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
        builtin: Bool = true, bindings: [Int: WPETextureReference]? = nil, binds: [Int: WPETextureReference] = [:],
        color: [Double]? = nil, transformed: Bool = true, blending: String? = nil, cullMode: String = "nocull"
    ) -> WPEPreparedRenderLayer {
        let colors: [[Double]] = [[0.2, 0.6, 1.5, 1], [1.2, 0.1, 0.4, 0.35],
                                  [0.3, 1.4, 0.1, 0.6], [0.8, 0.2, 0.9, 0.15]]
        let modes = ["premultiplied", "additive", "premultiplied", "premultiplied"]
        let graphPass = WPERenderPass(
            id: "solid-\(index).0", phase: .material, shader: shader, source: source, target: target,
            textures: [:], binds: binds, constants: ["g_Color": .vector(color ?? colors[index % 4])],
            combos: [:], blending: blending ?? (shader == "solidlayer" ? modes[index % 4] : "disabled"),
            cullMode: cullMode, depthTest: depthTest, depthWrite: "disabled"
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
        _ executor: WPEMetalRenderExecutor, pipeline: WPEPreparedRenderPipeline, hdr: Bool,
        textures: [String: MTLTexture] = [:]
    ) throws -> [UInt8] {
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: Double(size.width), height: Double(size.height), auto: true),
            sceneCamera: .defaultCamera, sceneHDR: hdr
        )
        let output = try executor.render(pipeline: pipeline, size: size, textures: textures, cameraUniforms: camera)
        #expect(output.pixelFormat == (hdr ? MTLPixelFormat.rgba16Float : MTLPixelFormat.rgba8Unorm_srgb))
        return try bytes(output)
    }

    @Test("Diagnostic controls are independent, strict and disabled by default")
    func diagnosticEnvironmentControls() {
        let defaults = WPEMetalRenderExecutor.DiagnosticControls()
        #expect(!defaults.disableParticleBatching && !defaults.disableSolidBatching && !defaults.disableFBOAliasing)
        #expect(!defaults.disableSceneAliasDirectBind)
        for key in ["PARTICLE_BATCHING", "SOLID_BATCHING", "FBO_ALIASING", "SCENE_ALIAS_DIRECT_BIND"] {
            let controls = WPEMetalRenderExecutor.DiagnosticControls(environment: ["WPE_DIAGNOSTIC_DISABLE_" + key: "1"])
            #expect(controls.disableParticleBatching == (key == "PARTICLE_BATCHING"))
            #expect(controls.disableSolidBatching == (key == "SOLID_BATCHING"))
            #expect(controls.disableFBOAliasing == (key == "FBO_ALIASING"))
            #expect(controls.disableSceneAliasDirectBind == (key == "SCENE_ALIAS_DIRECT_BIND"))
            #expect(WPEMetalRenderExecutor.DiagnosticControls(environment: ["WPE_DIAGNOSTIC_DISABLE_" + key: "true"]) == defaults)
        }
    }

    @Test("Solid diagnostic bypass does not get re-enabled through experimental quad sharing")
    func diagnosticSolidBypass() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let baseline = try WPEMetalRenderExecutor(device: device, diagnosticControls: .init())
        let disabled = try WPEMetalRenderExecutor(device: device, diagnosticControls: .init(environment: [
            "WPE_DIAGNOSTIC_DISABLE_SOLID_BATCHING": "1",
        ]))
        baseline.sceneQuadBatchingEnabled = true
        disabled.sceneQuadBatchingEnabled = true
        let pipeline = WPEPreparedRenderPipeline(layers: (0 ..< 4).map { layer($0) })
        let expected = try renderBytes(baseline, pipeline: pipeline, hdr: true)
        let actual = try renderBytes(disabled, pipeline: pipeline, hdr: true)
        #expect(actual == expected)
        #expect(baseline.lastSolidSceneBatchStats.draws == 4)
        #expect(disabled.lastSolidSceneBatchStats.draws == 0)
        #expect(!disabled.lastDiagnosticFrameStats.solidBatchingEnabled)
        #expect(disabled.lastDiagnosticFrameStats.sceneQuadBatchingEnabled)
        #expect(!disabled.lastDiagnosticFrameStats.perPassReadbackActive)
        #expect(disabled.lastDiagnosticFrameStats.fboAliasingEnabled)
    }

    @MainActor
    @Test("Particle diagnostic bypass uses independent encoders without readbacks")
    func diagnosticParticleBypass() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 1, "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 8, "max": 8],
                            ["name": "lifetimerandom", "min": 10, "max": 10]],
        ]))
        var systems: [WPEParticleSystem] = []
        var textures: [ObjectIdentifier: MTLTexture] = [:]
        for index in 0 ..< 3 {
            let system = try #require(WPEParticleSystem(
                definition: definition, device: device,
                sceneTransform: WPEParticleSceneTransform(
                    sceneSize: SIMD2<Float>(33, 17), objectOrigin: SIMD3<Float>(16.5, 8.5, 0),
                    objectScale: SIMD3<Float>(repeating: 1), objectAngleZ: 0
                ), seed: UInt64(index + 1)
            ))
            system.tick(now: 0)
            system.tick(now: 0.05)
            try #require(system.liveInstanceCount == 1)
            systems.append(system)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            let texture = try #require(device.makeTexture(descriptor: descriptor))
            let color = [Float16(index == 0 ? 1.5 : 0.125), Float16(index == 1 ? 1.5 : 0.125),
                         Float16(index == 2 ? 1.5 : 0.125), Float16(0.5)].map(\.bitPattern)
            color.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8)
            }
            textures[ObjectIdentifier(system)] = texture
        }
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: 33, height: 17, auto: true),
            sceneCamera: .defaultCamera, sceneHDR: true
        )
        var expected: [UInt8]?
        for disable in [false, true] {
            let executor = try WPEMetalRenderExecutor(device: device, diagnosticControls: .init(environment:
                disable ? ["WPE_DIAGNOSTIC_DISABLE_PARTICLE_BATCHING": "1"] : [:]))
            let output = try executor.render(pipeline: .init(layers: []), size: size, textures: [:], cameraUniforms: camera,
                                             particleSystems: systems, particleTextures: textures)
            let actual = try bytes(output)
            #expect(actual.contains { $0 != 0 })
            if let expected {
                #expect(actual == expected)
            } else {
                expected = actual
            }
            let stats = executor.lastDiagnosticFrameStats
            #expect(stats.particleSystemsEncoded == 3)
            #expect(stats.particleEncoderCount == (disable ? 3 : 1))
            #expect(stats.particleBatchingEnabled == !disable)
            #expect(!stats.perPassReadbackActive)
            #expect(stats.solidBatchingEnabled && stats.fboAliasingEnabled)
        }
    }

    @Test("Canonical rotation preserves raw HDR output and external A consumers", arguments: [2, 4])
    func canonicalRotationHDR(count: Int) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ payload: [String: Any], _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: payload).write(to: url)
        }
        try write(["material": "materials/base.json"], "models/image.json")
        try write(["passes": [["shader": "copy", "textures": ["source"], "blending": "disabled"]]], "materials/base.json")
        try write(["passes": Array(repeating: ["material": "materials/effect.json"], count: count - 1)], "effects/chain.json")
        try write(["passes": [["shader": "copy", "blending": "disabled"]]], "materials/effect.json")
        let names = WPERenderTargetNames.ImageLayerComposite.make(objectID: "701")
        try write(["material": "materials/consumer.json"], "models/consumer.json")
        try write(["passes": [["shader": "copy", "textures": [names.a], "blending": "disabled"]]], "materials/consumer.json")
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0", "eye": "0 0 1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": size.width, "height": size.height]],
            "objects": [
                ["id": 701, "name": "Producer", "image": "models/image.json", "size": "33 17", "origin": "16.5 8.5 0",
                 "effects": [["id": 702, "file": "effects/chain.json"]]],
                ["id": 703, "name": "Consumer", "image": "models/consumer.json", "size": "33 17", "origin": "16.5 8.5 0",
                 "dependencies": [701]],
            ],
        ]))
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let builder = WPERenderPipelineBuilder(cacheRootURL: root)
        let baseline = try builder.build(graph: graph, canonicalCompositeRotationEnabled: false, sceneHDR: true)
        let optimized = try builder.build(graph: graph, canonicalCompositeRotationEnabled: true, sceneHDR: true)
        #expect(optimized.layers[0].passes.count == baseline.layers[0].passes.count - 1)
        #expect(optimized.layers[1] == baseline.layers[1])
        #expect(optimized.layers[1].passes[0].textureBindings[0] == .fbo(names.a))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(size.width), height: Int(size.height), mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try #require(device.makeTexture(descriptor: descriptor))
        let referenceExecutor = try WPEMetalRenderExecutor(device: device)
        let optimizedExecutor = try WPEMetalRenderExecutor(device: device)
        let noAliasExecutor = try WPEMetalRenderExecutor(device: device, diagnosticControls: .init(environment: [
            "WPE_DIAGNOSTIC_DISABLE_FBO_ALIASING": "1",
        ]))
        var previous: [UInt8]?
        for frame in 0 ..< 2 {
            let pixels = (0 ..< (input.width * input.height)).flatMap { index -> [UInt16] in
                [Float16(1.5 + Double((index + frame) % 7) * 0.125).bitPattern,
                 Float16(0.25 + Double(frame) * 0.125).bitPattern, Float16(0.75).bitPattern, Float16(0.5).bitPattern]
            }
            pixels.withUnsafeBytes {
                input.replace(region: MTLRegionMake2D(0, 0, input.width, input.height), mipmapLevel: 0,
                              withBytes: $0.baseAddress!, bytesPerRow: input.width * 8)
            }
            let reference = try renderBytes(referenceExecutor, pipeline: baseline, hdr: true, textures: ["source": input])
            let actual = try renderBytes(optimizedExecutor, pipeline: optimized, hdr: true, textures: ["source": input])
            #expect(actual == reference)
            let unaliased = try renderBytes(noAliasExecutor, pipeline: baseline, hdr: true, textures: ["source": input])
            #expect(unaliased == reference)
            #expect(noAliasExecutor.lastDiagnosticFrameStats.plannedAliasIntervalCount > 0)
            #expect(noAliasExecutor.lastDiagnosticFrameStats.aliasIntervalCount == 0)
            #expect(!noAliasExecutor.lastDiagnosticFrameStats.fboAliasingEnabled)
            #expect(referenceExecutor.lastDiagnosticFrameStats.aliasIntervalCount > 0)
            // Raw half floats prove the fixture exercises HDR and alpha, not a clamped hash.
            let red = Float16(bitPattern: UInt16(actual[0]) | UInt16(actual[1]) << 8)
            let alpha = Float16(bitPattern: UInt16(actual[6]) | UInt16(actual[7]) << 8)
            #expect(red > 1)
            #expect(alpha == 0.5)
            if let previous {
                #expect(actual != previous)
            }
            previous = actual
        }
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

    /// A full-frame effect layer's shape: capture the scene into the layer's own
    /// composite, then copy that composite back to the scene. `leadingScenePass`
    /// prepends a solid scene write so the capture follows an own-layer scene write.
    private func sceneAliasReaderLayer(
        _ index: Int, leadingScenePass: Bool = false, previousBind: Bool = false, readerTarget: String? = nil
    ) -> WPEPreparedRenderLayer {
        let name = readerTarget ?? "solid-\(index)-a"
        var parts: [WPEPreparedRenderLayer] = []
        if leadingScenePass {
            parts.append(layer(index, transformed: false))
        }
        parts.append(layer(index + 1, shader: "commands/copy", source: .fbo("_rt_FullFrameBuffer"),
                           target: readerTarget.map { .fbo(name: $0) } ?? .layerComposite(name: name),
                           binds: previousBind ? [1: .previous] : [:], transformed: false))
        parts.append(layer(index + 2, shader: "commands/copy", source: .fbo(name), transformed: false))
        let graph = layer(index, transformed: false).graphLayer
        let passes = parts.flatMap(\.passes)
        return WPEPreparedRenderLayer(graphLayer: WPERenderLayer(
            objectID: graph.objectID, objectName: graph.objectName, visible: true,
            imagePath: graph.imagePath, materialPath: nil, geometry: graph.geometry,
            compositeA: name, compositeB: graph.compositeB, localFBOs: [],
            passes: passes.map(\.pass), sortIndex: index
        ), passes: passes)
    }

    private func sceneAliasExecutor(_ device: MTLDevice, forceSnapshot: Bool) throws -> WPEMetalRenderExecutor {
        try WPEMetalRenderExecutor(device: device, diagnosticControls: .init(environment:
            forceSnapshot ? ["WPE_DIAGNOSTIC_DISABLE_SCENE_ALIAS_DIRECT_BIND": "1"] : [:]))
    }

    @Test("A layer's first scene-alias read into its own composite binds the live scene, byte-identical to a snapshot")
    func sceneAliasDirectBindMatchesSnapshot() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipeline = WPEPreparedRenderPipeline(layers: [layer(0), sceneAliasReaderLayer(1), layer(4)])
        let forced = try sceneAliasExecutor(device, forceSnapshot: true)
        let expected = try renderBytes(forced, pipeline: pipeline, hdr: true)
        #expect(expected.contains { $0 != 0 })
        #expect(forced.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 1)
        #expect(forced.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
        let direct = try sceneAliasExecutor(device, forceSnapshot: false)
        let actual = try renderBytes(direct, pipeline: pipeline, hdr: true)
        #expect(actual == expected)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 0)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasDirectBinds == 1)
    }

    @Test("A scene-targeted alias read keeps the snapshot")
    func sceneAliasReadIntoSceneStillSnapshots() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let capture = layer(2, shader: "commands/copy", source: .fbo("_rt_FullFrameBuffer"), transformed: false)
        let pipeline = WPEPreparedRenderPipeline(layers: [layer(0), layer(1), capture, layer(3)])
        let direct = try sceneAliasExecutor(device, forceSnapshot: false)
        _ = try renderBytes(direct, pipeline: pipeline, hdr: true)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 1)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
    }

    @Test("An alias read after an own-layer scene write keeps the snapshot and sees that write")
    func sceneAliasReadAfterOwnSceneWriteStillSnapshots() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipeline = WPEPreparedRenderPipeline(layers: [layer(0), sceneAliasReaderLayer(1, leadingScenePass: true)])
        let forced = try sceneAliasExecutor(device, forceSnapshot: true)
        let expected = try renderBytes(forced, pipeline: pipeline, hdr: true)
        #expect(forced.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 1)
        let direct = try sceneAliasExecutor(device, forceSnapshot: false)
        let actual = try renderBytes(direct, pipeline: pipeline, hdr: true)
        #expect(actual == expected)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 1)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
        // The capture is taken at the read, after this layer's own solid pass, so the
        // full-frame round trip is an identity over [layer 0, solid 1]. Had it seen the
        // pre-write scene, the copy-back would have erased the solid.
        let afterOwnWrite = try renderBytes(direct, pipeline: .init(layers: [layer(0), layer(1, transformed: false)]), hdr: true)
        let beforeOwnWrite = try renderBytes(direct, pipeline: .init(layers: [layer(0)]), hdr: true)
        #expect(actual == afterOwnWrite)
        #expect(actual != beforeOwnWrite)
    }

    @Test("A second reader layer after an intervening scene write sees the new content on both paths")
    func sceneAliasReadAcrossLayersIsFresh() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(0), sceneAliasReaderLayer(1), layer(4), sceneAliasReaderLayer(5),
        ])
        // Each full-frame reader is an identity round trip, so a fresh second read leaves
        // the frame equal to [layer 0, layer 4]; a stale read of layer 1's capture would
        // copy back the scene as it stood before layer 4 (layer 0 alone).
        let forced = try sceneAliasExecutor(device, forceSnapshot: true)
        let fresh = try renderBytes(forced, pipeline: .init(layers: [layer(0), layer(4)]), hdr: true)
        let stale = try renderBytes(forced, pipeline: .init(layers: [layer(0)]), hdr: true)
        #expect(fresh != stale)
        let expected = try renderBytes(forced, pipeline: pipeline, hdr: true)
        #expect(expected == fresh)
        #expect(forced.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 2)
        #expect(forced.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
        let direct = try sceneAliasExecutor(device, forceSnapshot: false)
        let actual = try renderBytes(direct, pipeline: pipeline, hdr: true)
        #expect(actual == fresh)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 0)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasDirectBinds == 2)
    }

    @Test("A pre-write alias read on a later frame keeps the capture path instead of binding the stale output")
    func sceneAliasReadBeforeAnySceneWriteStillCaptures() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // The reader is the first layer, so on frame 2 `output` still holds frame 1 when
        // the alias is read; the capture path clears the snapshot instead of copying.
        let pipeline = WPEPreparedRenderPipeline(layers: [sceneAliasReaderLayer(1), layer(4)])
        let forced = try sceneAliasExecutor(device, forceSnapshot: true)
        _ = try renderBytes(forced, pipeline: pipeline, hdr: true)
        let expected = try renderBytes(forced, pipeline: pipeline, hdr: true)
        #expect(expected.contains { $0 != 0 })
        #expect(forced.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 0)
        #expect(forced.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
        let direct = try sceneAliasExecutor(device, forceSnapshot: false)
        _ = try renderBytes(direct, pipeline: pipeline, hdr: true)
        let actual = try renderBytes(direct, pipeline: pipeline, hdr: true)
        #expect(actual == expected)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 0)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
        // Documents why the byte comparison alone cannot catch a stale bind here: the
        // initial-clear elision rejects a scene-alias read in the first layer's prefix,
        // so `output` is cleared up front. The counter is the load-bearing assertion.
        #expect(direct.lastInitialSceneClearStats.rejectReason == "unproven-fbo-read")
    }

    @Test("A raw `.previous` bind on a non-scene target still binds the live scene, byte-identical to a snapshot")
    func sceneAliasDirectBindSurvivesPreviousBindOnOwnTarget() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // The reader targets its own composite and carries a raw `bind: previous` (bloom's
        // light_map/apply shape): `.previous` resolves to that composite's history, which
        // is independent of which texture the scene-alias slot binds.
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(0), sceneAliasReaderLayer(1, previousBind: true), layer(4),
        ])
        let forced = try sceneAliasExecutor(device, forceSnapshot: true)
        let expected = try renderBytes(forced, pipeline: pipeline, hdr: true)
        #expect(expected.contains { $0 != 0 })
        #expect(forced.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 1)
        #expect(forced.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
        let direct = try sceneAliasExecutor(device, forceSnapshot: false)
        let actual = try renderBytes(direct, pipeline: pipeline, hdr: true)
        #expect(actual == expected)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 0)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasDirectBinds == 1)
    }

    @Test("A `.previous` reader whose target IS the alias name keeps the snapshot")
    func sceneAliasPreviousReadIntoAliasNamedTargetStillSnapshots() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Here `.previous` resolves to `latestNamedTextures["_rt_FullFrameBuffer"]`, the
        // very entry a direct bind would drop, so the capture must stay.
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(0), sceneAliasReaderLayer(1, previousBind: true, readerTarget: "_rt_FullFrameBuffer"), layer(4),
        ])
        let forced = try sceneAliasExecutor(device, forceSnapshot: true)
        let expected = try renderBytes(forced, pipeline: pipeline, hdr: true)
        #expect(expected.contains { $0 != 0 })
        #expect(forced.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 1)
        let direct = try sceneAliasExecutor(device, forceSnapshot: false)
        let actual = try renderBytes(direct, pipeline: pipeline, hdr: true)
        #expect(actual == expected)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 1)
        #expect(direct.lastDiagnosticFrameStats.sceneAliasDirectBinds == 0)
    }

    @Test("Full-frame passthrough elision renders byte-identical to the kept passthrough")
    func fullFramePassthroughElisionHDR() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ payload: [String: Any], _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: payload).write(to: url)
        }
        try write(["material": "materials/base.json"], "models/image.json")
        try write(["passes": [["shader": "copy", "textures": ["source"], "blending": "disabled"]]], "materials/base.json")
        try write(["material": "materials/util/fullscreenlayer.json", "fullscreen": true, "passthrough": true],
                  "models/util/fullscreenlayer.json")
        try write(
            ["passes": [["shader": "composelayer", "textures": ["_rt_FullFrameBuffer"], "blending": "translucent",
                         "depthtest": "disabled", "depthwrite": "disabled", "cullmode": "nocull"]]],
            "materials/util/fullscreenlayer.json"
        )
        try write(["passes": [["material": "materials/effect.json"]]], "effects/chain.json")
        try write(["passes": [["shader": "copy", "blending": "disabled"]]], "materials/effect.json")
        // A dependent consumer keeps the canonical A copy, so the passthrough lands in the rotated `_b`.
        let names = WPERenderTargetNames.ImageLayerComposite.make(objectID: "702")
        try write(["material": "materials/consumer.json"], "models/consumer.json")
        try write(["passes": [["shader": "copy", "textures": [names.a], "blending": "disabled"]]], "materials/consumer.json")
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0", "eye": "0 0 1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": size.width, "height": size.height]],
            "objects": [
                ["id": 701, "name": "Producer", "image": "models/image.json", "size": "33 17", "origin": "16.5 8.5 0"],
                ["id": 702, "name": "Post", "image": "models/util/fullscreenlayer.json",
                 "effects": [["id": 703, "file": "effects/chain.json"]]],
                ["id": 704, "name": "Consumer", "image": "models/consumer.json", "size": "33 17", "origin": "16.5 8.5 0",
                 "dependencies": [702]],
            ],
        ]))
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let builder = WPERenderPipelineBuilder(cacheRootURL: root)
        let kept = try builder.build(graph: graph, canonicalCompositeRotationEnabled: true, sceneHDR: true,
                                     fullFramePassthroughElisionEnabled: false)
        let built = try builder.buildReportingCanonicalRotation(
            graph: graph, canonicalCompositeRotationEnabled: true, sceneHDR: true, fullFramePassthroughElisionEnabled: true
        )
        #expect(built.canonicalRotation.decisions["702"] == "rotated")
        #expect(built.fullFramePassthroughElision == WPEFullFramePassthroughElisionReport(
            enabled: true, decisions: ["702": "elided"]
        ))
        #expect(kept.layers[1].passes[0].pass.target == .layerComposite(name: names.b))
        #expect(built.pipeline.layers[1].passes.count == kept.layers[1].passes.count - 1)
        #expect(built.pipeline.layers[1].passes.map(\.id) == Array(kept.layers[1].passes.map(\.id).dropFirst()))
        #expect(built.pipeline.layers[1].passes[0].textureBindings[0] == .fbo("_rt_FullFrameBuffer"))
        #expect(built.pipeline.layers[1].passes[0].pass.target == .layerComposite(name: names.a))
        #expect(built.pipeline.layers[0] == kept.layers[0])
        #expect(built.pipeline.layers[2] == kept.layers[2])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: Int(size.width), height: Int(size.height), mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let input = try #require(device.makeTexture(descriptor: descriptor))
        let keptExecutor = try WPEMetalRenderExecutor(device: device)
        let elidedExecutor = try WPEMetalRenderExecutor(device: device)
        for frame in 0 ..< 2 {
            let pixels = (0 ..< (input.width * input.height)).flatMap { index -> [UInt16] in
                [Float16(1.5 + Double((index + frame) % 7) * 0.125).bitPattern,
                 Float16(0.25 + Double(frame) * 0.125).bitPattern, Float16(0.75).bitPattern, Float16(0.5).bitPattern]
            }
            pixels.withUnsafeBytes {
                input.replace(region: MTLRegionMake2D(0, 0, input.width, input.height), mipmapLevel: 0,
                              withBytes: $0.baseAddress!, bytesPerRow: input.width * 8)
            }
            let reference = try renderBytes(keptExecutor, pipeline: kept, hdr: true, textures: ["source": input])
            let actual = try renderBytes(elidedExecutor, pipeline: built.pipeline, hdr: true, textures: ["source": input])
            #expect(reference.contains { $0 != 0 })
            #expect(actual == reference)
            #expect(keptExecutor.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 0)
            #expect(elidedExecutor.lastDiagnosticFrameStats.sceneAliasSnapshotBlits == 0)
            #expect(elidedExecutor.lastDiagnosticFrameStats.sceneAliasDirectBinds == 1)
        }
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

    private func patternedTexture(_ device: MTLDevice, flipped: Bool = false) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 4, height: 2, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .pixelFormatView, .renderTarget]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let values = (0 ..< 8).flatMap { index -> [Float16] in
            let alpha: Float16 = index % 2 == 0 ? 0.4 : 0.8
            return [Float16(flipped ? 7 - index : index) / 3, 0.2, 0.7, alpha]
        }
        values.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 4 * 8)
        }
        return texture
    }

    @Test("Mixed solid copy image runs rebind textures and uniforms, preserving raw HDR and SDR bytes",
          arguments: [false, true])
    func mixedTexturedSceneRuns(hdr: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let first = try patternedTexture(device)
        let second = try patternedTexture(device, flipped: true)
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(0),
            layer(1, shader: "commands/copy", source: .asset("first"), blending: "premultiplied"),
            layer(2, shader: "genericimage2", source: .asset("second"), blending: "additive", cullMode: "front"),
            layer(3),
            layer(4, shader: "commands/copy", source: .asset("second"), blending: "premultiplied", cullMode: "back"),
            layer(5, shader: "genericimage2", source: .asset("first"), blending: "premultiplied"),
        ])
        for textures in [["first": first, "second": second], ["first": second, "second": first]] {
            executor.solidSceneBatchingEnabled = false
            executor.sceneQuadBatchingEnabled = false
            let expected = try renderBytes(executor, pipeline: pipeline, hdr: hdr, textures: textures)
            executor.solidSceneBatchingEnabled = true
            executor.sceneQuadBatchingEnabled = true
            let actual = try renderBytes(executor, pipeline: pipeline, hdr: hdr, textures: textures)
            #expect(actual == expected)
            #expect(actual.contains { $0 != 0 })
            #expect(executor.lastSceneQuadBatchStats.encoders == 1)
            #expect(executor.lastSceneQuadBatchStats.draws == 6)
            #expect(executor.lastSceneQuadBatchStats.texturedDraws == 4)
            let reversed = WPEPreparedRenderPipeline(layers: Array(pipeline.layers.reversed()))
            #expect(try renderBytes(executor, pipeline: reversed, hdr: hdr, textures: textures) != expected)
        }
    }

    @Test("Texture admission rejects scene views, unresolved inputs, media substitution and dependencies")
    func texturedEligibilityRejectsPhysicalHazards() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try patternedTexture(device)
        let independent = try patternedTexture(device, flipped: true)
        let view = try #require(output.makeTextureView(pixelFormat: .rgba16Float))
        let copy = layer(0, shader: "commands/copy", source: .asset("source"))
        func reason(_ texture: MTLTexture?, media: Bool = false) -> String? {
            WPEMetalSolidSceneRun.texturedRejectionReason(
                copy, textures: texture.map { ["source": $0] } ?? [:],
                output: output, hasMediaSubstitution: media
            )
        }
        #expect(reason(independent) == nil)
        #expect(reason(output) == "attachment-alias")
        #expect(reason(view) == "attachment-alias")
        #expect(reason(nil) == "unresolved-texture")
        #expect(reason(independent, media: true) == "media-substitution")
        for dependency in [WPETextureReference.previous, .fbo("_rt_FullFrameBuffer"), .fbo("independent-fbo")] {
            let candidate = layer(0, shader: "commands/copy", source: .asset("source"), bindings: [8: dependency])
            #expect(WPEMetalSolidSceneRun.texturedRejectionReason(
                candidate, textures: ["source": independent], output: output,
                hasMediaSubstitution: false
            ) == "target-dependency")
        }
    }

    @Test("A scene read ends an extended quad run before the snapshot blit")
    func snapshotSeparatesTexturedRuns() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let textures = try ["source": patternedTexture(device)]
        let pipeline = WPEPreparedRenderPipeline(layers: [
            layer(0), layer(1, shader: "genericimage2", source: .asset("source")),
            layer(2, shader: "commands/copy", source: .fbo("_rt_FullFrameBuffer"), transformed: false),
            layer(3), layer(4, shader: "commands/copy", source: .asset("source")),
        ])
        executor.solidSceneBatchingEnabled = false
        let expected = try renderBytes(executor, pipeline: pipeline, hdr: true, textures: textures)
        executor.solidSceneBatchingEnabled = true
        executor.sceneQuadBatchingEnabled = true
        let actual = try renderBytes(executor, pipeline: pipeline, hdr: true, textures: textures)
        #expect(actual == expected)
        #expect(executor.lastSceneQuadBatchStats.encoders == 2)
        #expect(executor.lastSceneQuadBatchStats.draws == 4)
        #expect(executor.lastSceneQuadBatchStats.rejectedPasses["target-dependency"] == 1)
    }

    private func compositedLayer(_ index: Int) throws -> WPEPreparedRenderLayer {
        let name = "solid-\(index)-a"
        let producer = layer(index, target: .layerComposite(name: name),
                             color: [0.6, 0.4, 1.2, 0.35], transformed: false)
        let copy = layer(index + 1, shader: "commands/copy", source: .fbo(name),
                         transformed: false, blending: "premultiplied")
        let graph = producer.graphLayer
        let passes = producer.passes + copy.passes
        return WPEPreparedRenderLayer(graphLayer: WPERenderLayer(
            objectID: graph.objectID, objectName: graph.objectName, visible: true,
            imagePath: graph.imagePath, materialPath: nil, geometry: graph.geometry,
            compositeA: graph.compositeA, compositeB: graph.compositeB, localFBOs: [],
            passes: passes.map(\.pass), sortIndex: index
        ), passes: passes)
    }

    @Test("A final FBO copy shares with image4 while a later producer ends the lease",
          arguments: [false, true])
    func finalCopyToMaskedImagePreservesOutput(hdr: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let textures = try ["image": patternedTexture(device), "mask": patternedTexture(device, flipped: true)]
        let masked = layer(2, shader: "genericimage4", source: .asset("image"),
                           bindings: [0: .asset("image"), 1: .asset("mask")], blending: "premultiplied")
        let fallback = layer(3, shader: "genericimage4", source: .asset("mask"), blending: "additive")
        let pipeline = try WPEPreparedRenderPipeline(layers: [
            compositedLayer(0), masked, fallback, compositedLayer(4), layer(6),
        ])
        executor.solidSceneBatchingEnabled = false
        executor.sceneQuadBatchingEnabled = false
        let expected = try renderBytes(executor, pipeline: pipeline, hdr: hdr, textures: textures)
        executor.solidSceneBatchingEnabled = true
        executor.sceneQuadBatchingEnabled = true
        for _ in 0 ..< 3 {
            let actual = try renderBytes(executor, pipeline: pipeline, hdr: hdr, textures: textures)
            #expect(actual == expected)
            #expect(executor.lastSceneQuadBatchStats.encoders == 2)
            #expect(executor.lastSceneQuadBatchStats.draws == 5)
            #expect(executor.lastSceneQuadBatchStats.texturedDraws == 4)
        }
        // Changing the mask must affect output: this is not a fixture of invisible draws.
        let primary = try #require(textures["image"])
        let swapped = ["image": primary, "mask": primary]
        #expect(try renderBytes(executor, pipeline: pipeline, hdr: hdr, textures: swapped) != expected)
    }

    @Test("History and cache seeds are not evidence of a named FBO write this frame")
    func finalCopyRejectsUnwrittenNamedTexture() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let output = try patternedTexture(device)
        let source = try patternedTexture(device, flipped: true)
        let chain = try compositedLayer(0)
        let copy = try #require(chain.passes.last)
        var frame = WPEMetalFrameState(
            output: output, sceneSize: size, previousNamedTextures: ["solid-0-a": source]
        )
        func reason() -> String? {
            WPEMetalSolidSceneRun.texturedRejectionReason(
                chain, textures: [:], output: output, hasMediaSubstitution: false,
                finalCopyPass: copy, frameState: frame
            )
        }
        #expect(reason() == "fbo-not-written-this-frame")
        frame.markInitialized(source)
        frame.seedPreviousTexture(source, targetID: .named("solid-0-a"))
        #expect(reason() == "fbo-not-written-this-frame")
        frame.registerWrite(texture: source, targetID: .named("solid-0-a"))
        #expect(reason() == nil)
        frame.registerWrite(texture: output, targetID: .named("solid-0-a"))
        #expect(reason() == "attachment-alias")
    }

    @Test("Deferred alias end-pass callbacks run once and only after the encoder closes")
    func aliasLeaseReleaseFollowsEncoderEnd() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = try patternedTexture(device)
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store
        var released: [Int] = []
        var activeRun: WPEMetalSolidSceneRun?
        let run = WPEMetalSolidSceneRun { index in
            // Metal validation rejects a second encoder if end() releases leases
            // before closing the old render encoder.
            #expect(activeRun?.encoder == nil)
            let blit = command.makeBlitCommandEncoder()
            #expect(blit != nil)
            blit?.endEncoding()
            released.append(index)
        }
        activeRun = run
        run.encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
        run.deferEndPass(7)
        run.deferEndPass(8)
        #expect(released.isEmpty)
        run.end()
        #expect(released == [7, 8])
        run.end()
        #expect(released == [7, 8])
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        activeRun = nil
    }

    @Test("A failed frame releases the preceding final-copy run before the next FBO allocation")
    func failureReleasesFinalCopyLease() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.sceneQuadBatchingEnabled = true
        let broken = try WPEPreparedRenderPipeline(layers: [
            compositedLayer(0), layer(2),
            layer(3, shader: "commands/copy", source: .asset("absent")),
        ])
        #expect(throws: (any Error).self) {
            try executor.render(pipeline: broken, size: size, textures: [:])
        }
        let valid = try WPEPreparedRenderPipeline(layers: [compositedLayer(0), layer(2)])
        let actual = try renderBytes(executor, pipeline: valid, hdr: true)
        executor.sceneQuadBatchingEnabled = false
        executor.solidSceneBatchingEnabled = false
        #expect(try renderBytes(executor, pipeline: valid, hdr: true) == actual)
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
