#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE color and alpha GPU contracts", .serialized)
struct WPEColorDomainProbeTests {
    private static let encodedPixel: [UInt8] = [192, 128, 64, 128]

    @Test func tintSeparatesSampleAndAttachmentTransferFromAlpha() throws {
        let tint: [Double] = [0.5, 0.75, 0.25, 0.8]
        var outputs: [[Float]] = []
        for format: MTLPixelFormat in [.rgba8Unorm, .rgba8Unorm_srgb] {
            let result = try WPEColorDomainReplay.run(
                images: [.init(width: 1, bytes: Self.encodedPixel, format: format)],
                body: "gl_FragColor = texture(g_Texture0, v_TexCoord) * u_Tint;",
                declarations: "uniform vec4 u_Tint;", values: ["u_Tint": .vector(tint)], outputFormat: format
            )
            let expected = (0 ..< 4).map { component -> Double in
                let stored = Double(Self.encodedPixel[component]) / 255
                if component < 3, format == .rgba8Unorm_srgb {
                    return encode(decode(stored) * tint[component])
                }
                return stored * tint[component]
            }
            expect(result.values, equals: expected)
            #expect(result.contract.attachment.hardwareRGBTransfer == (format == .rgba8Unorm ? .identity : .sRGB))
            #expect(result.contract.inputs[0].view?.alphaTransfer == "identity")
            outputs.append(result.values)
        }
        #expect(abs(outputs[0][0] - outputs[1][0]) > 0.15)
        #expect(outputs[0][3] == outputs[1][3])
    }

    @Test func fiveTapBlurMatchesSampleNumberArithmetic() throws {
        let taps: [UInt8] = [0, 48, 96, 176, 240]
        let bytes = taps.flatMap { [$0, $0, $0, UInt8(255)] }
        let body = """
        vec3 sum = vec3(0.0);
        for (int i = 0; i < 5; i++) {
            sum += texture(g_Texture0, vec2((float(i) + 0.5) / 5.0, 0.5)).rgb;
        }
        gl_FragColor = vec4(sum * 0.2, 1.0);
        """
        let unorm = try WPEColorDomainReplay.run(images: [.init(width: 5, bytes: bytes, format: .rgba8Unorm)], body: body, outputFormat: .rgba8Unorm)
        let srgb = try WPEColorDomainReplay.run(images: [.init(width: 5, bytes: bytes, format: .rgba8Unorm_srgb)], body: body, outputFormat: .rgba8Unorm_srgb)
        let numericMean = taps.reduce(0.0) { $0 + Double($1) / 255 } / 5
        let decodedMean = taps.reduce(0.0) { $0 + decode(Double($1) / 255) } / 5
        expect(unorm.values, equals: [numericMean, numericMean, numericMean, 1])
        expect(srgb.values, equals: [encode(decodedMean), encode(decodedMean), encode(decodedMean), 1])
        #expect(abs(unorm.values[0] - srgb.values[0]) > 0.1)
    }

    @Test func alphaWeightedComposeKeepsAlphaOutsideRGBTransfer() throws {
        let front: [UInt8] = [200, 80, 32, 128]
        let back: [UInt8] = [16, 160, 224, 192]
        let body = """
        vec4 a = texture(g_Texture0, v_TexCoord);
        vec4 b = texture(g_Texture1, v_TexCoord);
        gl_FragColor = vec4(mix(b.rgb, a.rgb, a.a * 0.6), a.a * 0.75);
        """
        let alpha = Double(front[3]) / 255
        for format: MTLPixelFormat in [.rgba8Unorm, .rgba8Unorm_srgb] {
            let actual = try WPEColorDomainReplay.run(images: [.init(width: 1, bytes: front, format: format), .init(width: 1, bytes: back, format: format)],
                                                      body: body, outputFormat: format)
            var rgb = (0 ..< 3).map { component -> Double in
                var a = Double(front[component]) / 255, b = Double(back[component]) / 255
                if format == .rgba8Unorm_srgb {
                    a = decode(a); b = decode(b)
                }
                let mixed = b * (1 - alpha * 0.6) + a * alpha * 0.6
                return format == .rgba8Unorm_srgb ? encode(mixed) : mixed
            }
            rgb.append(alpha * 0.75)
            expect(actual.values, equals: rgb)
        }
    }

