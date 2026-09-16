#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Metal full-image texture copy")
struct WPEMetalTextureCopyTests {
    @Test("Reduced snapshots sample the entire source, not its top-left rectangle")
    func downsamplesAllQuadrants() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba8Unorm, 4, 4)
        let destination = try texture(device, .rgba8Unorm, 2, 2)
        let corners: [[UInt8]] = [[255, 0, 0, 64], [0, 255, 0, 128], [0, 0, 255, 192], [255, 255, 255, 255]]
        let pixels: [UInt8] = (0 ..< 16).flatMap { index -> [UInt8] in
            let row = index / 4
            let column = index % 4
            return corners[(row / 2) * 2 + column / 2]
        }
        upload(pixels, to: source, bytesPerPixel: 4)
        try copy(executor, source, destination)
        #expect(readBytes(destination, bytesPerPixel: 4) == corners.flatMap(\.self))
    }

    @Test("Upsampling preserves HDR RGB and unmodified alpha, and refreshes destination mip levels", arguments: [Float(0), Float(2)])
    func hdrAlphaAndMips(alpha: Float) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba16Float, 2, 2)
        let destination = try texture(device, .rgba16Float, 4, 4, mipmapped: true)
        for red: Float in [4, 8] {
            let pixel = [red, 1, 0.5, alpha].map { Float16($0).bitPattern }
            upload(Array(repeating: pixel, count: 4).flatMap(\.self), to: source, bytesPerPixel: 8)
            try copy(executor, source, destination, mipmaps: true)
            for level in 0 ..< destination.mipmapLevelCount {
                let actual = readBytes(destination, bytesPerPixel: 8, level: level)
                let count = max(1, destination.width >> level) * max(1, destination.height >> level)
                let expected = Array(repeating: pixel, count: count).flatMap(\.self)
                #expect(actual == expected.withUnsafeBytes { Array($0) })
            }
        }
    }

    @Test("Pixel-format conversion uses sampling, including channel order and sRGB decoding")
    func formatConversion() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba8Unorm, 1, 1)
        let bgra = try texture(device, .bgra8Unorm, 1, 1)
        upload([UInt8(16), 32, 64, 128], to: source, bytesPerPixel: 4)
        try copy(executor, source, bgra)
        #expect(readBytes(bgra, bytesPerPixel: 4) == [64, 32, 16, 128])

        let srgb = try texture(device, .rgba8Unorm_srgb, 1, 1)
        let linear = try texture(device, .rgba16Float, 1, 1)
        upload([UInt8(128), 128, 128, 128], to: srgb, bytesPerPixel: 4)
        try copy(executor, srgb, linear)
        let components = readBytes(linear, bytesPerPixel: 8).withUnsafeBytes {
            Array($0.bindMemory(to: UInt16.self)).map { Float(Float16(bitPattern: $0)) }
        }
        for channel in 0 ..< 3 {
            #expect(abs(components[channel] - 0.21586) < 0.001)
        }
        #expect(abs(components[3] - 128.0 / 255.0) < 0.001, "sRGB transfer must not affect alpha")
    }

    @Test("Matching-format copies retain exact half-float bits")
    func matchingCopiesAreBitExact() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba16Float, 2, 1)
        let destination = try texture(device, .rgba16Float, 2, 1)
        let words: [UInt16] = [0x7E01, 0x0001, 0xBC00, 0x4000, 0x4400, 0x3800, 0, 0]
        upload(words, to: source, bytesPerPixel: 8)
        try copy(executor, source, destination)
        #expect(readBytes(destination, bytesPerPixel: 8) == words.withUnsafeBytes { Array($0) })
    }

    @Test("Identity copy can still regenerate mips without overlapping self-blit")
    func identityCopyRegeneratesMips() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba8Unorm, 4, 4, mipmapped: true)
        let pixel: [UInt8] = [64, 128, 192, 0]
        upload(Array(repeating: pixel, count: 16).flatMap(\.self), to: source, bytesPerPixel: 4)
        try copy(executor, source, source, mipmaps: true)
        #expect(readBytes(source, bytesPerPixel: 4, level: 2) == pixel)
        try copy(executor, source, source)
        #expect(readBytes(source, bytesPerPixel: 4) == Array(repeating: pixel, count: 16).flatMap(\.self))
    }

    @Test("Unsupported texture layout and sampled usage fail before Metal encoding")
    func rejectsUnsupportedInputs() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba8Unorm, 2, 2)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.textureType = .type2DArray
        descriptor.arrayLength = 2
        let array = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(executor.textureSourceCommandQueue.makeCommandBuffer())
        #expect(throws: WPEMetalTextureCopyError.unsupportedLayout) {
            try executor.copyTexture(source, to: array, commandBuffer: command)
        }
        descriptor.textureType = .type2D
        descriptor.arrayLength = 1
        descriptor.usage = .shaderRead
        let noRenderUsage = try #require(device.makeTexture(descriptor: descriptor))
        #expect(throws: WPEMetalTextureCopyError.missingSampledUsage) {
            try executor.copyTexture(source, to: noRenderUsage, commandBuffer: command)
        }
    }

    @Test("Closed effect gate resizes and converts an external image into its composite")
    func gatedExternalInput() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba16Float, 2, 2)
        let pixel = [Float(0.25), 0.5, 0.75, 0.5].map { Float16($0).bitPattern }
        upload(Array(repeating: pixel, count: 4).flatMap(\.self), to: source, bytesPerPixel: 8)
        let gate = WPEPassVisibilityGate(script: WPESceneTransformScript(script: "return false;", seed: .zero), initialVisible: false)
        func prepared(_ id: String, source: WPETextureReference, target: WPERenderTarget, gate: WPEPassVisibilityGate? = nil) -> WPEPreparedRenderPass {
            let pass = WPERenderPass(
                id: id, phase: .command(file: "effects/copy/effect.json"), shader: "commands/copy", source: source, target: target,
                textures: [:], binds: [:], constants: [:], combos: [:], blending: "disabled",
                cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled", visibilityGate: gate
            )
            return WPEPreparedRenderPass(
                pass: pass, shader: WPEShaderProgram(name: "commands/copy", vertexSource: "", fragmentSource: "", isBuiltin: true),
                textureBindings: [0: source], comboValues: [:], uniformValues: [:]
            )
        }
        let passes = [prepared("gate", source: .asset("external"), target: .layerComposite(name: "a"), gate: gate),
                      prepared("present", source: .fbo("a"), target: .scene)]
        let layer = WPERenderLayer(
            objectID: "gate", objectName: "gate", imagePath: "external", materialPath: nil,
            geometry: .identity, compositeA: "a", compositeB: "b", localFBOs: [], passes: passes.map(\.pass)
        )
        let output = try executor.render(
            pipeline: WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: passes)]),
            size: CGSize(width: 4, height: 4), textures: ["external": source]
        )
        let staging = try texture(device, output.pixelFormat, 4, 4)
        try copy(executor, output, staging)
        let isSRGB = output.pixelFormat == .rgba8Unorm_srgb || output.pixelFormat == .bgra8Unorm_srgb
        let isBGRA = output.pixelFormat == .bgra8Unorm || output.pixelFormat == .bgra8Unorm_srgb
        try #require(isSRGB || output.pixelFormat == .rgba8Unorm || output.pixelFormat == .bgra8Unorm)
        // The external half-float input is linear. An sRGB composite encodes
        // on store, then its scene sample decodes before the final sRGB store.
        // Compute the independent transfer-function oracle; alpha stays linear.
        var expected = [Double(0.25), 0.5, 0.75].map { linear -> UInt8 in
            let encoded = isSRGB
                ? (linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055)
                : linear
            return UInt8((encoded * 255).rounded())
        }
        if isBGRA {
            expected.swapAt(0, 2)
        }
        expected.append(UInt8((0.5 * 255).rounded()))
        let actual = readBytes(staging, bytesPerPixel: 4)
        for index in actual.indices {
            #expect(abs(Int(actual[index]) - Int(expected[index % 4])) <= 1)
        }
    }

    /// A blit cannot open while the solid scene run's render encoder is still recording on the
    /// same command buffer; the copy has to end that encoder before it asks for a blit.
    @Test("A copy ends the shared scene encoder before opening its blit")
    func copyEndsSharedSceneEncoder() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try texture(device, .rgba8Unorm, 2, 2)
        let destination = try texture(device, .rgba8Unorm, 2, 2)
        let scene = try texture(device, .rgba8Unorm, 2, 2)
        let command = try #require(executor.textureSourceCommandQueue.makeCommandBuffer())
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = scene
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        let run = WPEMetalSolidSceneRun()
        run.encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
        run.destinationTexture = scene
        executor.sharedSceneRun = run
        defer { executor.sharedSceneRun = nil }
        try executor.copyTexture(source, to: destination, commandBuffer: command)
        #expect(run.encoder == nil)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.error == nil)
    }

    private func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int, mipmapped: Bool = false) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: mipmapped)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func upload(_ data: [some Any], to texture: MTLTexture, bytesPerPixel: Int) {
        data.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: texture.width * bytesPerPixel)
        }
    }

    private func readBytes(_ texture: MTLTexture, bytesPerPixel: Int, level: Int = 0) -> [UInt8] {
        let width = max(1, texture.width >> level), height = max(1, texture.height >> level)
        var result = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        result.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * bytesPerPixel,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: level)
        }
        return result
    }

    private func copy(_ executor: WPEMetalRenderExecutor, _ source: MTLTexture, _ destination: MTLTexture, mipmaps: Bool = false) throws {
        let command = try #require(executor.textureSourceCommandQueue.makeCommandBuffer())
        try executor.copyTexture(source, to: destination, commandBuffer: command, generateMipmaps: mipmaps)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        #expect(command.error == nil)
    }
}
#endif
