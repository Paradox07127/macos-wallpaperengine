import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal solid scene encoder runs")
struct WPEMetalSolidSceneRunTests {
    private let size = CGSize(width: 33, height: 17)

    private func layer(
        _ index: Int, shader: String = "solidlayer", source: WPETextureReference = .image("unused"),
        target: WPERenderTarget = .scene, depthTest: String = "disabled", visible: Bool = true,
        builtin: Bool = true, bindings: [Int: WPETextureReference]? = nil,
        color: [Double]? = nil, transformed: Bool = true
    ) -> WPEPreparedRenderLayer {
        let colors: [[Double]] = [[0.2, 0.6, 1.5, 1], [1.2, 0.1, 0.4, 0.35],
                                  [0.3, 1.4, 0.1, 0.6], [0.8, 0.2, 0.9, 0.15]]
        let modes = ["premultiplied", "additive", "premultiplied", "premultiplied"]
        let graphPass = WPERenderPass(
            id: "solid-\(index).0", phase: .material, shader: shader, source: source, target: target,
            textures: [:], binds: [:], constants: ["g_Color": .vector(color ?? colors[index % 4])],
            combos: [:], blending: shader == "solidlayer" ? modes[index % 4] : "disabled",
            cullMode: "nocull", depthTest: depthTest, depthWrite: "disabled"
        )
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(16.5 + (transformed ? Double(index * 3 - 4) : 0), 8.5, 0),
            scale: SIMD3<Double>(transformed && index == 2 ? -1 : 1, 1, 1),
            angles: SIMD3<Double>(0, 0, transformed ? Double(index) * 0.15 : 0),
            alignment: .center, size: size, alpha: 1, color: SIMD3<Double>(repeating: 1), brightness: 1
        )
        let graphLayer = WPERenderLayer(
            objectID: "solid-\(index)", objectName: "Solid \(index)", visible: visible,
            imagePath: "unused", materialPath: nil, geometry: geometry,
            compositeA: "solid-\(index)-a", compositeB: "solid-\(index)-b", localFBOs: [],
            passes: [graphPass], sortIndex: index
        )
        let pass = WPEPreparedRenderPass(
            pass: graphPass,
            shader: WPEShaderProgram(name: shader, vertexSource: "", fragmentSource: "", isBuiltin: builtin),
            textureBindings: bindings ?? [0: source], comboValues: [:], uniformValues: [:]
        )
        return WPEPreparedRenderLayer(graphLayer: graphLayer, passes: [pass])
    }

    private func bytes(_ texture: MTLTexture) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false
        )
        descriptor.storageMode = .shared
        let staging = try #require(texture.device.makeTexture(descriptor: descriptor))
        let queue = try #require(texture.device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let bytesPerRow = texture.width * (texture.pixelFormat == .rgba16Float ? 8 : 4)
        var result = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        result.withUnsafeMutableBytes {
            staging.getBytes($0.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }

    private func renderBytes(
        _ executor: WPEMetalRenderExecutor, pipeline: WPEPreparedRenderPipeline, hdr: Bool
    ) throws -> [UInt8] {
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: Double(size.width), height: Double(size.height), auto: true),
            sceneCamera: .defaultCamera, sceneHDR: hdr
        )
        let output = try executor.render(pipeline: pipeline, size: size, textures: [:], cameraUniforms: camera)
        #expect(output.pixelFormat == (hdr ? MTLPixelFormat.rgba16Float : MTLPixelFormat.rgba8Unorm_srgb))
        return try bytes(output)
    }

    @Test("Actual merged render preserves ordered colors, transforms and all target bytes",
          arguments: [false, true])
    func mergedPixelsMatch(hdr: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pipeline = WPEPreparedRenderPipeline(layers: (0 ..< 4).map { layer($0) })
        var reference: [UInt8]?
        for enabled in [false, true, false, true] {
            executor.solidSceneBatchingEnabled = enabled
            let actual = try renderBytes(executor, pipeline: pipeline, hdr: hdr)
            #expect(actual.contains { $0 != 0 })
            #expect(executor.lastSolidSceneBatchStats.encoders == (enabled ? 1 : 0))
            #expect(executor.lastSolidSceneBatchStats.draws == (enabled ? 4 : 0))
            if let reference {
                #expect(actual == reference)
            } else {
                reference = actual
            }
        }
        let reversed = WPEPreparedRenderPipeline(layers: Array(pipeline.layers.reversed()))
        let reordered = try renderBytes(executor, pipeline: reversed, hdr: hdr)
        let ordered = try #require(reference)
        #expect(reordered != ordered) // Prove this fixture observes paint order, not just empty draws.
    }

    @Test("A solid run has no four-draw limit and preserves every full-target draw",
          arguments: [1, 5, 6, 17, 64], [false, true])
    func arbitraryRunLength(count: Int, hdr: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let layers = (0 ..< count).map { index in
            let mix = Double(index + 1) / Double(count + 1)
            return layer(index, color: [1.4 * mix, 0.2, 1.3 - mix, 0.35], transformed: false)
        }
        let pipeline = WPEPreparedRenderPipeline(layers: layers)
        executor.solidSceneBatchingEnabled = false
        let expected = try renderBytes(executor, pipeline: pipeline, hdr: hdr)
        executor.solidSceneBatchingEnabled = true
        let actual = try renderBytes(executor, pipeline: pipeline, hdr: hdr)
        #expect(actual == expected)
        #expect(actual.contains { $0 != 0 })
        #expect(executor.lastSolidSceneBatchStats.encoders == 1)
        #expect(executor.lastSolidSceneBatchStats.draws == count)
        if count > 1 {
            let reversed = WPEPreparedRenderPipeline(layers: Array(layers.reversed()))
            #expect(try renderBytes(executor, pipeline: reversed, hdr: hdr) != expected)
        }
    }

    @Test("A scene snapshot closes the run and preserves the later composition")
    func snapshotSeparatesRuns() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let capture = layer(2, shader: "commands/copy", source: .fbo("_rt_FullFrameBuffer"), transformed: false)
        let pipeline = WPEPreparedRenderPipeline(layers: [layer(0), layer(1), capture, layer(3), layer(4)])
        executor.solidSceneBatchingEnabled = false
        let expected = try renderBytes(executor, pipeline: pipeline, hdr: true)
        executor.solidSceneBatchingEnabled = true
        let actual = try renderBytes(executor, pipeline: pipeline, hdr: true)
        #expect(actual == expected)
        #expect(executor.lastSolidSceneBatchStats.encoders == 2)
        #expect(executor.lastSolidSceneBatchStats.draws == 4)
    }

    @Test("Hidden layer boundaries and same-key color updates do not retain stale state")
    func visibilityAndLiveUniforms() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        for alpha in [0.0, 0.35, 1.0] {
            let pipeline = WPEPreparedRenderPipeline(layers: [
                layer(0), layer(1, visible: false), layer(2, color: [0.1, 1.8, 0.2, alpha]), layer(3),
            ])
            executor.solidSceneBatchingEnabled = false
            let expected = try renderBytes(executor, pipeline: pipeline, hdr: true)
            executor.solidSceneBatchingEnabled = true
            let actual = try renderBytes(executor, pipeline: pipeline, hdr: true)
            #expect(actual == expected)
            #expect(executor.lastSolidSceneBatchStats.encoders == 2)
            #expect(executor.lastSolidSceneBatchStats.draws == 3)
        }
    }

    @Test("Unsupported input and depth paths cannot borrow a solid encoder")
    func conservativeEligibility() {
        #expect(WPEMetalSolidSceneRun.accepts(layer(0)))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, source: .previous)))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, source: .fbo("scene"))))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, bindings: [8: .fbo("_rt_FullFrameBuffer")])))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, target: .fbo(name: "other"))))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, depthTest: "enabled")))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, builtin: false)))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, visible: false)))
        #expect(!WPEMetalSolidSceneRun.accepts(layer(0, shader: "commands/copy")))
    }

    @Test("Failure after a run leaves the next frame able to encode")
    func failureClosesRun() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let broken = WPEPreparedRenderPipeline(layers: [
            layer(0), layer(1), layer(2, shader: "commands/copy", source: .asset("absent")),
        ])
        #expect(throws: (any Error).self) {
            try executor.render(pipeline: broken, size: size, textures: [:])
        }
        let output = try executor.render(
            pipeline: WPEPreparedRenderPipeline(layers: [layer(0), layer(1)]), size: size, textures: [:]
        )
        #expect(try bytes(output).contains { $0 != 0 })
        #expect(executor.lastSolidSceneBatchStats.encoders == 1)
        #expect(executor.lastSolidSceneBatchStats.draws == 2)
    }
}

