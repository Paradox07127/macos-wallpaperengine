#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

/// Exercises the actual fallback fragment entry points, with raw linear RGBA16Float
/// targets so neither sRGB conversion nor a blend operation can hide an alpha error.
@Suite("WPE builtin fallback PMA colour domain", .serialized)
struct WPEBuiltinColorDomainTests {
    @Test("Nonlinear fallback colours operate in straight RGB; zero coverage preserves additive RGB", arguments: [false, true])
    func colourDomain(fast: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalBuiltins.metal")
        let library = try device.makeLibrary(source: source, options: WPEMetalLibraryRegistry.Configuration(fastMathEnabled: fast).makeOptions())
        let queue = try #require(device.makeCommandQueue())
        // Include opaque legacy controls, low alpha, HDR clamping in the existing
        // straight formula, and zero-alpha additive values (including >1 and negative).
        let inputs: [SIMD4<Float>] = [
            SIMD4(0.1, 0.05, 0, 0.25), SIMD4(0.4, 0.2, 0, 1),
            SIMD4(0.0005, 0.00025, 0, 0.001), SIMD4(0.5, 0.25, 0.1, 0.25),
            SIMD4(2, 0.25, -0.1, 0), SIMD4(0, 0, 0, 0),
        ]
        for grading in [false, true] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "wpe_fullscreen_vertex")
            descriptor.fragmentFunction = try WPEMetalColorOutput.fragment(library: library, name: grading ? "wpe_effect_color_grading_fragment" : "wpe_effect_colorbalance_fragment", format: .rgba16Float)
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            for input in inputs {
                let actual = try render(input, grading: grading, pipeline: pipeline, device: device, queue: queue)
                let sampled = input.mapHalfRoundTrip
                let expected = reference(sampled, grading: grading)
                for channel in 0 ..< 4 {
                    #expect(actual[channel].isFinite)
                    let tolerance: Float = sampled.w == 0 ? 0 : max(0.000002, abs(expected[channel]) * 0.002)
                    #expect(abs(actual[channel] - expected[channel]) <= tolerance,
                            "grading=\(grading), fast=\(fast), input=\(sampled), channel=\(channel): \(actual) vs \(expected)")
                }
            }
        }
    }

    @Test("Text-carrier inputs keep independent RGB through identity colour effects and blend composites",
          arguments: [false, true])
    func carrierInputsSkipCoverageDivision(straightOutput: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try RepositoryRoot.source("LiveWallpaper/Runtime/Metal/WPEMetalBuiltins.metal")
        let library = try device.makeLibrary(source: source, options: WPEMetalLibraryRegistry.Configuration(fastMathEnabled: true).makeOptions())
        let queue = try #require(device.makeCommandQueue())
        let carrier = WPENativeAlphaPolicy(input: .none, straightOutput: straightOutput, independentCoverageInput: true)
        // RGB greater than coverage: a PMA division would clip every channel to 1.
        let input = SIMD4<Float>(0.6, 0.7, 0.8, 0.25).mapHalfRoundTrip
        let associated = SIMD4(input.x * input.w, input.y * input.w, input.z * input.w, input.w)
        let effects = ["wpe_effect_colorbalance_fragment", "wpe_effect_color_grading_fragment"]
        for name in effects {
            let actual = try renderCarrier(input, fragment: name, nativeAlpha: carrier, library: library, device: device, queue: queue)
            expectClose(actual, straightOutput ? input : associated, "\(name), straightOutput=\(straightOutput)")
        }
        // Darker Color against a white scene returns the layer's straight RGB unmixed.
        for name in ["wpe_blend_composite_fragment", "wpe_blend_composite_fetch_fragment"] {
            let actual = try renderCarrier(input, fragment: name, nativeAlpha: carrier, library: library, device: device, queue: queue)
            expectClose(actual, associated, "\(name), straightOutput=\(straightOutput)")
        }
    }

    private func expectClose(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>, _ label: String) {
        for channel in 0 ..< 4 {
            #expect(abs(actual[channel] - expected[channel]) <= 0.002, "\(label), channel=\(channel): \(actual) vs \(expected)")
        }
    }

    private func renderCarrier(_ input: SIMD4<Float>, fragment: String, nativeAlpha: WPENativeAlphaPolicy,
                               library: MTLLibrary, device: MTLDevice, queue: MTLCommandQueue) throws -> SIMD4<Float> {
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "wpe_fullscreen_vertex")
        pipelineDescriptor.fragmentFunction = try WPEMetalColorOutput.fragment(
            library: library, name: fragment, format: .rgba16Float, nativeAlpha: nativeAlpha
        )
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let scene = try #require(device.makeTexture(descriptor: descriptor))
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let region = MTLRegionMake2D(0, 0, 1, 1)
        var pixel = (0 ..< 4).map { Float16(input[$0]).bitPattern }
        pixel.withUnsafeBytes { source.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        let white = [UInt16](repeating: Float16(1).bitPattern, count: 4)
        for texture in [scene, output] {
            white.withUnsafeBytes { texture.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(scene, index: 4)
        switch fragment {
        case "wpe_effect_colorbalance_fragment":
            var uniforms = WPEColorBalanceUniforms(brightness: 0, contrast: 1, saturation: 1, padding: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
        case "wpe_effect_color_grading_fragment":
            var uniforms = WPEColorGradingUniforms(lift: .zero, gamma: SIMD4(repeating: 1), gain: SIMD4(repeating: 1))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
        default:
            var uniforms = WPEBlendCompositeUniforms(blendMode: 5)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBlendCompositeUniforms>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed, "\(String(describing: command.error))")
        pixel.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 8, from: region, mipmapLevel: 0) }
        return SIMD4(Float(Float16(bitPattern: pixel[0])), Float(Float16(bitPattern: pixel[1])),
                     Float(Float16(bitPattern: pixel[2])), Float(Float16(bitPattern: pixel[3])))
    }

    private func reference(_ sampled: SIMD4<Float>, grading: Bool) -> SIMD4<Float> {
        guard sampled.w != 0 else { return sampled }
        let alpha = Double(sampled.w)
        var rgb = SIMD3<Double>(Double(sampled.x), Double(sampled.y), Double(sampled.z)) / alpha
        if grading {
            // Actual uniform bytes below: lift=.1, gamma=2, gain=1.2.
            rgb += SIMD3(repeating: Double(Float(0.1)))
            rgb *= Double(Float(1.2))
            for index in 0 ..< 3 {
                rgb[index] = sqrt(min(max(rgb[index], 0), 1))
            }
        } else {
            // Brightness=.2, contrast=1, saturation=1 isolates the nonhomogeneous term.
            rgb += SIMD3(repeating: Double(Float(0.2)))
        }
        return SIMD4(Float(min(max(rgb.x, 0), 1) * alpha),
                     Float(min(max(rgb.y, 0), 1) * alpha),
                     Float(min(max(rgb.z, 0), 1) * alpha), sampled.w).mapHalfRoundTrip
    }

    private func render(_ input: SIMD4<Float>, grading: Bool, pipeline: MTLRenderPipelineState,
                        device: MTLDevice, queue: MTLCommandQueue) throws -> SIMD4<Float> {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let output = try #require(device.makeTexture(descriptor: descriptor))
        var pixel = (0 ..< 4).map { Float16(input[$0]).bitPattern }
        pixel.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        if grading {
            var uniforms = WPEColorGradingUniforms(lift: SIMD4(repeating: 0.1), gamma: SIMD4(repeating: 2), gain: SIMD4(repeating: 1.2))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
        } else {
            var uniforms = WPEColorBalanceUniforms(brightness: 0.2, contrast: 1, saturation: 1, padding: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout.size(ofValue: uniforms), index: 0)
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed, "\(String(describing: command.error))")
        pixel.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        return SIMD4(Float(Float16(bitPattern: pixel[0])), Float(Float16(bitPattern: pixel[1])),
                     Float(Float16(bitPattern: pixel[2])), Float(Float16(bitPattern: pixel[3])))
    }
}

private extension SIMD4<Float> {
    var mapHalfRoundTrip: Self {
        SIMD4(Float(Float16(x)), Float(Float16(y)), Float(Float16(z)), Float(Float16(w)))
    }
}
#endif