    @Test func straightAndPremultipliedBlendAgreeAndZeroAlphaIsFinite() throws {
        let straight: [UInt8] = [160, 80, 40, 128]
        let premultiplied: [UInt8] = [80, 40, 20, 128]
        let body = "gl_FragColor = texture(g_Texture0, v_TexCoord);"
        let clear = SIMD4<Double>(0.1, 0.2, 0.3, 0.4)
        let a = Double(straight[3]) / 255
        let normal = try WPEColorDomainReplay.run(images: [.init(width: 1, bytes: straight, format: .rgba8Unorm)], body: body,
                                                  outputFormat: .rgba32Float, blend: "normal", clear: clear)
        let pma = try WPEColorDomainReplay.run(images: [.init(width: 1, bytes: premultiplied, format: .rgba8Unorm)], body: body,
                                               outputFormat: .rgba32Float, blend: "premultipliednormal", clear: clear, pmaInputs: [0], pmaOutput: true)
        let normalExpected = (0 ..< 3).map { Double(straight[$0]) / 255 * a + clear[$0] * (1 - a) } + [a + clear.w * (1 - a)]
        let pmaExpected = (0 ..< 3).map { Double(premultiplied[$0]) / 255 + clear[$0] * (1 - a) } + [a + clear.w * (1 - a)]
        expect(normal.values, equals: normalExpected, tolerance: 0.00001)
        expect(pma.values, equals: pmaExpected, tolerance: 0.00001)
        #expect(zip(normal.values, pma.values).allSatisfy { abs($0 - $1) < 1.0 / 255 })
        #expect(pma.contract.inputs[0].shaderAlphaOperation == "unpremultiply-after-sampling")
        #expect(pma.contract.shaderOutputAlphaOperation == "premultiply-before-attachment")
        let zero = try WPEColorDomainReplay.run(images: [.init(width: 1, bytes: [255, 128, 64, 0], format: .rgba8Unorm)], body: body,
                                                outputFormat: .rgba32Float, pmaInputs: [0], pmaOutput: true)
        #expect(zero.values.allSatisfy { $0.isFinite && $0 == 0 })
    }

    @Test func additiveBlendingAndUNORMClippingStaySeparateFromFloatStorage() throws {
        let image = WPEColorDomainReplay.Image(width: 1, bytes: [192, 128, 64, 128], format: .rgba8Unorm)
        let body = "gl_FragColor = texture(g_Texture0, v_TexCoord) * 2.0;"
        let floats = try WPEColorDomainReplay.run(images: [image], body: body, outputFormat: .rgba32Float)
        let normalized = try WPEColorDomainReplay.run(images: [image], body: body, outputFormat: .rgba8Unorm)
        #expect(floats.values[0] > 1.5 && normalized.values[0] == 1)
        #expect(floats.contract.attachment.storage == .floatingPoint && normalized.contract.attachment.storage == .normalized)
        let clear = SIMD4<Double>(0.2, 0.3, 0.4, 0.1)
        let add = try WPEColorDomainReplay.run(images: [image], body: "gl_FragColor = texture(g_Texture0, v_TexCoord);",
                                               outputFormat: .rgba32Float, blend: "additive", clear: clear)
        let alpha = Double(image.bytes[3]) / 255
        expect(add.values, equals: (0 ..< 3).map { Double(image.bytes[$0]) / 255 * alpha + clear[$0] } + [alpha + clear.w], tolerance: 0.00001)
    }

    @Test func maskAndNativeTintProducerAreIndependentOfViewPolicy() throws {
        let mask = WPEColorDomainReplay.Image(width: 1, bytes: [128], format: .r8Unorm)
        let body = """
        vec4 color = texture(g_Texture0, v_TexCoord);
        color.a *= texture(g_Texture1, v_TexCoord).r;
        gl_FragColor = color;
        """
        for format: MTLPixelFormat in [.rgba8Unorm, .rgba8Unorm_srgb] {
            let actual = try WPEColorDomainReplay.run(images: [.init(width: 1, bytes: Self.encodedPixel, format: format), mask], body: body,
                                                      outputFormat: .rgba32Float)
            #expect(abs(actual.values[3] - Float(128.0 / 255 * 128.0 / 255)) < 0.00001)
            #expect(actual.contract.inputs[1].view?.hardwareRGBTransfer == .identity)
        }
        let pass = WPEPreparedRenderPass(
            pass: WPERenderPass(id: "tint", phase: .material, shader: "genericimage2", source: .image("input"), target: .scene,
                                textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"),
            shader: nil, textureBindings: [:], comboValues: [:], uniformValues: ["g_Color": .vector([0.5, 0.5, 0.5, 0.25])]
        )
        let native = WPEMetalShaderInputs.colorVector(for: pass)
        #expect(abs(Double(native.x) - decode(0.5)) < 0.00001 && native.w == 0.25)
        // This producer conversion is a separate decision from changing the sampling view.
        #expect(abs(native.x - 0.5) > 0.25)
    }

    private func expect(_ actual: [Float], equals expected: [Double], tolerance: Double = 2.0 / 255) {
        #expect(actual.count == expected.count)
        for (a, e) in zip(actual, expected) {
            #expect(a.isFinite && abs(Double(a) - e) <= tolerance)
        }
    }

    private func decode(_ x: Double) -> Double {
        x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
    }

    private func encode(_ x: Double) -> Double {
        x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }
}
#endif