@Suite("WPEMetalShaderInputs — named FBO alias lookup")
struct WPEMetalNamedFBOAliasTests {

    @Test("Exact-name lookup is unaffected by alias logic")
    func exactNameWins() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["blur_start"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start",
            frameState: frameState
        )
        #expect(resolved == nil)
    }

    @Test("`_rt_` prefix is stripped when probing aliases")
    func stripsRTPrefix() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["blur_start"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "_rt_blur_start",
            frameState: frameState
        )
        #expect(resolved != nil)
    }

    @Test("`_rt_` prefix is added when probing aliases")
    func addsRTPrefix() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["_rt_blur_start"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start",
            frameState: frameState
        )
        #expect(resolved != nil)
    }

    @Test("Case-insensitive fallback catches stray capitalization")
    func caseInsensitiveFallback() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["Blur_Start_2"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start_2",
            frameState: frameState
        )
        #expect(resolved != nil)
    }

    @Test("Unknown names still return nil so the caller raises missingTexture")
    func unknownNameReturnsNil() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)
        frameState.latestNamedTextures["something_else"] = texture
        let resolved = WPEMetalShaderInputs.resolveAliasedNamedTexture(
            name: "blur_start",
            frameState: frameState
        )
        #expect(resolved == nil)
    }

    @Test("Scene writes bump the generation so alias snapshots can detect staleness")
    func sceneWriteGenerationTracksSnapshotStaleness() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let texture = Self.makeScratchTexture(device: device) else {
            return
        }
        var frameState = Self.makeFrameState(output: texture)

        frameState.latestNamedTextures["_rt_FullFrameBuffer"] = texture
        frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] = frameState.sceneWriteGeneration
        #expect(frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] == frameState.sceneWriteGeneration)

        frameState.registerWrite(texture: texture, targetID: .scene)
        #expect(frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] != frameState.sceneWriteGeneration)

        frameState.registerWrite(texture: texture, targetID: .named("_rt_imageLayerComposite_x_a"))
        let generationAfterFBOWrite = frameState.sceneWriteGeneration
        frameState.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] = generationAfterFBOWrite
        #expect(frameState.sceneWriteGeneration == generationAfterFBOWrite)

        frameState.sceneAliasSnapshotGenerations["_rt_HalfFrameBuffer"] = frameState.sceneWriteGeneration
        frameState.registerWrite(texture: texture, targetID: .named("_rt_HalfFrameBuffer"))
        #expect(frameState.sceneAliasSnapshotGenerations["_rt_HalfFrameBuffer"] == nil)
    }

    private static func makeFrameState(output: MTLTexture) -> WPEMetalFrameState {
        WPEMetalFrameState(
            output: output,
            sceneSize: CGSize(width: 4, height: 4)
        )
    }

    @Test("reflection copy and mip generation in one encoder preserve HDR values")
    func reflectionCopyGeneratesFreshMipChain() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 8, height: 8, mipmapped: true
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let destination = try #require(device.makeTexture(descriptor: descriptor))
        // Two updates catch both accidentally skipping the copy and stale mips.
        for red: Float in [2, 4] {
            let pixel = [red, 0.25, 0.5, 1].map { Float16($0).bitPattern }
            let input = Array(repeating: pixel, count: 64).flatMap(\.self)
            input.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                source.replace(region: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0,
                               withBytes: base, bytesPerRow: 64)
            }
            let command = try #require(executor.textureSourceCommandQueue.makeCommandBuffer())
            try executor.copyTexture(source, to: destination, commandBuffer: command, generateMipmaps: true)
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            #expect(command.error == nil)
            for level in 0 ..< destination.mipmapLevelCount {
                var output = [UInt16](repeating: 0, count: 4)
                output.withUnsafeMutableBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    destination.getBytes(base, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: level)
                }
                #expect(output == pixel)
            }
        }
    }

    private static func makeScratchTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 4,
            height: 4,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}

