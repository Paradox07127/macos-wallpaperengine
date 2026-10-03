#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing
import UniformTypeIdentifiers

@Suite("WPE color and alpha GPU contracts", .serialized)
struct WPEColorDomainProbeTests {
    private static let encodedPixel: [UInt8] = [192, 128, 64, 128]

    @Test("Closed image producers can store straight RGBA without changing legacy native PMA",
          arguments: [false, true])
    func nativeImageOutputAlphaContract(straight: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [192, 128, 64, 96]
        bytes.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4) }
        let pass = WPERenderPass(id: "image", phase: .material, shader: "genericimage2", source: .asset("source"), target: .scene,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let prepared = WPEPreparedRenderPass(pass: pass, shader: nil, textureBindings: [0: .asset("source")], comboValues: [:], uniformValues: [:],
                                             alphaContract: straight ? .init(unpremultipliedInputSlots: [], premultipliedOutput: false) : nil)
        let layer = WPERenderLayer(objectID: "image", objectName: "image", imagePath: "source", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])
        let output = try executor.render(pipeline: .init(layers: [.init(graphLayer: layer, passes: [prepared])]),
                                         size: CGSize(width: 4, height: 4), textures: ["source": source])
        let pixel = try rawPixels(output, coordinates: [[2, 2]], executor: executor)[0]
        for channel in 0 ..< 3 {
            let expected = Double(bytes[channel]) / 255 * (straight ? 1 : Double(bytes[3]) / 255)
            #expect(abs(pixel[channel] - expected) <= 1.0 / 255)
        }
    }

    @Test("UNORM clamps over-range source before blending while float targets retain HDR")
    func attachmentSourceRangeIsAppliedBeforeBlend() throws {
        for blend in ["normal", "additive"] {
            for format: MTLPixelFormat in [.rgba8Unorm, .rgba16Float, .rgba32Float] {
                let output = try WPEColorDomainReplay.run(images: [], body: "gl_FragColor = vec4(2.0, -1.0, 0.25, 0.25);",
                                                          outputFormat: format, blend: blend, clear: SIMD4(0.25, 0.25, 0.25, 1))
                let back = blend == "normal" ? 0.1875 : 0.25
                let source: [Double] = format == .rgba8Unorm ? [1, 0, 0.25] : [2, -1, 0.25]
                let alpha = blend == "additive" && format != .rgba8Unorm ? 1.25 : 1.0
                let expected = source.map { $0 * 0.25 + back } + [alpha]
                expect(output.values, equals: expected, tolerance: format == .rgba8Unorm ? 1.0 / 255 : 0.001)
            }
        }
    }

    @Test("Injected PMA preserves the UNORM source clamp before representation conversion")
    func injectedPremultiplyKeepsSourceRangeOrder() throws {
        for format: MTLPixelFormat in [.rgba8Unorm, .rgba16Float] {
            let output = try WPEColorDomainReplay.run(images: [], body: "gl_FragColor = vec4(2.0, -1.0, 0.25, 0.25);",
                                                      outputFormat: format, blend: "premultipliednormal", clear: SIMD4(0.25, 0.25, 0.25, 1), pmaOutput: true)
            let expected: [Double] = format == .rgba8Unorm ? [0.4375, 0.1875, 0.25, 1] : [0.6875, -0.0625, 0.25, 1]
            expect(output.values, equals: expected, tolerance: format == .rgba8Unorm ? 1.0 / 255 : 0.001)
        }
    }

    @Test("Native solid source clamps before its injected PMA conversion")
    func nativeSolidSourceRangeBeforePremultiply() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = WPERenderPass(id: "solid", phase: .material, shader: "solidlayer", source: .asset("white"), target: .scene,
                                 textures: [:], binds: [:], constants: [:], combos: [:], blending: "premultipliednormal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let prepared = WPEPreparedRenderPass(pass: pass, shader: nil, textureBindings: [:], comboValues: [:],
                                             uniformValues: ["g_Color": .vector([2, -1, 0.25, 0.25])])
        let layer = WPERenderLayer(objectID: "solid", objectName: "solid", imagePath: "white", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [prepared])])
        let texture = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:])
        let pixel = try rawPixels(texture, coordinates: [[2, 2]], executor: executor)[0]
        #expect(abs(pixel[0] - 0.25) <= 1.0 / 255)
        #expect(pixel[1] == 0)
        #expect(abs(pixel[2] - 0.0625) <= 1.0 / 255)
    }

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
        #expect(native.x == 0.5 && native.w == 0.25)
    }

    @Test("Production image tint, opacity and SDR brightness match Windows raw numbers")
    func ordinaryImageNumbersReachTheAttachment() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try #require(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 128, count: 16)
        input.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 8)
        for alpha in [1.0, 0.5, 0.25] {
            let pass = WPERenderPass(id: "image", phase: .material, shader: "genericimage4", source: .image("input"),
                                     target: .scene, textures: [0: .image("input")], binds: [:], constants: [:], combos: ["VERSION": 2],
                                     blending: "premultiplied", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
            let geometry = WPERenderLayerGeometry(origin: SIMD3(2, 2, 0), scale: SIMD3(repeating: 1), angles: .zero,
                                                  alignment: .center, size: CGSize(width: 4, height: 4), alpha: alpha,
                                                  color: SIMD3(repeating: 0.5), brightness: 4)
            let graph = WPERenderLayer(objectID: "image", objectName: "image", imagePath: "input", materialPath: nil,
                                       geometry: geometry, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])
            let prepared = WPEPreparedRenderPass(pass: pass,
                                                 shader: .init(name: "genericimage4", vertexSource: "", fragmentSource: "", isBuiltin: true),
                                                 textureBindings: [0: .image("input")], comboValues: ["VERSION": 2], uniformValues: [:])
            let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: [prepared])])
            let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: ["input": input])
            let probe = try rawPixels(output, coordinates: [[2, 2]], executor: executor)
            // Brightness is ignored in SDR output.
            let expected = 0.5 * pow(128.0 / 255, 2) * alpha
            #expect(output.pixelFormat == .rgba8Unorm)
            #expect(abs(probe[0][0] - expected) <= 1.0 / 255)
            #expect(probe[0][3] == 1)
        }
    }

    @Test("Terminal HDR transfer maps the captured combine_hdr RT to EDR reference white and preserves the work texture")
    func hdrDisplayTransferIsTerminal() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 4, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        let input = try #require(device.makeTexture(descriptor: descriptor))
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let numbers: [Float] = [0.53564453125, 0.259033203125, 0.1314697265625, 5.71875]
        var pixels = numbers.flatMap { [Float16($0).bitPattern, Float16($0).bitPattern, Float16($0).bitPattern, UInt16(0)] }
        input.replace(region: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 32)
        let command = try #require(executor.commandQueue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        try encoder.setRenderPipelineState(executor.renderPipeline(
            fragmentName: WPEMetalRenderExecutor.presentFragment(source: input.pixelFormat),
            blendMode: "disabled", alphaWritePolicy: .all, colorPixelFormat: output.pixelFormat
        ))
        encoder.setFragmentTexture(input, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        #expect(command.status == .completed)
        let actual = try rawPixels(output, coordinates: [[0, 0], [1, 0], [2, 0], [3, 0]], executor: executor)
        // Windows combine_hdr RT divided by that capture's g_RenderVar0.x (SDR white 240 nits = 3.0): EDR 1.0 is already reference white.
        let reference = [0.74560546875, 0.16357421875, 0.04681396484375, 3.0].map { $0 / 3 }
        for (sample, expected) in zip(actual, reference) {
            #expect(abs(sample[0] - expected) <= 0.001)
            #expect(sample[3] == 1)
        }
        let unchanged = try rawPixels(input, coordinates: [[3, 0]], executor: executor)
        #expect(unchanged[0][0] == Double(numbers[3]))
        #expect(unchanged[0][3] == 0)
    }

    @Test("Unprepared image copy keeps authored RGB and opaque scene coverage")
    func unpreparedImageKeepsSceneCoverage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try #require(device.makeTexture(descriptor: descriptor))
        var pixels = [UInt8](repeating: 128, count: 16)
        input.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &pixels, bytesPerRow: 8)
        let graph = WPERenderLayer(objectID: "copy", objectName: "copy", imagePath: "input", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: [])])
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 2, height: 2), textures: ["input": input])
        let sample = try rawPixels(output, coordinates: [[1, 1]], executor: executor)[0]
        #expect(abs(sample[0] - 128.0 / 255) <= 1.0 / 255)
        #expect(sample[3] == 1)
    }

    @MainActor
    @Test("Native additive particle scene draw preserves alpha and authored sample arithmetic")
    func additiveParticleKeepsSceneCoverage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 1, "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 8, "max": 8],
                            ["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "colorrandom", "min": "128 128 128", "max": "128 128 128"]],
            "operator": [["name": "alphafade", "fadeintime": 0, "fadeouttime": 1]],
        ])
        let transform = WPEParticleSceneTransform(sceneSize: SIMD2(16, 16), objectOrigin: SIMD3(8, 8, 0),
                                                  objectScale: SIMD3(repeating: 1), objectAngleZ: 0)
        let system = try #require(WPEParticleSystem(definition: definition, device: device, blendMode: .additive,
                                                    sceneTransform: transform, seed: 133))
        system.tick(now: 0)
        system.tick(now: 0.05)
        try #require(system.liveInstanceCount == 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 16, height: 16, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        var clear = Array(repeating: [Float16(0), 0, 0, 1].map(\.bitPattern), count: 256).flatMap(\.self)
        output.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: &clear, bytesPerRow: 128)
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = .shaderRead
        let input = try #require(device.makeTexture(descriptor: sourceDescriptor))
        input.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](arrayLiteral: 128, 128, 128, 255), bytesPerRow: 4)
        let command = try #require(executor.commandQueue.makeCommandBuffer())
        let size = CGSize(width: 16, height: 16)
        var state = WPEMetalFrameState(output: output, sceneSize: size)
        try executor.encodeParticleSystem(system, into: command, output: output, sceneSize: size, cameraParallax: .neutral,
                                          texturesByMaterial: [ObjectIdentifier(system): input], normalsByMaterial: [:],
                                          frameState: &state, traceIndex: 0)
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        let sample = try rawPixels(output, coordinates: [[8, 8]], executor: executor)[0]
        #expect(abs(sample[0] - pow(128.0 / 255, 2)) < 0.001)
        #expect(sample[3] == 1, "Fresh Windows particle scene draws use writeMask=7")
    }

    @Test("A media cover samples back at its encoded sRGB byte value")
    func mediaCoverSamplesBackEncodedBytes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let gray = [UInt8](repeating: 128, count: 8 * 8 * 4).enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 8, height: 8, mipmapped: false)
        descriptor.usage = .shaderRead
        let decodedOnSample = try #require(device.makeTexture(descriptor: descriptor))
        decodedOnSample.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0, withBytes: gray, bytesPerRow: 8 * 4)
        let pass = WPERenderPass(id: "cover.0", phase: .material, shader: "genericimage2", source: .image("cover"), target: .scene,
                                 textures: [0: .image("cover")], binds: [:], constants: [:], combos: [:],
                                 userTextureBindings: .init(material: [.init(name: "$mediaThumbnail", type: "system", slot: 0)]),
                                 blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        let layer = WPERenderLayer(objectID: "cover", objectName: "cover", imagePath: "cover", materialPath: nil,
                                   geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass])
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [
            .init(pass: pass, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]),
        ])])
        func sampledBytes(_ store: WPEMediaTextureStore) throws -> [Int] {
            executor.mediaTextureStore = store
            let output = try executor.render(pipeline: pipeline, size: CGSize(width: 8, height: 8), textures: ["cover": decodedOnSample])
            #expect(output.pixelFormat == WPEMetalRenderExecutor.outputPixelFormat)
            return try rawPixels(output, coordinates: [[4, 4]], executor: executor)[0].prefix(3).map { Int(($0 * 255).rounded()) }
        }

        let coverStore = WPEMediaTextureStore(device: device, slotsByPassID: ["cover.0": [0: .thumbnail]])
        try #require(coverStore.ingest(artwork: Self.png(rgba: gray, width: 8, height: 8)))
        let cover = try sampledBytes(coverStore)
        #expect(cover.allSatisfy { abs($0 - 128) <= 2 }, "cover sampled back as \(cover), decoded once too often")
        let control = try sampledBytes(WPEMediaTextureStore(device: device, slotsByPassID: ["cover.0": [0: .thumbnail]]))
        // 55 is 128 after one sRGB decode: 255 * ((128/255 + 0.055) / 1.055)^2.4.
        #expect(control.allSatisfy { abs($0 - 55) <= 3 }, "_srgb control sampled back as \(control)")
    }

    private static func png(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func rawPixels(_ texture: MTLTexture, coordinates: [[Int]], executor: WPEMetalRenderExecutor) throws -> [[Double]] {
        let probe = try WPEOraclePixelProbe.sample(texture: texture, coordinates: coordinates, commandQueue: executor.commandQueue)
        let samples = try #require(probe["samples"] as? [[String: Any]])
        return try samples.map { try #require($0["storageRGBA"] as? [Double]) }
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