@Suite("Scene blend framebuffer fetch", .serialized)
struct WPEMetalSceneBlendFetchTests {
    private func texture(_ device: MTLDevice, format: MTLPixelFormat = .rgba16Float) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 17, height: 9, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func pass(source: WPETextureReference = .fbo("layer"), extra: WPETextureReference? = nil,
                      builtin: Bool = true) -> WPEPreparedRenderPass {
        var bindings: [Int: WPETextureReference] = [0: source, 4: .fbo("_rt_FullFrameBuffer")]
        if let extra {
            bindings[1] = extra
        }
        let graphPass = WPERenderPass(
            id: "blend", phase: .material, shader: "wpe_blend_composite", source: source, target: .scene,
            textures: bindings, binds: [:], constants: [:], combos: [:], blending: "premultiplied",
            cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        return WPEPreparedRenderPass(
            pass: graphPass,
            shader: WPEShaderProgram(name: graphPass.shader, vertexSource: "", fragmentSource: "", isBuiltin: builtin),
            textureBindings: bindings, comboValues: [:], uniformValues: [:]
        )
    }

    @Test("Fetch rejects feedback, named overrides, format conversion and uninitialized scenes without mutating aliases")
    func eligibilityAndAliasLifetime() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try texture(device)
        let source = try texture(device)
        let snapshot = try texture(device)
        let pool = WPEMetalRenderTargetPool(device: device)
        pool.promotesLDRFormatsToHDR = true
        let layer = WPERenderLayer(objectID: "test", objectName: "test", imagePath: "", materialPath: nil,
                                   geometry: .identity, compositeA: "layer", compositeB: "unused", localFBOs: [], passes: [])
        var state = WPEMetalFrameState(output: output, sceneSize: CGSize(width: 17, height: 9), renderTargetPool: pool)
        state.latestNamedTextures["layer"] = source
        func eligible(_ prepared: WPEPreparedRenderPass) -> Bool {
            WPEMetalShaderInputs.canFetchSceneColor(pass: prepared, layer: layer, destination: output,
                                                    textures: [:], frameState: state)
        }
        #expect(!eligible(pass()))
        state.registerWrite(texture: output, targetID: .scene)
        state.markInitialized(output)
        #expect(eligible(pass()) == device.supportsFamily(.apple1))
        #expect(!eligible(pass(builtin: false)))
        #expect(!eligible(pass(source: .previous)))
        #expect(!eligible(pass(source: .fbo("_rt_FullFrameBuffer"))))
        #expect(!eligible(pass(extra: .fbo("_rt_HalfFrameBuffer"))))
        state.latestNamedTextures["layer"] = output
        #expect(!eligible(pass()))
        state.latestNamedTextures["layer"] = source
        state.latestNamedTextures["_rt_FullFrameBuffer"] = snapshot
        #expect(!eligible(pass()))
        state.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] = 0
        #expect(eligible(pass()) == device.supportsFamily(.apple1))
        #expect(state.latestNamedTextures["_rt_FullFrameBuffer"] === snapshot)
        #expect(state.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] == 0)
        state.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] = state.sceneWriteGeneration
        state.latestNamedTextures["_rt_FullFrameBuffer"] = try texture(device, format: .rgba8Unorm_srgb)
        #expect(!eligible(pass()))
        state.latestNamedTextures["_rt_FullFrameBuffer"] = snapshot
        #expect(eligible(pass()) == device.supportsFamily(.apple1))
        state.registerWrite(texture: output, targetID: .scene)
        #expect(state.sceneAliasSnapshotGenerations["_rt_FullFrameBuffer"] != state.sceneWriteGeneration)
        pool.pixelScale = 0.5
        #expect(!eligible(pass()))
        pool.pixelScale = 1
        pool.promotesLDRFormatsToHDR = false
        #expect(!eligible(pass()))
    }

    @Test("Cached fast and fallback PSOs preserve every HDR blend mode", arguments: 0 ... 32)
    func hdrPixelsMatch(mode: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard device.supportsFamily(.apple1) else { return }
        let executor = try WPEMetalRenderExecutor(device: device)
        let background = try texture(device)
        let layer = try texture(device)
        let output = try texture(device)
        let region = MTLRegionMake2D(0, 0, 17, 9)
        let alphas: [Float] = [0, 0.0005, 0.000999, 0.001, 0.001001, 0.5, 1]
        var bg: [UInt16] = []
        var fg: [UInt16] = []
        for index in 0 ..< 153 {
            let alpha = alphas[index % alphas.count]
            let ramp = Float(index % 17) / 16
            bg += [ramp * 4, 2 - ramp, ramp, 1].map { Float16($0).bitPattern }
            fg += [alpha * ramp, alpha * 0.7, alpha * (1 - ramp), alpha].map { Float16($0).bitPattern }
        }
        bg.withUnsafeBytes { background.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 136) }
        fg.withUnsafeBytes { layer.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 136) }
        var reference: [UInt16]?
        for fetch in [false, true, false, true] {
            bg.withUnsafeBytes { output.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 136) }
            let command = try #require(executor.textureSourceCommandQueue.makeCommandBuffer())
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = output
            descriptor.colorAttachments[0].loadAction = .load
            descriptor.colorAttachments[0].storeAction = .store
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
            try encoder.setRenderPipelineState(executor.passPipelineState(
                passID: "same-pass", variant: fetch ? .blendCompositeFramebufferFetch : .blendComposite,
                objectQuad: false, vertexName: "wpe_fullscreen_vertex",
                fragmentName: fetch ? "wpe_blend_composite_fetch_fragment" : "wpe_blend_composite_fragment",
                blendMode: "premultiplied", alphaWritePolicy: .all, colorPixelFormat: .rgba16Float, depthPixelFormat: .invalid
            ))
            encoder.setFragmentTexture(layer, index: 0)
            if !fetch {
                encoder.setFragmentTexture(background, index: 4)
            }
            var uniforms = WPEBlendCompositeUniforms(blendMode: Int32(mode))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<WPEBlendCompositeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var pixels = [UInt16](repeating: 0, count: bg.count)
            pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 136, from: region, mipmapLevel: 0) }
            if let reference {
                #expect(pixels == reference)
            } else {
                reference = pixels
            }
        }
    }
}

@Suite("WPEMetalShaderInputs — declared-FBO first-read zero fill")
struct WPEMetalDeclaredFBOZeroFillTests {
    private static let declaredName = "_rt_FullCompoBuffer1"

    @Test("A declared-but-unwritten FBO first read returns a cached zero stand-in")
    func declaredFBOFirstReadReturnsZeroTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try #require(Self.makeScratchTexture(device: device))
        let pool = WPEMetalRenderTargetPool(device: device)
        pool.prepare(pipeline: Self.pipelineDeclaring(Self.declaredName))

        let frameState = WPEMetalFrameState(
            output: output,
            sceneSize: CGSize(width: 4, height: 4),
            renderTargetPool: pool
        )
        let resolved = try WPEMetalShaderInputs.resolve(
            reference: .fbo(Self.declaredName),
            textures: [:],
            frameState: frameState,
            currentTargetID: .scene
        )
        #expect(resolved.pixelFormat == WPEMetalRenderExecutor.outputPixelFormat)
        #expect(resolved !== output)

        let again = try WPEMetalShaderInputs.resolve(
            reference: .fbo(Self.declaredName),
            textures: [:],
            frameState: frameState,
            currentTargetID: .scene
        )
        #expect(resolved === again)
    }

    @Test("A cursorripple EightBuffer first read is a discrete zero FBO, not the scene")
    func eightBufferFirstReadDoesNotResolveToScene() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try #require(Self.makeScratchTexture(device: device))
        let pool = WPEMetalRenderTargetPool(device: device)
        let name = "_rt_EightBuffer2"
        pool.prepare(pipeline: Self.pipelineDeclaring(name))

        let frameState = WPEMetalFrameState(
            output: output,
            sceneSize: CGSize(width: 4, height: 4),
            renderTargetPool: pool
        )
        let resolved = try WPEMetalShaderInputs.resolve(
            reference: .fbo(name),
            textures: [:],
            frameState: frameState,
            currentTargetID: .scene
        )

        #expect(WPETextureReference.isSceneAliasName(name) == false)
        #expect(resolved !== output)
    }

    @Test("An UNDECLARED FBO name still throws missingTexture")
    func undeclaredFBONameStillThrows() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try #require(Self.makeScratchTexture(device: device))
        let pool = WPEMetalRenderTargetPool(device: device)
        pool.prepare(pipeline: Self.pipelineDeclaring(Self.declaredName))

        let frameState = WPEMetalFrameState(
            output: output,
            sceneSize: CGSize(width: 4, height: 4),
            renderTargetPool: pool
        )
        #expect(throws: (any Error).self) {
            try WPEMetalShaderInputs.resolve(
                reference: .fbo("_rt_NotDeclaredAnywhere"),
                textures: [:],
                frameState: frameState,
                currentTargetID: .scene
            )
        }
    }

    private static func pipelineDeclaring(_ fboName: String) -> WPEPreparedRenderPipeline {
        let layer = WPERenderLayer(
            objectID: "obj",
            objectName: "obj",
            imagePath: "",
            materialPath: nil,
            geometry: .identity,
            compositeA: "comp_a",
            compositeB: "comp_b",
            localFBOs: [WPERenderFBO(name: fboName, scale: 1, format: "rgba8888", unique: true)],
            passes: []
        )
        return WPEPreparedRenderPipeline(
            layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: [])]
        )
    }

    private static func makeScratchTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 4,
            height: 4,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }
}

@Suite("WPEMetalRenderTargetPool — FBO format mapping")
struct WPEMetalFBOFormatMappingTests {
    // Official engine effects author these (survey of oracle-engine-root
    // assets/effects/*/effect.json): r16f ×4 (fluidsimulation pressure),
    // rg1616f ×2 (velocity). Falling back to 8-bit RGBA destroys the
    // simulation's precision and channel count.
    @Test("r16f and rg1616f map to single/dual-channel float formats")
    func floatFormatsKeepChannelShape() {
        #expect(WPEMetalRenderTargetPool.pixelFormat(forFBOFormat: "r16f", promoteLDRToHDR: false) == .r16Float)
        #expect(WPEMetalRenderTargetPool.pixelFormat(forFBOFormat: "rg1616f", promoteLDRToHDR: false) == .rg16Float)
        // Already-float formats must not be re-promoted or demoted under HDR.
        #expect(WPEMetalRenderTargetPool.pixelFormat(forFBOFormat: "r16f", promoteLDRToHDR: true) == .r16Float)
        #expect(WPEMetalRenderTargetPool.pixelFormat(forFBOFormat: "rg1616f", promoteLDRToHDR: true) == .rg16Float)
    }
}
