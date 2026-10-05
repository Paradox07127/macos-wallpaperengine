import Darwin
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("WPE render pipeline builder")
struct WPERenderPipelineBuilderTests {
    @Test("Native sibling GPU source and interior probes match gated reopen", .serialized, arguments: ["9000543", "9200544", "9200545"])
    func nativeEffectSiblingGPU(sceneID: String) throws {
        let fixture = try nativeSiblingFixture(sceneID: sceneID)
        defer { fixture.cleanup() }
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: fixture.root.appendingPathComponent("scene.json")))
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let raw = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let canonical = WPERenderGraphBuilder.preparingEffectPublication(in: raw, camera: camera, permitsVisibilityGates: true)
        let owner = try #require(canonical.layers.first { $0.graphLayer.objectID == "947100" })
        _ = try #require(owner.effectPublication)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let expected: [String: [[[Int]]]] = [
            "9000543": [
                [
                    [88, 24, 255, 255, 255, 255],
                    [88, 40, 255, 255, 255, 255],
                    [112, 40, 255, 255, 255, 255],
                    [136, 40, 255, 255, 255, 255],
                    [160, 40, 255, 255, 255, 255],
                    [184, 40, 255, 255, 255, 255],
                    [88, 56, 255, 255, 255, 255],
                    [112, 56, 255, 255, 255, 255],
                    [136, 56, 255, 255, 255, 255],
                    [160, 56, 255, 255, 255, 255],
                    [184, 56, 255, 255, 255, 255],
                    [208, 56, 255, 255, 255, 255],
                    [88, 72, 255, 255, 255, 255],
                    [112, 72, 255, 255, 255, 255],
                    [136, 72, 255, 255, 255, 255],
                    [160, 72, 255, 255, 255, 255],
                    [184, 72, 255, 255, 255, 255],
                    [208, 72, 255, 255, 255, 255],
                    [88, 88, 255, 255, 255, 255],
                    [112, 88, 255, 255, 255, 255],
                    [136, 88, 255, 255, 255, 255],
                    [160, 88, 255, 255, 255, 255],
                    [184, 88, 255, 255, 255, 255],
                    [208, 88, 255, 255, 255, 255],
                    [88, 104, 255, 255, 255, 255],
                    [112, 104, 255, 255, 255, 255],
                    [136, 104, 255, 255, 255, 255],
                    [160, 104, 255, 255, 255, 255],
                    [184, 104, 255, 255, 255, 255],
                    [208, 104, 255, 255, 255, 255],
                ],
                [
                    [160, 40, 255, 255, 255, 255],
                    [184, 40, 255, 255, 255, 255],
                    [208, 40, 255, 255, 255, 255],
                    [64, 56, 255, 255, 255, 255],
                    [88, 56, 255, 255, 255, 255],
                    [112, 56, 255, 255, 255, 255],
                    [136, 56, 255, 255, 255, 255],
                    [160, 56, 255, 255, 255, 255],
                    [184, 56, 255, 255, 255, 255],
                    [208, 56, 255, 255, 255, 255],
                    [64, 72, 255, 255, 255, 255],
                    [88, 72, 255, 255, 255, 255],
                    [112, 72, 255, 255, 255, 255],
                    [136, 72, 255, 255, 255, 255],
                    [160, 72, 255, 255, 255, 255],
                    [184, 72, 255, 255, 255, 255],
                    [208, 72, 255, 255, 255, 255],
                    [64, 88, 255, 255, 255, 255],
                    [88, 88, 255, 255, 255, 255],
                    [112, 88, 255, 255, 255, 255],
                    [136, 88, 255, 255, 255, 255],
                    [160, 88, 255, 255, 255, 255],
                    [184, 88, 255, 255, 255, 255],
                    [208, 88, 255, 255, 255, 255],
                    [64, 104, 255, 255, 255, 255],
                    [88, 104, 255, 255, 255, 255],
                    [112, 104, 255, 255, 255, 255],
                    [136, 104, 255, 255, 255, 255],
                    [160, 104, 255, 255, 255, 255],
                    [184, 104, 255, 255, 255, 255],
                ],
                [
                    [88, 24, 255, 255, 255, 255],
                    [88, 40, 255, 255, 255, 255],
                    [112, 40, 255, 255, 255, 255],
                    [136, 40, 255, 255, 255, 255],
                    [160, 40, 255, 255, 255, 255],
                    [184, 40, 255, 255, 255, 255],
                    [88, 56, 255, 255, 255, 255],
                    [112, 56, 255, 255, 255, 255],
                    [136, 56, 255, 255, 255, 255],
                    [160, 56, 255, 255, 255, 255],
                    [184, 56, 255, 255, 255, 255],
                    [208, 56, 255, 255, 255, 255],
                    [88, 72, 255, 255, 255, 255],
                    [112, 72, 255, 255, 255, 255],
                    [136, 72, 255, 255, 255, 255],
                    [160, 72, 255, 255, 255, 255],
                    [184, 72, 255, 255, 255, 255],
                    [208, 72, 255, 255, 255, 255],
                    [88, 88, 255, 255, 255, 255],
                    [112, 88, 255, 255, 255, 255],
                    [136, 88, 255, 255, 255, 255],
                    [160, 88, 255, 255, 255, 255],
                    [184, 88, 255, 255, 255, 255],
                    [208, 88, 255, 255, 255, 255],
                    [88, 104, 255, 255, 255, 255],
                    [112, 104, 255, 255, 255, 255],
                    [136, 104, 255, 255, 255, 255],
                    [160, 104, 255, 255, 255, 255],
                    [184, 104, 255, 255, 255, 255],
                    [208, 104, 255, 255, 255, 255],
                ],
            ],
            "9200544": [
                [
                    [88, 24, 64, 20, 36, 255],
                    [88, 40, 64, 23, 58, 255],
                    [112, 40, 255, 255, 159, 255],
                    [136, 40, 255, 255, 159, 255],
                    [160, 40, 255, 255, 159, 255],
                    [184, 40, 255, 255, 159, 255],
                    [88, 56, 64, 26, 80, 255],
                    [112, 56, 255, 255, 159, 255],
                    [136, 56, 255, 255, 159, 255],
                    [160, 56, 255, 255, 159, 255],
                    [184, 56, 255, 255, 159, 255],
                    [208, 56, 255, 255, 159, 255],
                    [88, 72, 64, 29, 102, 255],
                    [112, 72, 255, 255, 159, 255],
                    [136, 72, 255, 255, 159, 255],
                    [160, 72, 255, 255, 159, 255],
                    [184, 72, 255, 255, 159, 255],
                    [208, 72, 255, 255, 159, 255],
                    [88, 88, 85, 57, 128, 255],
                    [112, 88, 255, 255, 159, 255],
                    [136, 88, 255, 255, 159, 255],
                    [160, 88, 255, 255, 159, 255],
                    [184, 88, 255, 255, 159, 255],
                    [208, 88, 117, 246, 116, 255],
                    [88, 104, 255, 255, 159, 255],
                    [112, 104, 255, 255, 159, 255],
                    [136, 104, 255, 255, 159, 255],
                    [160, 104, 255, 255, 159, 255],
                    [184, 104, 255, 255, 159, 255],
                    [208, 104, 64, 246, 121, 255],
                ],
                [
                    [88, 24, 255, 255, 159, 255],
                    [88, 40, 255, 255, 159, 255],
                    [112, 40, 255, 255, 159, 255],
                    [136, 40, 255, 255, 159, 255],
                    [160, 40, 255, 255, 159, 255],
                    [184, 40, 255, 255, 159, 255],
                    [88, 56, 255, 255, 159, 255],
                    [112, 56, 255, 255, 159, 255],
                    [136, 56, 255, 255, 159, 255],
                    [160, 56, 255, 255, 159, 255],
                    [184, 56, 255, 255, 159, 255],
                    [208, 56, 255, 255, 159, 255],
                    [88, 72, 255, 255, 159, 255],
                    [112, 72, 255, 255, 159, 255],
                    [136, 72, 255, 255, 159, 255],
                    [160, 72, 255, 255, 159, 255],
                    [184, 72, 255, 255, 159, 255],
                    [208, 72, 255, 255, 159, 255],
                    [88, 88, 255, 255, 159, 255],
                    [112, 88, 255, 255, 159, 255],
                    [136, 88, 255, 255, 159, 255],
                    [160, 88, 255, 255, 159, 255],
                    [184, 88, 255, 255, 159, 255],
                    [208, 88, 255, 255, 159, 255],
                    [88, 104, 255, 255, 159, 255],
                    [112, 104, 255, 255, 159, 255],
                    [136, 104, 255, 255, 159, 255],
                    [160, 104, 255, 255, 159, 255],
                    [184, 104, 255, 255, 159, 255],
                    [208, 104, 255, 255, 159, 255],
                ],
                [
                    [88, 24, 64, 20, 36, 255],
                    [88, 40, 64, 23, 58, 255],
                    [112, 40, 255, 255, 159, 255],
                    [136, 40, 255, 255, 159, 255],
                    [160, 40, 255, 255, 159, 255],
                    [184, 40, 255, 255, 159, 255],
                    [88, 56, 64, 26, 80, 255],
                    [112, 56, 255, 255, 159, 255],
                    [136, 56, 255, 255, 159, 255],
                    [160, 56, 255, 255, 159, 255],
                    [184, 56, 255, 255, 159, 255],
                    [208, 56, 255, 255, 159, 255],
                    [88, 72, 64, 29, 102, 255],
                    [112, 72, 255, 255, 159, 255],
                    [136, 72, 255, 255, 159, 255],
                    [160, 72, 255, 255, 159, 255],
                    [184, 72, 255, 255, 159, 255],
                    [208, 72, 255, 255, 159, 255],
                    [88, 88, 85, 57, 128, 255],
                    [112, 88, 255, 255, 159, 255],
                    [136, 88, 255, 255, 159, 255],
                    [160, 88, 255, 255, 159, 255],
                    [184, 88, 255, 255, 159, 255],
                    [208, 88, 117, 246, 116, 255],
                    [88, 104, 255, 255, 159, 255],
                    [112, 104, 255, 255, 159, 255],
                    [136, 104, 255, 255, 159, 255],
                    [160, 104, 255, 255, 159, 255],
                    [184, 104, 255, 255, 159, 255],
                    [208, 104, 64, 246, 121, 255],
                ],
            ],
            "9200545": [
                [
                    [136, 40, 64, 66, 61, 255],
                    [160, 40, 64, 42, 86, 255],
                    [184, 40, 64, 17, 112, 255],
                    [112, 56, 64, 125, 42, 255],
                    [136, 56, 64, 100, 68, 255],
                    [160, 56, 64, 76, 94, 255],
                    [184, 56, 64, 52, 119, 255],
                    [208, 56, 64, 27, 144, 255],
                    [112, 72, 64, 158, 50, 255],
                    [136, 72, 64, 134, 75, 255],
                    [160, 72, 64, 110, 101, 255],
                    [184, 72, 64, 85, 126, 255],
                    [208, 72, 64, 61, 152, 255],
                    [112, 88, 64, 192, 57, 255],
                    [136, 88, 64, 168, 83, 255],
                    [160, 88, 64, 144, 108, 255],
                    [184, 88, 64, 119, 134, 255],
                    [112, 104, 64, 226, 65, 255],
                    [136, 104, 64, 202, 90, 255],
                    [160, 104, 64, 177, 116, 255],
                    [184, 104, 64, 153, 141, 255],
                ],
                [
                    [88, 24, 255, 255, 159, 255],
                    [88, 40, 255, 255, 159, 255],
                    [112, 40, 255, 255, 159, 255],
                    [136, 40, 255, 255, 159, 255],
                    [160, 40, 255, 255, 159, 255],
                    [184, 40, 255, 255, 159, 255],
                    [88, 56, 255, 255, 159, 255],
                    [112, 56, 255, 255, 159, 255],
                    [136, 56, 255, 255, 159, 255],
                    [160, 56, 255, 255, 159, 255],
                    [184, 56, 255, 255, 159, 255],
                    [208, 56, 255, 255, 159, 255],
                    [88, 72, 255, 255, 159, 255],
                    [112, 72, 255, 255, 159, 255],
                    [136, 72, 255, 255, 159, 255],
                    [160, 72, 255, 255, 159, 255],
                    [184, 72, 255, 255, 159, 255],
                    [208, 72, 255, 255, 159, 255],
                    [88, 88, 255, 255, 159, 255],
                    [112, 88, 255, 255, 159, 255],
                    [136, 88, 255, 255, 159, 255],
                    [160, 88, 255, 255, 159, 255],
                    [184, 88, 255, 255, 159, 255],
                    [208, 88, 255, 255, 159, 255],
                    [88, 104, 255, 255, 159, 255],
                    [112, 104, 255, 255, 159, 255],
                    [136, 104, 255, 255, 159, 255],
                    [160, 104, 255, 255, 159, 255],
                    [184, 104, 255, 255, 159, 255],
                    [208, 104, 255, 255, 159, 255],
                ],
                [
                    [136, 40, 64, 66, 61, 255],
                    [160, 40, 64, 42, 86, 255],
                    [184, 40, 64, 17, 112, 255],
                    [112, 56, 64, 125, 42, 255],
                    [136, 56, 64, 100, 68, 255],
                    [160, 56, 64, 76, 94, 255],
                    [184, 56, 64, 52, 119, 255],
                    [208, 56, 64, 27, 144, 255],
                    [112, 72, 64, 158, 50, 255],
                    [136, 72, 64, 134, 75, 255],
                    [160, 72, 64, 110, 101, 255],
                    [184, 72, 64, 85, 126, 255],
                    [208, 72, 64, 61, 152, 255],
                    [112, 88, 64, 192, 57, 255],
                    [136, 88, 64, 168, 83, 255],
                    [160, 88, 64, 144, 108, 255],
                    [184, 88, 64, 119, 134, 255],
                    [112, 104, 64, 226, 65, 255],
                    [136, 104, 64, 202, 90, 255],
                    [160, 104, 64, 177, 116, 255],
                    [184, 104, 64, 153, 141, 255],
                ],
            ],
        ]
        #if DEBUG
        WPESceneDebugArtifacts.shared.setEnabledForTesting(true)
        defer { WPESceneDebugArtifacts.shared.setEnabledForTesting(nil) }
        #endif
        for (step, stage) in [0, 1, 0].enumerated() {
            #if DEBUG
            WPECanonicalTraceRecorder.shared.beginScene(workshopID: sceneID, projectJsonPath: nil, descriptor: "native-siblings")
            #endif
            let visibility = Dictionary(owner.passes.compactMap { $0.pass.visibilityGate.map { ($0.id, stage == 0) } }, uniquingKeysWith: { a, _ in a })
            let resolved = canonical.resolvingEffectPublication(passVisibility: visibility, camera: camera)
            for layer in resolved.layers {
                for pass in layer.passes where pass.shader?.isBuiltin == false {
                    let execution = WPEMetalRenderExecutor.authoredVertexExecution(for: pass, layer: layer.graphLayer, camera: camera)
                    let request = try #require(executor.authoredPrewarmRequest(for: pass, execution: execution))
                    let compiled = try executor.shaderCompiler.compile(request)
                    #expect(compiled.vertexStage?.execution == execution)
                    executor.seedTranslatedShaderCache([(request.translationCacheKey, compiled)])
                    let prewarm = WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm(
                        device: device, defaultLibrary: executor.defaultLibrary, result: compiled, vertexName: nil,
                        blendMode: pass.pass.blending, alphaWritePolicy: pass.renderContract.attachment.alphaWritePolicy,
                        colorPixelFormat: .rgba8Unorm, depthPixelFormat: .invalid
                    )
                    try executor.seedTranslatedPipelines([#require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))])
                }
            }
            executor.adoptPrewarmedAuthoredShaders(for: resolved, camera: camera)
            let output = try executor.render(pipeline: resolved, size: CGSize(width: 256, height: 128), textures: [:], cameraUniforms: camera)
            #expect(output.pixelFormat == .rgba8Unorm)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: 256, height: 128, mipmapped: false)
            desc.storageMode = .shared
            let staging = try #require(device.makeTexture(descriptor: desc))
            let command = try #require(executor.textureSourceCommandQueue.makeCommandBuffer())
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: output, to: staging)
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            #expect(command.error == nil)
            var pixels = [UInt8](repeating: 0, count: 256 * 128 * 4)
            pixels.withUnsafeMutableBytes { staging.getBytes($0.baseAddress!, bytesPerRow: 1024, from: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0) }
            #if DEBUG
            let traceData = try #require(WPECanonicalTraceRecorder.shared.finishFrame(outputTexture: staging, runtimeUniforms: nil,
                                                                                      firstFrameStats: nil, resolutionDiagnostics: .init(events: [])))
            let trace = try #require(JSONSerialization.jsonObject(with: traceData) as? [String: Any])
            let records = try #require(trace["passes"] as? [[String: Any]])
            let custom = records.filter { ($0["layerId"] as? String) == "947100" && ["gradient", "probe-clock", "third"].contains($0["shaderName"] as? String ?? "") }
            #expect(custom.count == (stage == 1 ? (sceneID == "9000543" ? 0 : 1) : (sceneID == "9000543" ? 2 : 3)))
            for record in custom {
                let contract = try #require(record["vertexContract"] as? [String: Any])
                #expect(contract["authoredVertexExecuted"] as? Bool == true)
                #expect(contract["fallbackReason"] == nil)
            }
            #endif
            for probe in try #require(expected[sceneID])[step] {
                let offset = (probe[1] * 256 + probe[0]) * 4
                #expect((0 ..< 3).allSatisfy { abs(Int(pixels[offset + $0]) - probe[2 + $0]) <= 1 })
                #expect(Int(pixels[offset + 3]) == probe[5])
            }
        }
    }

    @Test("Native grouped material passes preserve input snapshots and terminal geometry", arguments: ["9000543", "9200544", "9200545"])
    func nativeEffectSiblingTopology(sceneID: String) throws {
        let fixture = try nativeSiblingFixture(sceneID: sceneID)
        defer { fixture.cleanup() }
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: fixture.root.appendingPathComponent("scene.json")))
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let raw = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let canonical = WPERenderGraphBuilder.preparingEffectPublication(in: raw, camera: camera, permitsVisibilityGates: true)
        let owner = try #require(canonical.layers.first { $0.graphLayer.objectID == "947100" })
        #expect(owner.passes == raw.layers.first { $0.graphLayer.objectID == "947100" }?.passes)
        _ = try #require(owner.effectPublication)
        for stage in [0, 1, 0] {
            let visibility = Dictionary(owner.passes.compactMap { $0.pass.visibilityGate.map { ($0.id, stage == 0) } }, uniquingKeysWith: { a, _ in a })
            let resolved = canonical.resolvingEffectPublication(passVisibility: visibility, camera: camera)
            let layer = try #require(resolved.layers.first { $0.graphLayer.objectID == "947100" })
            let passes = layer.passes
            #expect(passes.count == (stage == 1 ? (sceneID == "9000543" ? 1 : 2) : (sceneID == "9000543" ? 3 : 4)))
            #expect(passes.last?.pass.target == .scene)
            if stage == 0 {
                let base = passes[0], a = passes[1], b = passes[2]
                #expect(a.publicationVertexRole == .localEffect)
                #expect(b.textureBindings[0] == (sceneID == "9200545" ? a.pass.target.textureReference : base.pass.target.textureReference))
                if sceneID == "9000543" {
                    #expect(a.pass.target == .scene && b.pass.target == .scene)
                    #expect(b.publicationVertexRole == nil)
                } else {
                    #expect(b.publicationVertexRole == .localEffect)
                    #expect(a.pass.target == b.pass.target || sceneID == "9200545")
                    #expect(passes[3].textureBindings[0] == b.pass.target.textureReference)
                    #expect(passes[3].publicationVertexRole == nil)
                }
            } else if sceneID != "9000543" {
                #expect(passes.last?.textureBindings[0] == passes.first?.pass.target.textureReference)
            }
        }
    }

    private func nativeSiblingFixture(sceneID: String) throws -> Fixture {
        var encoded: [String: String] = [
            "effects/gradient.json": """
            ewogICJ2ZXJzaW9uIjogMSwKICAibmFtZSI6ICJncmFkaWVudCIsCiAgInBhc3NlcyI6IFsKICAg
            IHsKICAgICAgIm1hdGVyaWFsIjogIm1hdGVyaWFscy9ncmFkaWVudC5qc29uIgogICAgfQogIF0K
            fQo=
            """,
            "effects/pair.json": """
            ewogICJ2ZXJzaW9uIjogMSwKICAibmFtZSI6ICJwYWlyIiwKICAicGFzc2VzIjogWwogICAgewog
            ICAgICAibWF0ZXJpYWwiOiAibWF0ZXJpYWxzL2dyYWRpZW50Lmpzb24iCiAgICB9LAogICAgewog
            ICAgICAibWF0ZXJpYWwiOiAibWF0ZXJpYWxzL3Byb2JlLmpzb24iCiAgICB9CiAgXQp9Cg==
            """,
            "effects/probe.json": """
            ewogICJ2ZXJzaW9uIjogMSwKICAibmFtZSI6ICJVbnVzZWQgZnJhZ21lbnQgdmFyeWluZyIsCiAg
            InBhc3NlcyI6IFsKICAgIHsKICAgICAgIm1hdGVyaWFsIjogIm1hdGVyaWFscy9wcm9iZS5qc29u
            IgogICAgfQogIF0sCiAgImRlcGVuZGVuY2llcyI6IFsKICAgICJtYXRlcmlhbHMvcHJvYmUuanNv
            biIsCiAgICAic2hhZGVycy9wcm9iZS1jbG9jay52ZXJ0IiwKICAgICJzaGFkZXJzL3Byb2JlLWNs
            b2NrLmZyYWciCiAgXQp9
            """,
            "effects/third.json": """
            ewogICJ2ZXJzaW9uIjogMSwKICAibmFtZSI6ICJ0aGlyZCIsCiAgInBhc3NlcyI6IFsKICAgIHsK
            ICAgICAgIm1hdGVyaWFsIjogIm1hdGVyaWFscy90aGlyZC5qc29uIgogICAgfQogIF0KfQo=
            """,
            "materials/base.json": """
            ewogICJwYXNzZXMiOiBbCiAgICB7CiAgICAgICJzaGFkZXIiOiAic29saWRsYXllciIsCiAgICAg
            ICJibGVuZGluZyI6ICJub3JtYWwiLAogICAgICAiY3VsbG1vZGUiOiAibm9jdWxsIiwKICAgICAg
            ImRlcHRodGVzdCI6ICJkaXNhYmxlZCIsCiAgICAgICJkZXB0aHdyaXRlIjogImRpc2FibGVkIgog
            ICAgfQogIF0KfQo=
            """,
            "materials/gradient.json": """
            ewogICJwYXNzZXMiOiBbCiAgICB7CiAgICAgICJzaGFkZXIiOiAiZ3JhZGllbnQiLAogICAgICAi
            YmxlbmRpbmciOiAiZGlzYWJsZWQiLAogICAgICAiY3VsbG1vZGUiOiAibm9jdWxsIiwKICAgICAg
            ImRlcHRodGVzdCI6ICJkaXNhYmxlZCIsCiAgICAgICJkZXB0aHdyaXRlIjogImRpc2FibGVkIiwK
            ICAgICAgInRleHR1cmVzIjogW10KICAgIH0KICBdCn0K
            """,
            "materials/gray.tex": """
            VEVYVjAwMDUAVEVYSTAwMDEAAAAAAAMAAAACAAAAAgAAAAIAAAACAAAAAAAAAFRFWEIwMDAzAAEA
            AAD/////AQAAAAIAAAACAAAAAAAAABAAAAAQAAAAgICAgICAgICAgICAgICAgA==
            """,
            "materials/probe.json": """
            ewogICJwYXNzZXMiOiBbCiAgICB7CiAgICAgICJibGVuZGluZyI6ICJkaXNhYmxlZCIsCiAgICAg
            ICJjb21ib3MiOiB7CiAgICAgICAgInZlcnNpb24iOiAyLAogICAgICAgICJNT0RFIjogMQogICAg
            ICB9LAogICAgICAiY3VsbG1vZGUiOiAibm9jdWxsIiwKICAgICAgImRlcHRodGVzdCI6ICJkaXNh
            YmxlZCIsCiAgICAgICJkZXB0aHdyaXRlIjogImRpc2FibGVkIiwKICAgICAgInNoYWRlciI6ICJw
            cm9iZS1jbG9jayIsCiAgICAgICJ0ZXh0dXJlcyI6IFsKICAgICAgICBudWxsCiAgICAgIF0sCiAg
            ICAgICJjb25zdGFudHNoYWRlcnZhbHVlcyI6IHsKICAgICAgICAib2Zmc2V0IjogIjAuMTMgLTAu
            MDkiLAogICAgICAgICJzY2FsZSI6ICIwLjc1IDEuMiIsCiAgICAgICAgImFuZ2xlIjogMC4zCiAg
            ICAgIH0KICAgIH0KICBdCn0K
            """,
            "materials/third.json": """
            ewogICJwYXNzZXMiOiBbCiAgICB7CiAgICAgICJibGVuZGluZyI6ICJkaXNhYmxlZCIsCiAgICAg
            ICJjb21ib3MiOiB7CiAgICAgICAgInZlcnNpb24iOiAyLAogICAgICAgICJNT0RFIjogMQogICAg
            ICB9LAogICAgICAiY3VsbG1vZGUiOiAibm9jdWxsIiwKICAgICAgImRlcHRodGVzdCI6ICJkaXNh
            YmxlZCIsCiAgICAgICJkZXB0aHdyaXRlIjogImRpc2FibGVkIiwKICAgICAgInNoYWRlciI6ICJ0
            aGlyZCIsCiAgICAgICJ0ZXh0dXJlcyI6IFsKICAgICAgICBudWxsCiAgICAgIF0sCiAgICAgICJj
            b25zdGFudHNoYWRlcnZhbHVlcyI6IHsKICAgICAgICAib2Zmc2V0IjogIjAuMTMgLTAuMDkiLAog
            ICAgICAgICJzY2FsZSI6ICIwLjc1IDEuMiIsCiAgICAgICAgImFuZ2xlIjogMC4zCiAgICAgIH0K
            ICAgIH0KICBdCn0K
            """,
            "models/probe.json": """
            eyJtYXRlcmlhbCI6Im1hdGVyaWFscy9iYXNlLmpzb24ifQo=
            """,
            "scene.json": """
            ewogICJjYW1lcmEiOiB7CiAgICAiZXllIjogIjAgMCAwIiwKICAgICJjZW50ZXIiOiAiMCAwIC0x
            IiwKICAgICJ1cCI6ICIwIDEgMCIKICB9LAogICJnZW5lcmFsIjogewogICAgIm9ydGhvZ29uYWxw
            cm9qZWN0aW9uIjogewogICAgICAid2lkdGgiOiAyNTYsCiAgICAgICJoZWlnaHQiOiAxMjgKICAg
            IH0sCiAgICAiY2xlYXJjb2xvciI6ICIwLjE1IDAuMjUgMC4zNSIsCiAgICAiY2xlYXJlbmFibGVk
            IjogdHJ1ZSwKICAgICJoZHIiOiBmYWxzZSwKICAgICJibG9vbSI6IGZhbHNlLAogICAgImJsb29t
            aGRyZmVhdGhlciI6IDEsCiAgICAiYmxvb21oZHJpdGVyYXRpb25zIjogNCwKICAgICJibG9vbWhk
            cnNjYXR0ZXIiOiAxLAogICAgImJsb29taGRyc3RyZW5ndGgiOiAwLAogICAgImJsb29taGRydGhy
            ZXNob2xkIjogMTAwLAogICAgImJsb29tc3RyZW5ndGgiOiAwLAogICAgImJsb29tdGhyZXNob2xk
            IjogMC42NSwKICAgICJibG9vbXRpbnQiOiAiMSAxIDEiLAogICAgImNhbWVyYXBhcmFsbGF4Ijog
            ZmFsc2UsCiAgICAiem9vbSI6IDEKICB9LAogICJvYmplY3RzIjogWwogICAgewogICAgICAiaWQi
            OiA5NDcwOTksCiAgICAgICJuYW1lIjogIm5hdGl2ZSBibGFjayBiYWNrZ3JvdW5kIGNhcHR1cmUg
            c2VudGluZWwiLAogICAgICAiaW1hZ2UiOiAibW9kZWxzL3V0aWwvc29saWRsYXllci5qc29uIiwK
            ICAgICAgIm9yaWdpbiI6ICIxMjggNjQgMCIsCiAgICAgICJzaXplIjogIjI1NiAxMjgiLAogICAg
            ICAic2NhbGUiOiAiMSAxIDEiLAogICAgICAiY29sb3IiOiAiMC4xNSAwLjI1IDAuMzUiLAogICAg
            ICAiYWxwaGEiOiAxLAogICAgICAiYnJpZ2h0bmVzcyI6IDEKICAgIH0sCiAgICB7CiAgICAgICJp
            ZCI6IDk0NzEwMCwKICAgICAgIm5hbWUiOiAicHJvZHVjZXIiLAogICAgICAiaW1hZ2UiOiAibW9k
            ZWxzL3V0aWwvc29saWRsYXllci5qc29uIiwKICAgICAgIm9yaWdpbiI6ICIxNDQgNTIgMCIsCiAg
            ICAgICJzaXplIjogIjE2MCA5NiIsCiAgICAgICJzY2FsZSI6ICIxLjIgMC44IDEiLAogICAgICAi
            Y29sb3IiOiAiMSAxIDEiLAogICAgICAiYWxwaGEiOiAxLAogICAgICAiYnJpZ2h0bmVzcyI6IDEs
            CiAgICAgICJhbmdsZXMiOiAiMCAwIDAuMTciLAogICAgICAiZWZmZWN0cyI6IFsKICAgICAgICB7
            CiAgICAgICAgICAiZmlsZSI6ICJlZmZlY3RzL3BhaXIuanNvbiIsCiAgICAgICAgICAiaWQiOiA5
            NTAwMDMsCiAgICAgICAgICAibmFtZSI6ICJwYWlyIiwKICAgICAgICAgICJ2aXNpYmxlIjogewog
            ICAgICAgICAgICAidmFsdWUiOiB0cnVlLAogICAgICAgICAgICAic2NyaXB0IjogImV4cG9ydCBm
            dW5jdGlvbiB1cGRhdGUodmFsdWUpIHsgcmV0dXJuIChOdW1iZXIoZW5naW5lLnVzZXJQcm9wZXJ0
            aWVzLnN0YWdlKSAmIDEpID09PSAwOyB9IgogICAgICAgICAgfQogICAgICAgIH0KICAgICAgXQog
            ICAgfQogIF0KfQo=
            """,
            "shaders/gradient.frag": """
            dmFyeWluZyB2ZWMyIHZfVGV4Q29vcmQ7CnZvaWQgbWFpbigpe2dsX0ZyYWdDb2xvcj12ZWM0KHZf
            VGV4Q29vcmQsMC4yNSwxLjApO30K
            """,
            "shaders/gradient.vert": """
            I2luY2x1ZGUgImNvbW1vbi5oIgp1bmlmb3JtIG1hdDQgZ19Nb2RlbFZpZXdQcm9qZWN0aW9uTWF0
            cml4OwphdHRyaWJ1dGUgdmVjMyBhX1Bvc2l0aW9uOwphdHRyaWJ1dGUgdmVjMiBhX1RleENvb3Jk
            Owp2YXJ5aW5nIHZlYzIgdl9UZXhDb29yZDsKdm9pZCBtYWluKCkgewogICAgZ2xfUG9zaXRpb24g
            PSBtdWwodmVjNChhX1Bvc2l0aW9uLCAxLjApLCBnX01vZGVsVmlld1Byb2plY3Rpb25NYXRyaXgp
            OwogICAgdl9UZXhDb29yZCA9IGFfVGV4Q29vcmQ7Cn0K
            """,
            "shaders/probe-clock.frag": """
            I2luY2x1ZGUgImNvbW1vbi5oIgp1bmlmb3JtIHNhbXBsZXIyRCBnX1RleHR1cmUwOwp2YXJ5aW5n
            IHZlYzIgdl9UZXhDb29yZDsKdm9pZCBtYWluKCkgewogICAgdmVjNCBjID0gdGV4U2FtcGxlMkQo
            Z19UZXh0dXJlMCwgdl9UZXhDb29yZCk7CiAgICBnbF9GcmFnQ29sb3IgPSB2ZWM0KGMuZywgYy5y
            LCBjLmIsIGMuYSk7Cn0K
            """,
            "shaders/probe-clock.vert": """
            DQovLyBbQ09NQk9dIHsibWF0ZXJpYWwiOiJ1aV9lZGl0b3JfcHJvcGVydGllc19tb2RlIiwiY29t
            Ym8iOiJNT0RFIiwidHlwZSI6Im9wdGlvbnMiLCJkZWZhdWx0IjowLCJvcHRpb25zIjp7IlZlcnRl
            eCI6MSwiVVYiOjB9fQ0KDQojaW5jbHVkZSAiY29tbW9uLmgiDQoNCnVuaWZvcm0gbWF0NCBnX01v
            ZGVsVmlld1Byb2plY3Rpb25NYXRyaXg7DQoNCnVuaWZvcm0gdmVjMiBnX09mZnNldDsgLy8geyJt
            YXRlcmlhbCI6Im9mZnNldCIsImxhYmVsIjoidWlfZWRpdG9yX3Byb3BlcnRpZXNfb2Zmc2V0Iiwi
            ZGVmYXVsdCI6IjAgMCJ9DQp1bmlmb3JtIHZlYzIgZ19TY2FsZTsgLy8geyJtYXRlcmlhbCI6InNj
            YWxlIiwibGFiZWwiOiJ1aV9lZGl0b3JfcHJvcGVydGllc19zY2FsZSIsImRlZmF1bHQiOiIxIDEi
            fQ0KdW5pZm9ybSBmbG9hdCBnX0RpcmVjdGlvbjsgLy8geyJtYXRlcmlhbCI6ImFuZ2xlIiwibGFi
            ZWwiOiJ1aV9lZGl0b3JfcHJvcGVydGllc19hbmdsZSIsImRlZmF1bHQiOjAsInJhbmdlIjpbMCw2
            LjI4XSwiZGlyZWN0aW9uIjp0cnVlLCJjb252ZXJzaW9uIjoicmFkMmRlZyJ9DQoNCmF0dHJpYnV0
            ZSB2ZWMzIGFfUG9zaXRpb247DQphdHRyaWJ1dGUgdmVjMiBhX1RleENvb3JkOw0KDQp2YXJ5aW5n
            IHZlYzIgdl9UZXhDb29yZDsNCg0KdmVjMiBhcHBseUZ4KHZlYzIgdikgew0KCXYgPSByb3RhdGVW
            ZWMyKHYgLSBDQVNUMigwLjUpLCAtZ19EaXJlY3Rpb24pOw0KCXJldHVybiAodiArIGdfT2Zmc2V0
            KSAqIGdfU2NhbGUgKyBDQVNUMigwLjUpOw0KfQ0KDQp2b2lkIG1haW4oKSB7DQoNCgl2ZWMzIHBv
            c2l0aW9uID0gYV9Qb3NpdGlvbjsNCiNpZiBNT0RFID09IDENCglwb3NpdGlvbi54eSA9IGFwcGx5
            RngocG9zaXRpb24ueHkpOw0KI2VuZGlmDQoJZ2xfUG9zaXRpb24gPSBtdWwodmVjNChwb3NpdGlv
            biwgMS4wKSwgZ19Nb2RlbFZpZXdQcm9qZWN0aW9uTWF0cml4KTsNCgkNCgl2X1RleENvb3JkID0g
            YV9UZXhDb29yZDsNCgkNCiNpZiBNT0RFID09IDANCgl2X1RleENvb3JkID0gYXBwbHlGeCh2X1Rl
            eENvb3JkKTsNCiNlbmRpZg0KfQ0K
            """,
            "shaders/third.frag": """
            I2luY2x1ZGUgImNvbW1vbi5oIgp1bmlmb3JtIHNhbXBsZXIyRCBnX1RleHR1cmUwOwp2YXJ5aW5n
            IHZlYzIgdl9UZXhDb29yZDsKdm9pZCBtYWluKCkgewogICAgdmVjNCBjID0gdGV4U2FtcGxlMkQo
            Z19UZXh0dXJlMCwgdl9UZXhDb29yZCk7CiAgICBnbF9GcmFnQ29sb3IgPSB2ZWM0KGMuYiwgYy5y
            LCAwLjEyNSArIDAuNSAqIGMuZywgYy5hKTsKfQo=
            """,
            "shaders/third.vert": """
            DQovLyBbQ09NQk9dIHsibWF0ZXJpYWwiOiJ1aV9lZGl0b3JfcHJvcGVydGllc19tb2RlIiwiY29t
            Ym8iOiJNT0RFIiwidHlwZSI6Im9wdGlvbnMiLCJkZWZhdWx0IjowLCJvcHRpb25zIjp7IlZlcnRl
            eCI6MSwiVVYiOjB9fQ0KDQojaW5jbHVkZSAiY29tbW9uLmgiDQoNCnVuaWZvcm0gbWF0NCBnX01v
            ZGVsVmlld1Byb2plY3Rpb25NYXRyaXg7DQoNCnVuaWZvcm0gdmVjMiBnX09mZnNldDsgLy8geyJt
            YXRlcmlhbCI6Im9mZnNldCIsImxhYmVsIjoidWlfZWRpdG9yX3Byb3BlcnRpZXNfb2Zmc2V0Iiwi
            ZGVmYXVsdCI6IjAgMCJ9DQp1bmlmb3JtIHZlYzIgZ19TY2FsZTsgLy8geyJtYXRlcmlhbCI6InNj
            YWxlIiwibGFiZWwiOiJ1aV9lZGl0b3JfcHJvcGVydGllc19zY2FsZSIsImRlZmF1bHQiOiIxIDEi
            fQ0KdW5pZm9ybSBmbG9hdCBnX0RpcmVjdGlvbjsgLy8geyJtYXRlcmlhbCI6ImFuZ2xlIiwibGFi
            ZWwiOiJ1aV9lZGl0b3JfcHJvcGVydGllc19hbmdsZSIsImRlZmF1bHQiOjAsInJhbmdlIjpbMCw2
            LjI4XSwiZGlyZWN0aW9uIjp0cnVlLCJjb252ZXJzaW9uIjoicmFkMmRlZyJ9DQoNCmF0dHJpYnV0
            ZSB2ZWMzIGFfUG9zaXRpb247DQphdHRyaWJ1dGUgdmVjMiBhX1RleENvb3JkOw0KDQp2YXJ5aW5n
            IHZlYzIgdl9UZXhDb29yZDsNCg0KdmVjMiBhcHBseUZ4KHZlYzIgdikgew0KCXYgPSByb3RhdGVW
            ZWMyKHYgLSBDQVNUMigwLjUpLCAtZ19EaXJlY3Rpb24pOw0KCXJldHVybiAodiArIGdfT2Zmc2V0
            KSAqIGdfU2NhbGUgKyBDQVNUMigwLjUpOw0KfQ0KDQp2b2lkIG1haW4oKSB7DQoNCgl2ZWMzIHBv
            c2l0aW9uID0gYV9Qb3NpdGlvbjsNCiNpZiBNT0RFID09IDENCglwb3NpdGlvbi54eSA9IGFwcGx5
            RngocG9zaXRpb24ueHkpOw0KI2VuZGlmDQoJZ2xfUG9zaXRpb24gPSBtdWwodmVjNChwb3NpdGlv
            biwgMS4wKSwgZ19Nb2RlbFZpZXdQcm9qZWN0aW9uTWF0cml4KTsNCgkNCgl2X1RleENvb3JkID0g
            YV9UZXhDb29yZDsNCgkNCiNpZiBNT0RFID09IDANCgl2X1RleENvb3JkID0gYXBwbHlGeCh2X1Rl
            eENvb3JkKTsNCiNlbmRpZg0KfQ0K
            """,
        ]
        if sceneID == "9200544" {
            let overrides: [String: String] = [
                "scene.json": """
                ewogICJjYW1lcmEiOiB7CiAgICAiZXllIjogIjAgMCAwIiwKICAgICJjZW50ZXIiOiAiMCAwIC0x
                IiwKICAgICJ1cCI6ICIwIDEgMCIKICB9LAogICJnZW5lcmFsIjogewogICAgIm9ydGhvZ29uYWxw
                cm9qZWN0aW9uIjogewogICAgICAid2lkdGgiOiAyNTYsCiAgICAgICJoZWlnaHQiOiAxMjgKICAg
                IH0sCiAgICAiY2xlYXJjb2xvciI6ICIwLjE1IDAuMjUgMC4zNSIsCiAgICAiY2xlYXJlbmFibGVk
                IjogdHJ1ZSwKICAgICJoZHIiOiBmYWxzZSwKICAgICJibG9vbSI6IGZhbHNlLAogICAgImJsb29t
                aGRyZmVhdGhlciI6IDEsCiAgICAiYmxvb21oZHJpdGVyYXRpb25zIjogNCwKICAgICJibG9vbWhk
                cnNjYXR0ZXIiOiAxLAogICAgImJsb29taGRyc3RyZW5ndGgiOiAwLAogICAgImJsb29taGRydGhy
                ZXNob2xkIjogMTAwLAogICAgImJsb29tc3RyZW5ndGgiOiAwLAogICAgImJsb29tdGhyZXNob2xk
                IjogMC42NSwKICAgICJibG9vbXRpbnQiOiAiMSAxIDEiLAogICAgImNhbWVyYXBhcmFsbGF4Ijog
                ZmFsc2UsCiAgICAiem9vbSI6IDEKICB9LAogICJvYmplY3RzIjogWwogICAgewogICAgICAiaWQi
                OiA5NDcwOTksCiAgICAgICJuYW1lIjogIm5hdGl2ZSBibGFjayBiYWNrZ3JvdW5kIGNhcHR1cmUg
                c2VudGluZWwiLAogICAgICAiaW1hZ2UiOiAibW9kZWxzL3V0aWwvc29saWRsYXllci5qc29uIiwK
                ICAgICAgIm9yaWdpbiI6ICIxMjggNjQgMCIsCiAgICAgICJzaXplIjogIjI1NiAxMjgiLAogICAg
                ICAic2NhbGUiOiAiMSAxIDEiLAogICAgICAiY29sb3IiOiAiMC4xNSAwLjI1IDAuMzUiLAogICAg
                ICAiYWxwaGEiOiAxLAogICAgICAiYnJpZ2h0bmVzcyI6IDEKICAgIH0sCiAgICB7CiAgICAgICJp
                ZCI6IDk0NzEwMCwKICAgICAgIm5hbWUiOiAicHJvZHVjZXIiLAogICAgICAiaW1hZ2UiOiAibW9k
                ZWxzL3V0aWwvc29saWRsYXllci5qc29uIiwKICAgICAgIm9yaWdpbiI6ICIxNDQgNTIgMCIsCiAg
                ICAgICJzaXplIjogIjE2MCA5NiIsCiAgICAgICJzY2FsZSI6ICIxLjIgMC44IDEiLAogICAgICAi
                Y29sb3IiOiAiMSAxIDEiLAogICAgICAiYWxwaGEiOiAxLAogICAgICAiYnJpZ2h0bmVzcyI6IDEs
                CiAgICAgICJhbmdsZXMiOiAiMCAwIDAuMTciLAogICAgICAiZWZmZWN0cyI6IFsKICAgICAgICB7
                CiAgICAgICAgICAiZmlsZSI6ICJlZmZlY3RzL3BhaXIuanNvbiIsCiAgICAgICAgICAiaWQiOiA5
                NTAwMDMsCiAgICAgICAgICAibmFtZSI6ICJwYWlyIiwKICAgICAgICAgICJ2aXNpYmxlIjogewog
                ICAgICAgICAgICAidmFsdWUiOiB0cnVlLAogICAgICAgICAgICAic2NyaXB0IjogImV4cG9ydCBm
                dW5jdGlvbiB1cGRhdGUodmFsdWUpIHsgcmV0dXJuIChOdW1iZXIoZW5naW5lLnVzZXJQcm9wZXJ0
                aWVzLnN0YWdlKSAmIDEpID09PSAwOyB9IgogICAgICAgICAgfQogICAgICAgIH0sCiAgICAgICAg
                ewogICAgICAgICAgImZpbGUiOiAiZWZmZWN0cy90aGlyZC5qc29uIiwKICAgICAgICAgICJpZCI6
                IDk1MDAwNCwKICAgICAgICAgICJuYW1lIjogInRlcm1pbmFsIHRoaXJkIgogICAgICAgIH0KICAg
                ICAgXQogICAgfQogIF0KfQo=
                """,
            ]
            encoded.merge(overrides) { _, value in value }
        }
        if sceneID == "9200545" {
            let overrides: [String: String] = [
                "effects/pair.json": """
                ewogICJ2ZXJzaW9uIjogMSwKICAibmFtZSI6ICJwYWlyIiwKICAicGFzc2VzIjogWwogICAgewog
                ICAgICAibWF0ZXJpYWwiOiAibWF0ZXJpYWxzL2dyYWRpZW50Lmpzb24iLAogICAgICAidGFyZ2V0
                IjogIl9ydF9CMHNjcmF0Y2giCiAgICB9LAogICAgewogICAgICAibWF0ZXJpYWwiOiAibWF0ZXJp
                YWxzL3Byb2JlLmpzb24iLAogICAgICAiYmluZCI6IFsKICAgICAgICB7CiAgICAgICAgICAiaW5k
                ZXgiOiAwLAogICAgICAgICAgIm5hbWUiOiAiX3J0X0Iwc2NyYXRjaCIKICAgICAgICB9CiAgICAg
                IF0KICAgIH0KICBdLAogICJmYm9zIjogWwogICAgewogICAgICAibmFtZSI6ICJfcnRfQjBzY3Jh
                dGNoIiwKICAgICAgInNjYWxlIjogMSwKICAgICAgImZvcm1hdCI6ICJyZ2JhODg4OCIsCiAgICAg
                ICJjbGVhciI6ICIwIDAgMCAwIiwKICAgICAgInVuaXF1ZSI6IHRydWUKICAgIH0KICBdCn0K
                """,
                "scene.json": """
                ewogICJjYW1lcmEiOiB7CiAgICAiZXllIjogIjAgMCAwIiwKICAgICJjZW50ZXIiOiAiMCAwIC0x
                IiwKICAgICJ1cCI6ICIwIDEgMCIKICB9LAogICJnZW5lcmFsIjogewogICAgIm9ydGhvZ29uYWxw
                cm9qZWN0aW9uIjogewogICAgICAid2lkdGgiOiAyNTYsCiAgICAgICJoZWlnaHQiOiAxMjgKICAg
                IH0sCiAgICAiY2xlYXJjb2xvciI6ICIwLjE1IDAuMjUgMC4zNSIsCiAgICAiY2xlYXJlbmFibGVk
                IjogdHJ1ZSwKICAgICJoZHIiOiBmYWxzZSwKICAgICJibG9vbSI6IGZhbHNlLAogICAgImJsb29t
                aGRyZmVhdGhlciI6IDEsCiAgICAiYmxvb21oZHJpdGVyYXRpb25zIjogNCwKICAgICJibG9vbWhk
                cnNjYXR0ZXIiOiAxLAogICAgImJsb29taGRyc3RyZW5ndGgiOiAwLAogICAgImJsb29taGRydGhy
                ZXNob2xkIjogMTAwLAogICAgImJsb29tc3RyZW5ndGgiOiAwLAogICAgImJsb29tdGhyZXNob2xk
                IjogMC42NSwKICAgICJibG9vbXRpbnQiOiAiMSAxIDEiLAogICAgImNhbWVyYXBhcmFsbGF4Ijog
                ZmFsc2UsCiAgICAiem9vbSI6IDEKICB9LAogICJvYmplY3RzIjogWwogICAgewogICAgICAiaWQi
                OiA5NDcwOTksCiAgICAgICJuYW1lIjogIm5hdGl2ZSBibGFjayBiYWNrZ3JvdW5kIGNhcHR1cmUg
                c2VudGluZWwiLAogICAgICAiaW1hZ2UiOiAibW9kZWxzL3V0aWwvc29saWRsYXllci5qc29uIiwK
                ICAgICAgIm9yaWdpbiI6ICIxMjggNjQgMCIsCiAgICAgICJzaXplIjogIjI1NiAxMjgiLAogICAg
                ICAic2NhbGUiOiAiMSAxIDEiLAogICAgICAiY29sb3IiOiAiMC4xNSAwLjI1IDAuMzUiLAogICAg
                ICAiYWxwaGEiOiAxLAogICAgICAiYnJpZ2h0bmVzcyI6IDEKICAgIH0sCiAgICB7CiAgICAgICJp
                ZCI6IDk0NzEwMCwKICAgICAgIm5hbWUiOiAicHJvZHVjZXIiLAogICAgICAiaW1hZ2UiOiAibW9k
                ZWxzL3V0aWwvc29saWRsYXllci5qc29uIiwKICAgICAgIm9yaWdpbiI6ICIxNDQgNTIgMCIsCiAg
                ICAgICJzaXplIjogIjE2MCA5NiIsCiAgICAgICJzY2FsZSI6ICIxLjIgMC44IDEiLAogICAgICAi
                Y29sb3IiOiAiMSAxIDEiLAogICAgICAiYWxwaGEiOiAxLAogICAgICAiYnJpZ2h0bmVzcyI6IDEs
                CiAgICAgICJhbmdsZXMiOiAiMCAwIDAuMTciLAogICAgICAiZWZmZWN0cyI6IFsKICAgICAgICB7
                CiAgICAgICAgICAiZmlsZSI6ICJlZmZlY3RzL3BhaXIuanNvbiIsCiAgICAgICAgICAiaWQiOiA5
                NTAwMDMsCiAgICAgICAgICAibmFtZSI6ICJwYWlyIiwKICAgICAgICAgICJ2aXNpYmxlIjogewog
                ICAgICAgICAgICAidmFsdWUiOiB0cnVlLAogICAgICAgICAgICAic2NyaXB0IjogImV4cG9ydCBm
                dW5jdGlvbiB1cGRhdGUodmFsdWUpIHsgcmV0dXJuIChOdW1iZXIoZW5naW5lLnVzZXJQcm9wZXJ0
                aWVzLnN0YWdlKSAmIDEpID09PSAwOyB9IgogICAgICAgICAgfQogICAgICAgIH0sCiAgICAgICAg
                ewogICAgICAgICAgImZpbGUiOiAiZWZmZWN0cy90aGlyZC5qc29uIiwKICAgICAgICAgICJpZCI6
                IDk1MDAwNCwKICAgICAgICAgICJuYW1lIjogInRlcm1pbmFsIHRoaXJkIgogICAgICAgIH0KICAg
                ICAgXQogICAgfQogIF0KfQo=
                """,
            ]
            encoded.merge(overrides) { _, value in value }
        }
        let data = try encoded.mapValues { try #require(Data(base64Encoded: $0, options: .ignoreUnknownCharacters)) }
        return try makeFixture(dataFiles: data)
    }

    @Test("Independent effect publication preserves canonical gates and reconnects every active subset",
          arguments: [false, true], [2, 3])
    func independentEffectPublication(reverse: Bool, count: Int) throws {
        let (fixture, document) = try effectPublicationFixture(count: count, reverse: reverse)
        defer { fixture.cleanup() }
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let original = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let canonical = WPERenderGraphBuilder.preparingEffectPublication(in: original, camera: camera, permitsVisibilityGates: true)
        let owner = try #require(canonical.layers.first)
        let descriptor = try #require(owner.effectPublication)
        #expect(descriptor.scope == .nativeSolidChain)
        #expect(owner.passes == original.layers[0].passes)
        #expect(owner.graphLayer == original.layers[0].graphLayer)
        #expect(descriptor.effects.map(\.passID) == owner.passes.dropFirst().dropLast().map(\.id))
        #expect(owner.replacing().effectPublication == descriptor)
        let prewarm = owner.effectPublicationPrewarmPasses(camera: camera)
        #expect(prewarm.count == count * 4 + 2)
        #expect(prewarm[0].pass.target == .layerComposite(name: owner.graphLayer.compositeA) && prewarm[0].pass.blending == "disabled")
        #expect(prewarm[1].pass.target == .scene && prewarm[1].pass.blending == "normal")
        #expect(prewarm.prefix(2).allSatisfy { $0.alphaContract == .init(unpremultipliedInputSlots: [], premultipliedOutput: false) })
        #expect(prewarm.prefix(2).allSatisfy { $0.publicationVertexRole == nil })
        #expect(prewarm.dropFirst(2).allSatisfy {
            $0.publicationVertexRole == ($0.pass.target == .scene ? nil : .localEffect)
        })
        #expect(WPERenderGraphBuilder.rotatingCanonicalCompositeOutputs(in: canonical, sceneHDR: true).pipeline == canonical)
        #expect(WPERenderGraphBuilder.elidingFullFramePassthroughs(in: canonical, sceneHDR: true).pipeline == canonical)
        #expect(canonical.retainingEffectPublication(in: []).layers[0].passes == owner.passes)
        #expect(canonical.retainingEffectPublication(in: []).layers[0].effectPublication == nil)
        let effects = Array(owner.passes.dropFirst().dropLast())
        let cold = canonical.resolvingEffectPublication(passVisibility: [:], camera: camera)
        #expect(cold.layers[0].passes.count == 1 && cold.layers[0].passes[0].pass.target == .scene)
        #expect(cold.layers[0].passes[0].pass.blending == "normal")
        #expect(cold.layers[0].passes[0].alphaContract == .init(unpremultipliedInputSlots: [], premultipliedOutput: false))
        #expect(cold.layers[0].passes[0].uniformValues["g_Color"] == .vector([0.8, 0.2, 0.6, 0.375]))
        #if DEBUG
        #expect(WPEMetalShaderDispatcher.builtinTraceMetadata(for: .solidLayer, passShader: "solidlayer",
                                                              alphaContract: cold.layers[0].passes[0].alphaContract).fragmentShaderName
                == "wpe_solidlayer_straight_fragment")
        #expect(WPEMetalShaderDispatcher.builtinTraceMetadata(for: .solidLayer, passShader: "solidlayer").fragmentShaderName
            == "wpe_solidlayer_fragment")
        #endif
        for mask in 0 ..< (1 << count) {
            var visibility: [String: Bool] = [:]
            for (index, effect) in effects.enumerated() {
                try visibility[#require(effect.pass.visibilityGate?.id)] = mask & (1 << index) != 0
            }
            let frame = canonical.resolvingEffectPublication(passVisibility: visibility, camera: camera)
            let layer = try #require(frame.layers.first)
            let selected = effects.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            #expect(layer.effectPublication == nil)
            #expect(layer.graphLayer.passes == layer.passes.map(\.pass))
            #expect(layer.passes.map(\.id) == [owner.passes[0].id] + selected.map(\.id))
            #expect(layer.passes.allSatisfy { $0.pass.visibilityGate == nil })
            #expect(layer.passes.last?.pass.target == .scene)
            #expect(frame.resolvingEffectPublication(passVisibility: [:], camera: camera) == frame)
            #expect(canonical.layers[0].passes == owner.passes)
            var predecessor = WPETextureReference.fbo(owner.graphLayer.compositeA)
            for (index, effect) in layer.passes.dropFirst().enumerated() {
                #expect(effect.pass.source == predecessor)
                #expect(effect.pass.textures.values.allSatisfy { $0 == predecessor })
                #expect(effect.pass.binds.values.allSatisfy { $0 == predecessor })
                #expect(effect.textureBindings.values.allSatisfy { $0 == predecessor })
                #expect(effect.access.matches(pass: effect.pass, textureBindings: effect.textureBindings))
                #expect(!effect.access.readsCurrentTarget && !effect.access.hasPreviousReference)
                #expect(effect.alphaContract == .init(unpremultipliedInputSlots: [], premultipliedOutput: false))
                let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: effect, recordFailure: false))
                #expect(request.premultipliedInputSlots.isEmpty && !request.premultipliedOutput)
                if index == selected.count - 1 {
                    #expect(effect.pass.target == .scene && effect.pass.blending == "normal")
                    #expect(effect.publicationVertexRole == nil)
                } else {
                    let expected = index.isMultiple(of: 2) ? owner.graphLayer.compositeB : owner.graphLayer.compositeA
                    #expect(effect.pass.target == .layerComposite(name: expected))
                    #expect(effect.pass.blending == "disabled")
                    #expect(effect.publicationVertexRole == .localEffect)
                    #expect(effect.pass.target.textureReference != predecessor)
                    predecessor = .fbo(expected)
                }
            }
            let rebuilt = frame.addingMetalRuntimeUniforms(
                .init(time: 0, daytime: 0, brightness: 1, pointerPosition: .zero), camera: camera,
                scriptedConstants: Dictionary(uniqueKeysWithValues: layer.passes.map { ($0.id, ["roleProbe": .number(1)]) })
            ).pipeline
            #expect(rebuilt.layers[0].passes.map(\.publicationVertexRole) == layer.passes.map(\.publicationVertexRole))
            let overlay = frame.applyingFrameOverlay(.init(visibility: [:], alpha: [owner.id: 0.5], colors: [:]))
            #expect(overlay.layers[0].passes.map(\.publicationVertexRole) == layer.passes.map(\.publicationVertexRole))
        }
        #expect(canonical.resolvingEffectPublication(passVisibility: [:], camera: camera) == cold)
    }

    @Test("Multi-material and ambiguous effect instances reject publication without partial rewrites",
          arguments: ["multi-material", "multi-effect-pass", "duplicate-id", "missing-identity", "external-read", "external-write", "history", "extra-slot", "fbo", "owner-script", "parent", "base-history", "base-foreign-fbo", "base-raw-binding", "base-explicit-target", "copy-history", "copy-foreign-binding", "custom-base", "sampled-authored-source", "vertex-sampled-authored-source", "metadata-authored-source",
                      "vertex-reduction-scale", "fragment-reduction-scale"])
    func effectPublicationRejectsUnprovedChains(scope: String) throws {
        let (fixture, document) = try effectPublicationFixture(count: 2, reverse: false, rejection: scope)
        defer { fixture.cleanup() }
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        var original = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        if scope == "missing-identity" || scope.hasPrefix("base-") || scope.hasPrefix("copy-") {
            let owner = original.layers[0]
            let passes = owner.passes.enumerated().map { index, prepared -> WPEPreparedRenderPass in
                let changesIdentity = scope == "missing-identity" && prepared.pass.authoredJSON.effectIdentity != nil
                let changesBase = scope.hasPrefix("base-") && index == 0
                let changesCopy = scope.hasPrefix("copy-") && index == owner.passes.count - 1
                guard changesIdentity || changesBase || changesCopy else { return prepared }
                let pass = prepared.pass, authored = pass.authoredJSON
                let source: WPETextureReference = scope.hasSuffix("history") ? .previous
                    : (scope == "base-foreign-fbo" ? .fbo("foreign") : pass.source)
                let binds: [Int: WPETextureReference] = scope.hasSuffix("binding") ? [0: .fbo("foreign")] : pass.binds
                var materialPass = authored.materialPass
                if scope == "base-explicit-target" {
                    var fields: [String: WPESceneJSONValue] = [:]
                    if case let .object(existing)? = materialPass {
                        fields = existing
                    }
                    fields["target"] = .string("foreign")
                    materialPass = .object(fields)
                }
                let rewritten = WPERenderPass(
                    id: pass.id, phase: pass.phase, shader: pass.shader, source: source, target: pass.target,
                    textures: pass.textures, binds: binds, constants: pass.constants, combos: pass.combos,
                    userTextureBindings: pass.userTextureBindings,
                    authoredJSON: .init(materialDocument: authored.materialDocument, materialPass: materialPass,
                                        effectDocument: authored.effectDocument, effectPass: authored.effectPass,
                                        effectIdentity: changesIdentity ? nil : authored.effectIdentity),
                    blending: pass.blending, cullMode: pass.cullMode, depthTest: pass.depthTest, depthWrite: pass.depthWrite,
                    constantScripts: pass.constantScripts, visibilityGate: pass.visibilityGate
                )
                return .init(pass: rewritten, shader: prepared.shader, textureBindings: prepared.textureBindings,
                             comboValues: prepared.comboValues, uniformValues: prepared.uniformValues,
                             materialUniformNames: prepared.materialUniformNames, stageUniformBindings: prepared.stageUniformBindings,
                             layerTintOverride: prepared.layerTintOverride, alphaContract: prepared.alphaContract)
            }
            original = .init(layers: [owner.replacing(graphLayer: owner.graphLayer.replacingPasses(passes.map(\.pass)), passes: passes)])
        }
        if scope.hasPrefix("external") {
            let owner = original.layers[0]
            let template = owner.passes[0]
            let consumerPass = WPERenderPass(
                id: "consumer.0", phase: .material, shader: template.pass.shader,
                source: scope == "external-read" ? .fbo(owner.graphLayer.compositeB) : template.pass.source,
                target: scope == "external-write" ? .fbo(name: owner.graphLayer.compositeA) : .scene,
                textures: [:], binds: [:], constants: [:], combos: [:],
                blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
            )
            let consumer = WPERenderLayer(objectID: "consumer", objectName: "consumer", imagePath: "models/solid.json",
                                          materialPath: nil, geometry: .identity, compositeA: "consumer-a", compositeB: "consumer-b",
                                          localFBOs: [], passes: [consumerPass])
            original = WPEPreparedRenderPipeline(layers: original.layers + [WPEPreparedRenderLayer(
                graphLayer: consumer, passes: [.init(pass: consumerPass, shader: template.shader,
                                                     textureBindings: [:], comboValues: [:], uniformValues: [:])]
            )])
        }
        let prepared = WPERenderGraphBuilder.preparingEffectPublication(in: original, camera: camera, permitsVisibilityGates: true)
        #expect(prepared == original)
        #expect(prepared.resolvingEffectPublication(passVisibility: [:], camera: camera) == original)
    }

    @Test("Sampler-free authored white slot remains canonical while selected frame bindings use the active producer")
    func unusedAuthoredEffectTexturePublication() throws {
        let (fixture, document) = try effectPublicationFixture(count: 2, reverse: false, rejection: "unused-authored-source")
        defer { fixture.cleanup() }
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let original = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let canonical = WPERenderGraphBuilder.preparingEffectPublication(in: original, camera: camera, permitsVisibilityGates: true)
        let owner = canonical.layers[0]
        #expect(owner.effectPublication?.scope == .nativeSolidChain)
        #expect(owner.passes == original.layers[0].passes)
        #expect(owner.graphLayer == original.layers[0].graphLayer)
        let effect = owner.passes[1]
        #expect(effect.pass.textures[0] != effect.pass.source)
        #expect(effect.textureBindings[0] == effect.pass.source)
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: effect, recordFailure: false))
        let link = try WPEShaderStageLink(vertex: request.processedVertexSource, fragment: request.processedFragmentSource)
        #expect(!link.interface.variables.contains { $0.glslType.hasPrefix("sampler") })
        let visibility = Dictionary(uniqueKeysWithValues: owner.passes.compactMap { prepared in
            prepared.pass.visibilityGate.map { ($0.id, true) }
        })
        let frame = canonical.resolvingEffectPublication(passVisibility: visibility, camera: camera)
        #expect(frame.layers[0].passes.count == 3)
        var predecessor = WPETextureReference.fbo(owner.graphLayer.compositeA)
        for selected in frame.layers[0].passes.dropFirst() {
            #expect(selected.pass.source == predecessor)
            #expect(selected.pass.textures == [0: predecessor])
            #expect(selected.textureBindings[0] == predecessor)
            #expect(selected.access.matches(pass: selected.pass, textureBindings: selected.textureBindings))
            #expect(!selected.access.readsCurrentTarget)
            predecessor = selected.pass.target.textureReference ?? predecessor
        }
        #expect(canonical.layers[0].passes == owner.passes)
    }

    @Test("Native solid chain publishes a vertex reduction-scale declaration only when proven unreferenced")
    func unreferencedVertexReductionScalePublication() throws {
        let (fixture, document) = try effectPublicationFixture(count: 2, reverse: false, rejection: "unused-vertex-reduction-scale")
        defer { fixture.cleanup() }
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let original = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let canonical = WPERenderGraphBuilder.preparingEffectPublication(in: original, camera: camera, permitsVisibilityGates: true)
        #expect(canonical.layers[0].effectPublication?.scope == .nativeSolidChain)
        #expect(canonical.layers[0].effectPublication?.sourceExtent == nil)
    }

    @Test("Composed fallback for a published pass compiles the published alpha contract, not the canonical one")
    func publishedPassFallbackUsesPublishedAlphaContract() throws {
        let (fixture, document) = try effectPublicationFixture(count: 2, reverse: false, rejection: "compilable")
        defer { fixture.cleanup() }
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let original = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let canonical = WPERenderGraphBuilder.preparingEffectPublication(in: original, camera: camera, permitsVisibilityGates: true)
        let owner = canonical.layers[0]
        #expect(owner.effectPublication?.scope == .nativeSolidChain)
        let visibility = Dictionary(uniqueKeysWithValues: owner.passes.compactMap { prepared in
            prepared.pass.visibilityGate.map { ($0.id, true) }
        })
        let published = canonical.resolvingEffectPublication(passVisibility: visibility, camera: camera).layers[0].passes.dropFirst()
        #expect(published.count == 2)
        let executor = try WPEMetalRenderExecutor(device: #require(MTLCreateSystemDefaultDevice()))
        for effect in owner.passes.dropFirst().dropLast() {
            let canonicalContract = try executor.compileCustomShader(for: effect).alphaContract
            #expect(canonicalContract?.unpremultipliedInputSlots == [0])
        }
        for effect in published {
            let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: effect, recordFailure: false))
            let result = try executor.compileCustomShader(for: effect)
            #expect(result.alphaContract == .init(unpremultipliedInputSlots: request.premultipliedInputSlots,
                                                  premultipliedOutput: request.premultipliedOutput))
            #expect(result.alphaContract == effect.alphaContract)
        }
        for effect in owner.passes.dropFirst().dropLast() {
            #expect(try executor.compileCustomShader(for: effect).alphaContract?.unpremultipliedInputSlots == [0])
        }
    }

    private func effectPublicationFixture(count: Int, reverse: Bool, rejection: String = "") throws
        -> (fixture: Fixture, document: WPESceneDocument) {
        func json(_ value: Any) throws -> String {
            try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
        }
        var material: [String: Any] = ["shader": "chain", "textures": [NSNull()], "blending": "disabled", "cullmode": "nocull"]
        if rejection.hasSuffix("authored-source") {
            material["textures"] = ["util/white"]
        }
        if rejection == "history" {
            material["textures"] = ["previous"]
        }
        if rejection == "extra-slot" {
            material["textures"] = [NSNull(), "external"]
        }
        var asset: [String: Any] = ["passes": [["material": "materials/chain.json"]]]
        if rejection == "multi-effect-pass" {
            asset["passes"] = [["material": "materials/chain.json"], ["material": "materials/chain.json"]]
        }
        if rejection == "fbo" {
            asset["fbos"] = [["name": "scratch", "scale": 1]]
        }
        var vertex = "attribute vec3 a_Position; attribute vec2 a_TexCoord; uniform mat4 g_ModelViewProjectionMatrix; varying vec2 uv; void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1);uv=a_TexCoord;}"
        var fragment = "uniform sampler2D g_Texture0; varying vec2 uv; void main(){vec4 c=texture2D(g_Texture0,uv);gl_FragColor=vec4(c.yx,c.z,c.a*0.5);}"
        if ["unused-authored-source", "metadata-authored-source", "vertex-sampled-authored-source"].contains(rejection) {
            fragment = "varying vec2 uv; void main(){gl_FragColor=vec4(uv,0.25,0.375);}"
        }
        if rejection == "metadata-authored-source" {
            fragment = "uniform vec4 g_Texture0Resolution; varying vec2 uv; void main(){gl_FragColor=vec4(uv*g_Texture0Resolution.zw,0.25,0.375);}"
        }
        if rejection == "vertex-sampled-authored-source" {
            vertex = "attribute vec3 a_Position; attribute vec2 a_TexCoord; uniform mat4 g_ModelViewProjectionMatrix; uniform sampler2D g_Texture0; varying vec2 uv; void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position.xy+texture2D(g_Texture0,a_TexCoord).xy,0,1);uv=a_TexCoord;}"
        }
        if rejection == "vertex-reduction-scale" {
            vertex = "attribute vec3 a_Position; attribute vec2 a_TexCoord; uniform mat4 g_ModelViewProjectionMatrix; uniform float g_TextureReductionScale; varying vec2 uv; void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1);uv=a_TexCoord*g_TextureReductionScale;}"
        }
        if rejection == "unused-vertex-reduction-scale" {
            vertex = "attribute vec3 a_Position; attribute vec2 a_TexCoord; uniform mat4 g_ModelViewProjectionMatrix; uniform float g_TextureReductionScale; varying vec2 uv; void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position,1);uv=a_TexCoord;}"
        }
        if rejection == "fragment-reduction-scale" {
            fragment = "uniform sampler2D g_Texture0; uniform float g_TextureReductionScale; varying vec2 uv; void main(){vec4 c=texture2D(g_Texture0,uv*g_TextureReductionScale);gl_FragColor=c;}"
        }
        if rejection == "compilable" {
            // The transpiler drops whole declaration lines, so main must not share one.
            vertex = vertex.replacingOccurrences(of: "; ", with: ";\n").replacingOccurrences(of: "uv", with: "v_TexCoord")
            fragment = fragment.replacingOccurrences(of: "; ", with: ";\n").replacingOccurrences(of: "uv", with: "v_TexCoord")
        }
        let fixture = try makeFixture(files: [
            "models/solid.json": #"{"material":"materials/base.json"}"#,
            "materials/base.json": #"{"passes":[{"shader":"solidlayer","blending":"normal","cullmode":"nocull"}]}"#,
            "materials/chain.json": json(["passes": rejection == "multi-material" ? [material, material] : [material]]),
            "effects/chain.json": json(asset),
            "shaders/chain.vert": vertex,
            "shaders/chain.frag": fragment,
        ])
        var effects: [[String: Any]] = (0 ..< count).map { index in
            ["id": rejection == "duplicate-id" ? 7 : index + 7, "file": "effects/chain.json",
             "visible": ["value": false, "script": "export function update(v){return engine.userProperties.gate\(index);}"]]
        }
        if reverse {
            effects.reverse()
        }
        var owner: [String: Any] = ["id": 1, "image": rejection == "custom-base" ? "models/solid.json" : "models/util/solidlayer.json",
                                    "origin": "128 64 0", "size": "160 96", "color": "0.8 0.2 0.6", "alpha": 0.375, "effects": effects]
        if rejection == "owner-script" {
            owner["origin"] = ["value": "128 64 0", "script": "export function update(v){return v;}"]
        }
        if rejection == "parent" {
            owner["parent"] = 2
        }
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 128]], "objects": [owner],
        ]))
        return (fixture, document)
    }

    @Test("Static positive flat parent publication preserves full hierarchy shear and rejects incomplete or mutable ancestry",
          arguments: ["identity", "combined", "deep", "missing", "cycle", "parent-link", "negative", "zero", "zero-z", "3d", "overflow", "animation", "leaf-animation", "shape", "effect-script", "cross-layer-script", "text-parent", "parallax"])
    func staticParentPublication(scope: String) throws {
        let fixture = try makeFixture(files: [
            "models/solid.json": #"{"material":"materials/base.json"}"#,
            "materials/base.json": #"{"passes":[{"shader":"solidlayer","blending":"normal"}]}"#,
            "materials/procedural.json": #"{"passes":[{"shader":"parent-probe","blending":"disabled","cullmode":"nocull"}]}"#,
            "effects/procedural.json": #"{"passes":[{"material":"materials/procedural.json"}]}"#,
            "shaders/parent-probe.vert": """
            attribute vec3 a_Position; attribute vec2 a_TexCoord;
            uniform mat4 g_ModelViewProjectionMatrix;
            varying vec2 uv;
            void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position.xy*vec2(0.75,1.2),0,1);uv=a_TexCoord;}
            """,
            "shaders/parent-probe.frag": "varying vec2 uv; void main(){gl_FragColor=vec4(uv,0.25,1.0);}",
        ])
        defer { fixture.cleanup() }
        var parent: [String: Any] = ["id": 2, "name": "parent", "origin": "40 24 0", "scale": "1.1 0.9 1", "angles": "0 0 0.25"]
        if scope == "identity" {
            parent.merge(["origin": "0 0 0", "scale": "1 1 1", "angles": "0 0 0"]) { _, new in new }
        }
        if scope == "negative" {
            parent["scale"] = "-1.1 0.9 1"
        }
        if scope == "zero" {
            parent["scale"] = "1.1 0 1"
        }
        if scope == "zero-z" {
            parent["scale"] = "1.1 0.9 0"
        }
        if scope == "3d" {
            parent["angles"] = "0.2 0 0.25"
        }
        if scope == "overflow" {
            parent["scale"] = "1e40 0.9 1"
        }
        if scope == "cycle" {
            parent["parent"] = 1
        }
        let animatedOrigin: [String: Any] = ["value": "40 24 0", "animation": [
            "c0": [["frame": 0, "value": 40], ["frame": 30, "value": 50]],
            "c1": [["frame": 0, "value": 24], ["frame": 30, "value": 24]],
            "c2": [["frame": 0, "value": 0], ["frame": 30, "value": 0]],
            "options": ["fps": 30, "length": 30, "mode": "loop"],
        ]]
        if scope == "animation" {
            parent["origin"] = animatedOrigin
        }
        if scope == "text-parent" {
            parent["text"] = "parent"
        }
        var effect: [String: Any] = ["id": 3, "file": "effects/procedural.json"]
        if scope == "effect-script" {
            effect["visible"] = ["value": true, "script": "export function update(v){return v;}"]
        }
        var child: [String: Any] = ["id": 1, "name": "child", "image": "models/solid.json", "parent": 2,
                                    "origin": "144 52 0", "scale": "1.2 0.8 1", "angles": "0 0 0.17",
                                    "size": "160 96", "effects": [effect]]
        if scope == "leaf-animation" {
            child["origin"] = animatedOrigin
        }
        if scope == "shape" {
            child["shape"] = "quad"
        }
        var objects = [parent, child]
        if scope == "deep" {
            objects[0]["parent"] = 4
            objects.insert(["id": 4, "name": "grandparent", "origin": "5 6 0", "scale": "0.8 1.3 1", "angles": "0 0 -0.2"], at: 0)
        }
        if scope == "cross-layer-script" {
            objects.append(["id": 5, "name": "writer", "visible": ["value": true, "script": "export function update(v){return v;}"]])
        }
        func document(_ objects: [[String: Any]]) throws -> WPESceneDocument {
            try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
                "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                "general": ["orthogonalprojection": ["width": 256, "height": 128], "cameraparallax": scope == "parallax"], "objects": objects,
            ]))
        }
        let scene = try document(objects)
        if scope == "animation" {
            #expect(scene.transformHostObjects.first?.originAnimation != nil)
        }
        var contextObjects = objects
        if scope == "parent-link" {
            contextObjects[1]["parent"] = 99
        }
        let contextDocument = try document(contextObjects)
        var transforms = WPEMetalSceneRenderer.ancestorLocalTransforms(in: contextDocument)
        if scope == "missing" {
            transforms.removeValue(forKey: "2")
        }
        let context = WPEStaticParentHierarchyContext(document: contextDocument, localTransforms: transforms)
        if ["effect-script", "cross-layer-script", "parallax"].contains(scope) {
            #expect(context == nil)
        }
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: scene)
        if ["identity", "combined", "deep"].contains(scope) {
            let admitted = try #require(context)
            let childGraph = try #require(graph.layers.first { $0.id == "1" })
            #expect(childGraph.parallaxDepth == SIMD2<Double>(1, 1))
            #expect(!scene.general.cameraParallax.enabled)
            let model = try #require(admitted.modelMatrix(for: childGraph))
            #expect(model.count == 16)
        }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: scene.general.orthogonalProjection, sceneCamera: scene.camera)
        let original = try builder.build(graph: graph)
        let canonical = try builder.build(graph: graph, proceduralPublicationCamera: camera, proceduralParentHierarchy: context)
        let pipeline = canonical.resolvingEffectPublication(passVisibility: [:], camera: camera)
        guard ["identity", "combined", "deep"].contains(scope) else {
            #expect(pipeline == original)
            return
        }
        let layer = try #require(pipeline.layers.first { $0.id == "1" })
        let canonicalLayer = try #require(canonical.layers.first { $0.id == "1" })
        #expect(canonicalLayer.passes == original.layers.first { $0.id == "1" }?.passes)
        #expect(canonicalLayer.passes.count == 3 && canonicalLayer.effectPublication != nil)
        #expect(canonicalLayer.effectPublication?.scope == .legacyStaticSingleEffect)
        #expect(canonicalLayer.modelMatrix == nil)
        #expect(layer.effectPublication == nil)
        #expect(layer.passes.allSatisfy { $0.publicationVertexRole == nil })
        #expect(layer.passes.count == 2 && layer.passes.last?.pass.target == .scene)
        #expect(layer.hasStaticParentModel)
        #expect(layer.graphLayer.parentObjectID == "2" && layer.graphLayer.localGeometry != nil)
        #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: layer.graphLayer, camera: camera))
        var resolver = WPEObjectModelMatrixResolver(localTransforms: transforms, parentByID: scene.objectParentByID)
        let resolved = resolver.resolve("1", requiringCompleteHierarchy: true)
        let expected = try #require(resolved)
        #expect(layer.modelMatrixOverride == WPEMetalObjectUniforms.flattenedColumnMajor(expected))
        if scope != "identity" {
            let g = layer.graphLayer.geometry
            let flattened = WPEMetalObjectUniforms.modelMatrix(origin: g.origin, scale: g.scale, angles: g.angles)
            let actualMatrix = try #require(layer.modelMatrixOverride)
            #expect(zip(actualMatrix, WPEMetalObjectUniforms.flattenedColumnMajor(flattened)).contains { abs($0 - $1) > 0.001 })
        }
        let immutable = pipeline.applyingLayerTransforms(origins: ["1": .zero, "2": .zero], scales: [:], angles: [:])
            .resolvingSceneModelMatrices(origins: [:], scales: [:], angles: [:], parentByID: [:], hostTransforms: [:], camera: camera)
        #expect(immutable == pipeline)
        let overlay = pipeline.applyingFrameOverlay(.init(visibility: ["1": false], alpha: ["1": 0.5], colors: [:]))
        #expect(overlay.layers.first { $0.id == "1" }?.modelMatrix == layer.modelMatrix)
        let presentation = pipeline.applyingScriptLayerPresentation(["1": .init(sortIndex: 9)])
        #expect(presentation.layers.first { $0.id == "1" }?.modelMatrix == layer.modelMatrix)
        let sourceExtent = WPERenderSourceExtent(textureSize: CGSize(width: 32, height: 32), imageSize: CGSize(width: 32, height: 32))
        let sized = WPEPreparedRenderPipeline(layers: [layer.replacing(
            graphLayer: layer.graphLayer.replacingPasses(layer.graphLayer.passes, compositeSourceExtent: sourceExtent)
        )]).resolvingSourceMipLevels { _ in 1 }
        #expect(sized.layers[0].graphLayer.compositeSourceExtent?.sourceMipLevel == 1)
        #expect(sized.layers[0].modelMatrix == layer.modelMatrix)
        let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(repeating: 0.5))
        let frame = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera)
        let rebuilt = pipeline.addingMetalRuntimeUniforms(runtime, camera: camera, scriptedConstants: [layer.passes[1].id: ["probe": .number(1)]])
        #expect(rebuilt.pipeline.layers.first { $0.id == "1" }?.modelMatrix == layer.modelMatrix)
        #expect(frame.frameUniforms.affineModelMatrixPassIDs.contains(layer.passes[1].id))
        #expect(frame.frameUniforms.value(named: "g_ModelMatrix", passID: layer.passes[1].id)?.vectorValue == layer.modelMatrixOverride)
        guard scope == "combined" else { return }
        let mvp = try #require(frame.frameUniforms.value(named: "g_ModelViewProjectionMatrix", passID: layer.passes[1].id)?.vectorValue)
        // Windows parent-r2 9000808, terminal event 48; column-major bound VS MVP.
        let captured = [0.009494711644947529, 0.007795349694788456, 0, 0,
                        -0.0024985559284687042, 0.010167608968913555, 0, 0,
                        0, 0, 0.0002500000118743628, 0,
                        0.42107200622558594, 0.6958420276641846, 0.5, 1]
        for (actual, oracle) in zip(mvp, captured) {
            #expect(abs(actual - oracle) < 0.000001)
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let pass = layer.passes[1]
        let request = try #require(executor.authoredPrewarmRequest(for: pass, execution: .authoredObjectQuad))
        let compiled = try executor.shaderCompiler.compile(request)
        executor.seedTranslatedShaderCache([(key: request.translationCacheKey, result: compiled)])
        let prewarm = WPEMetalRenderExecutor.WPETranslatedPipelinePrewarm(
            device: device, defaultLibrary: executor.defaultLibrary, result: compiled, vertexName: nil,
            blendMode: "disabled", alphaWritePolicy: WPEMetalAlphaWritePolicy.resolve(targetID: WPEMetalTargetID(target: .scene), blendMode: "disabled"),
            colorPixelFormat: WPEMetalRenderExecutor.outputPixelFormat, depthPixelFormat: .invalid
        )
        let built = try #require(WPEMetalRenderExecutor.buildTranslatedPipeline(prewarm))
        executor.seedTranslatedPipelines([built])
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 256, height: 128), textures: [:], cameraUniforms: camera)
        executor.frameUniformContext = frame.frameUniforms
        #expect(executor.authoredVertexRejection(for: pass, result: compiled, layer: layer.graphLayer,
                                                 frameState: WPEMetalFrameState(output: output, sceneSize: camera.renderSize, cameraUniforms: camera),
                                                 effectTextureProjection: { nil }) == nil)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: output.pixelFormat, width: 256, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        let staging = try #require(device.makeTexture(descriptor: descriptor))
        let command = try #require(executor.textureSourceCommandQueue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: output, to: staging)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        #expect(command.error == nil)
        var bytes = [UInt8](repeating: 0, count: 256 * 128 * 4)
        bytes.withUnsafeMutableBytes {
            staging.getBytes($0.baseAddress!, bytesPerRow: 256 * 4, from: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0)
        }
        let green = stride(from: 1, to: bytes.count, by: 4).map { bytes[$0] }
        #expect(green.filter { $0 > 0 }.count > 1000)
        #expect(Set(green).count > 32)
    }

    @Test("Static publication eligibility excludes every runtime script family and property binding",
          arguments: ["none", "image-visible", "image-alpha", "image-origin", "image-scale", "image-angles", "image-color",
                      "text", "text-visible", "text-alpha", "host", "transform-host", "effect-visible", "effect-constant", "particle-alpha", "property"])
    func staticPublicationScriptEligibility(scope: String) throws {
        let script = "export function update(v){return v;}"
        let envelope: [String: Any] = ["value": "0 0 0", "script": "export function update(v){v.x += engine.runtime; return v;}"]
        var object: [String: Any] = ["id": 1, "name": "probe", "image": "models/image.json"]
        switch scope {
        case "image-visible": object["visible"] = ["value": true, "script": script]
        case "image-alpha": object["alpha"] = ["value": 1, "script": script]
        case "image-origin": object["origin"] = envelope
        case "image-scale": object["scale"] = envelope
        case "image-angles": object["angles"] = envelope
        case "image-color": object["color"] = envelope
        case "text", "text-visible", "text-alpha":
            object.removeValue(forKey: "image")
            object["text"] = scope == "text" ? ["value": "probe", "script": script] as Any : "probe"
            if scope == "text-visible" {
                object["visible"] = ["value": true, "script": script]
            }
            if scope == "text-alpha" {
                object["alpha"] = ["value": 1, "script": script]
            }
        case "host":
            object.removeValue(forKey: "image")
            object["visible"] = ["value": true, "script": script]
        case "transform-host":
            object.removeValue(forKey: "image")
            object["origin"] = envelope
        case "effect-visible":
            object["effects"] = [["id": 2, "file": "effects/probe.json", "visible": ["value": true, "script": script]]]
        case "effect-constant":
            object["effects"] = [["id": 2, "file": "effects/probe.json", "passes": [["constantshadervalues": ["amount": ["value": 1, "script": script]]]]]]
        case "particle-alpha":
            object.removeValue(forKey: "image")
            object["particle"] = "particles/probe.json"
            object["instanceoverride"] = ["alpha": ["value": 1, "script": script]]
        case "property": object["visible"] = ["value": true, "user": "toggle"]
        default: break
        }
        let scene = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"], "general": ["orthogonalprojection": ["width": 64, "height": 64]], "objects": [object],
        ]))
        if scope == "image-origin" {
            _ = try #require(scene.imageObjects.first?.originScript)
        }
        if scope == "transform-host" {
            _ = try #require(scene.transformHostObjects.first?.originScript)
        }
        #expect(WPEStaticParentHierarchyContext.permitsScriptFreePublication(in: scene) == (scope == "none"))
        #expect(WPEMetalSceneRenderer.permitsEffectGatePublication(in: scene) == (scope == "none" || scope == "effect-visible"))
    }

    @Test("Complete matrix resolution cannot reuse truncated legacy ancestry and accepts the bounded full chain")
    func completeMatrixResolutionKeepsIndependentMemo() throws {
        print("Parent matrix resolver test worker stack bytes: \(pthread_get_stacksize_np(pthread_self()))")
        var locals: [String: WPERenderObjectTransform] = [:]
        var parents: [String: String] = [:]
        for index in 0 ..< 103 {
            locals[String(index)] = .init(origin: SIMD3(1, 0, 0), scale: SIMD3(repeating: 1), angles: .zero)
            if index < 102 {
                parents[String(index)] = String(index + 1)
            }
        }
        var resolver = WPEObjectModelMatrixResolver(localTransforms: locals, parentByID: parents)
        let legacy = resolver.resolve("0", requiringCompleteHierarchy: false)
        let truncated = try #require(legacy)
        #expect(truncated.columns.3.x == 101)
        let tooDeep = resolver.resolve("2", requiringCompleteHierarchy: true)
        #expect(tooDeep == nil)
        let resolved = resolver.resolve("3", requiringCompleteHierarchy: true)
        let complete = try #require(resolved)
        #expect(resolver.completeChain(for: "3")?.count == 100)
        #expect(complete.columns.3.x == 100)
        let missing = resolver.resolve("missing", requiringCompleteHierarchy: true)
        #expect(missing == nil)
        parents["102"] = "3"
        var cyclic = WPEObjectModelMatrixResolver(localTransforms: locals, parentByID: parents)
        let cycle = cyclic.resolve("3", requiringCompleteHierarchy: true)
        #expect(cycle == nil)
        parents["102"] = "102"
        var selfCycle = WPEObjectModelMatrixResolver(localTransforms: locals, parentByID: parents)
        let legacySelf = selfCycle.resolve("102", requiringCompleteHierarchy: false)
        let localOnly = try #require(legacySelf)
        #expect(localOnly.columns.3.x == 1)
        let strictSelf = selfCycle.resolve("102", requiringCompleteHierarchy: true)
        #expect(strictSelf == nil)
        parents["102"] = "missing"
        var orphan = WPEObjectModelMatrixResolver(localTransforms: locals, parentByID: parents)
        let legacyOrphan = orphan.resolve("101", requiringCompleteHierarchy: false)
        let partial = try #require(legacyOrphan)
        #expect(partial.columns.3.x == 2)
        let strictOrphan = orphan.resolve("101", requiringCompleteHierarchy: true)
        #expect(strictOrphan == nil)
    }

    @Test("Static sampled terminal publication separates source extent from object geometry",
          arguments: ["square", "padded", "default-base", "missing", "animated", "oversize", "gated", "extra-sampler"])
    func sampledTerminalExtent(scope: String) throws {
        let width = scope == "square" ? 32 : 31
        let height = scope == "square" ? 32 : 47
        let physicalHeight = scope == "square" ? 32 : 48
        var tex = Data()
        tex.appendCString("TEXV0005")
        tex.appendCString("TEXI0001")
        for value in [0, 0, 32, physicalHeight, scope == "oversize" ? 33 : width, height, 0] {
            tex.appendLE(UInt32(value))
        }
        tex.appendCString("TEXB0001")
        let frames = scope == "animated" ? 2 : 1
        tex.appendLE(UInt32(frames))
        for _ in 0 ..< frames {
            for value in [1, 32, physicalHeight, 32 * physicalHeight * 4] {
                tex.appendLE(UInt32(value))
            }
            tex.append(Data(repeating: 255, count: 32 * physicalHeight * 4))
        }
        let fragment = """
        #include "common.h"
        uniform sampler2D g_Texture0;
        varying vec2 uv;
        varying vec3 facts;
        void main(){ gl_FragColor=vec4(texSample2D(g_Texture0,uv).rg,facts.z,1.0); }
        """ + (scope == "extra-sampler" ? "\nuniform sampler2D g_Texture1;" : "")
        let fixture = try makeFixture(files: [
            "models/image.json": #"{"material":"materials/base.json"}"#,
            "materials/base.json": scope == "default-base"
                ? #"{"passes":[{"shader":"genericimage2","textures":["source"],"cullmode":"nocull"}]}"#
                : #"{"passes":[{"shader":"genericimage2","combos":{"VERSION":2},"textures":["source"],"blending":"normal","cullmode":"nocull"}]}"#,
            "materials/probe.json": #"{"passes":[{"shader":"probe","textures":[null],"blending":"disabled","cullmode":"nocull"}]}"#,
            "effects/probe.json": #"{"passes":[{"material":"materials/probe.json"}]}"#,
            "shaders/probe.vert": """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            uniform mat4 g_ModelViewProjectionMatrix;
            uniform vec4 g_Texture0Resolution;
            uniform float g_TextureReductionScale;
            varying vec2 uv;
            varying vec3 facts;
            void main(){gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position.xy*0.75,0,1);
              uv=a_TexCoord; facts=vec3(g_Texture0Resolution.zw,g_TextureReductionScale);}
            """,
            "shaders/probe.frag": fragment,
        ], dataFiles: scope == "missing" ? [:] : ["materials/source.tex": tex])
        defer { fixture.cleanup() }
        var effect: [String: Any] = ["id": 2, "file": "effects/probe.json"]
        if scope == "gated" {
            effect["visible"] = ["value": true, "script": "export function update(v){return v;}"]
        }
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 128]],
            "objects": [["id": 1, "image": "models/image.json", "origin": "144 52 0", "size": "160 96", "effects": [effect]]],
        ]))
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let original = try builder.build(graph: graph)
        let canonical = try builder.build(graph: graph, proceduralPublicationCamera: camera)
        let result = canonical.resolvingEffectPublication(passVisibility: [:], camera: camera)
        guard ["square", "padded", "default-base"].contains(scope) else {
            #expect(result == original)
            return
        }
        let layer = try #require(result.layers.first)
        #expect(canonical.layers.first?.passes == original.layers.first?.passes)
        #expect(canonical.layers.first?.passes.count == 3 && canonical.layers.first?.effectPublication != nil)
        #expect(canonical.layers.first?.effectPublication?.scope == .legacyStaticSingleEffect)
        #expect(canonical.layers.first?.graphLayer.compositeSourceExtent == nil)
        #expect(layer.passes.count == 2)
        #expect(layer.passes.last?.pass.target == .scene)
        #expect(layer.passes[0].pass.blending == "disabled")
        #expect(layer.passes.allSatisfy { $0.alphaContract == .init(unpremultipliedInputSlots: [], premultipliedOutput: false) })
        let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: layer.passes[1], recordFailure: false))
        #expect(request.premultipliedInputSlots.isEmpty && !request.premultipliedOutput)
        #expect(layer.graphLayer.compositeSourceExtent?.imageSize == CGSize(width: width, height: height))
        #expect(layer.graphLayer.compositeSourceExtent?.textureSize == CGSize(width: 32, height: physicalHeight))
        #expect(layer.graphLayer.geometry.size == CGSize(width: 160, height: 96))
        let inputs = WPEMetalRenderExecutor.authoredObjectQuadInputs(layer: layer.graphLayer)
        #expect(inputs[0].x == -80 && inputs[0].y == 48)
        #expect(abs(inputs[0].z - Float(0.15 / 32)) < 0.000001)
        #expect(abs(inputs[0].w - Float(0.15 / Double(physicalHeight))) < 0.000001)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        let executor = try WPEMetalRenderExecutor(device: device)
        let key = pool.diagnosticKey(for: layer.passes[0].pass.target, layer: layer.graphLayer,
                                     sceneSize: CGSize(width: 256, height: 128), declaredFBOs: [:])
        #expect(key.width == width && key.height == height)
        let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0, brightness: 1,
                                              pointerPosition: .zero, audioSpectrumLeft: [], audioSpectrumRight: [])
        let (_, frame) = result.addingMetalRuntimeUniforms(runtime, camera: camera)
        #expect(frame.value(named: "g_TextureReductionScale", passID: layer.passes[1].id) == .number(1))
        #expect(frame.value(named: "g_TextureReductionScale", passID: "unrelated") == nil)
        #expect(result.resolvingSourceMipLevels { _ in nil } == result)
        #expect(result.resolvingSourceMipLevels { _ in -1 } == result)
        #expect(result.resolvingSourceMipLevels { _ in 15 } == result)
        for mip in [0, 1, 2] {
            let fromCanonical = canonical.resolvingSourceMipLevels { _ in mip }
                .resolvingEffectPublication(passVisibility: [:], camera: camera)
            let reduced = result.resolvingSourceMipLevels { reference in
                #expect(reference == layer.passes[0].textureBindings[0])
                return mip
            }
            let reducedLayer = try #require(reduced.layers.first)
            #expect(fromCanonical == reduced)
            #expect(reducedLayer.passes == layer.passes)
            #expect(reducedLayer.graphLayer.geometry == layer.graphLayer.geometry)
            let imageUniforms = executor.genericImageUniforms(for: reducedLayer.passes[0], layer: reducedLayer.graphLayer, hasMask: false)
            #expect(imageUniforms.textureUVScale.x == Float(width) / 32)
            #expect(imageUniforms.textureUVScale.y == Float(height) / Float(physicalHeight))
            #expect(WPEMetalRenderExecutor.authoredObjectQuadInputs(layer: reducedLayer.graphLayer) == inputs)
            let (_, reducedFrame) = reduced.addingMetalRuntimeUniforms(runtime, camera: camera)
            #expect(reducedFrame.value(named: "g_TextureReductionScale", passID: layer.passes[1].id) == .number(Double(1 << mip)))
            for pixelScale in [1.0, 0.5] {
                pool.pixelScale = pixelScale
                let reducedKey = pool.diagnosticKey(for: layer.passes[0].pass.target, layer: reducedLayer.graphLayer,
                                                    sceneSize: CGSize(width: 256, height: 128), declaredFBOs: [:])
                #expect(reducedKey.width == max(4, width >> mip))
                #expect(reducedKey.height == max(4, height >> mip))
            }
        }
    }

    @Test("Terminal procedural effects retain authored geometry and disabled blend at scene publication",
          arguments: ["direct", "zero", "zero-inverse", "gated", "sampler", "viewport", "texture-metadata", "wide-attribute", "explicit-target", "blend", "layer-blend", "multiple-effects", "depth", "perspective", "hdr", "textured-base", "external-reader"])
    func terminalProceduralPublication(scope: String) throws {
        var material: [String: Any] = ["shader": "procedural", "blending": scope == "blend" ? "normal" : "disabled",
                                       "depthtest": scope == "depth" ? "enabled" : "disabled", "cullmode": "front"]
        material["textures"] = []
        var effectPass: [String: Any] = ["material": "materials/procedural.json"]
        if scope == "explicit-target" {
            effectPass["target"] = "scratch"
        }
        var effect: [String: Any] = ["id": 3, "file": "effects/procedural.json"]
        if scope == "gated" {
            effect["visible"] = ["value": true, "script": "export function update(v){return v;}"]
        }
        var vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        uniform mat4 g_ModelViewProjectionMatrix;
        uniform float g_Scale; // {"material":"scale","default":0.75}
        varying vec2 uv;
        void main() { gl_Position=g_ModelViewProjectionMatrix*vec4(a_Position.xy*vec2(g_Scale,1.2),0,1); uv=a_TexCoord; }
        """
        if scope == "texture-metadata" {
            vertex += "\nuniform float g_TextureReductionScale;"
        }
        if scope == "zero-inverse" {
            vertex += "\nuniform mat4 g_ModelViewProjectionMatrixInverse;"
        }
        if scope == "wide-attribute" {
            vertex = vertex.replacingOccurrences(of: "attribute vec2", with: "attribute vec4")
        }
        let extra = scope == "sampler" ? "uniform sampler2D g_Texture0;\n" : (scope == "viewport" ? "uniform vec4 g_Resolution;\n" : "")
        func json(_ value: Any) throws -> String {
            let data = try JSONSerialization.data(withJSONObject: value)
            return try #require(String(data: data, encoding: .utf8))
        }
        let fixture = try makeFixture(files: [
            "models/solid.json": #"{"material":"materials/base.json"}"#,
            "materials/base.json": json(["passes": [["shader": scope == "textured-base" ? "genericimage2" : "solidlayer",
                                                     "blending": scope == "layer-blend" ? "additive" : "normal"]]]),
            "materials/procedural.json": json(["passes": [material]]),
            "effects/procedural.json": json(["passes": [effectPass]]),
            "shaders/procedural.vert": vertex,
            "shaders/procedural.frag": extra + "varying vec2 uv; void main(){gl_FragColor=vec4(uv,0.25,0.375);}",
        ])
        defer { fixture.cleanup() }
        var effects = [effect]
        if scope == "multiple-effects" {
            effects.append(["id": 4, "file": "effects/procedural.json"])
        }
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 128]],
            "objects": [["id": 1, "image": "models/solid.json", "origin": "128 64 0", "size": "160 96",
                         "scale": scope.hasPrefix("zero") ? "1.2 0 1" : "1 1 1", "effects": effects]],
        ]))
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection,
                                            sceneCamera: document.camera, usesPerspectiveProjection: scope == "perspective",
                                            sceneHDR: scope == "hdr")
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let original = try builder.build(graph: graph)
        if scope == "external-reader" {
            let producer = try #require(original.layers.first)
            let copy = try #require(producer.passes.last)
            let consumer = WPERenderLayer(objectID: "consumer", objectName: "consumer", imagePath: "models/solid.json",
                                          materialPath: nil, geometry: .identity, compositeA: "consumer-a", compositeB: "consumer-b",
                                          localFBOs: [], passes: [copy.pass])
            let shared = WPEPreparedRenderPipeline(layers: original.layers + [WPEPreparedRenderLayer(graphLayer: consumer, passes: [copy])])
            #expect(WPERenderGraphBuilder.preparingEffectPublication(in: shared, camera: camera) == shared)
            return
        }
        let canonical = try builder.build(graph: graph, proceduralPublicationCamera: camera)
        let result = canonical.resolvingEffectPublication(passVisibility: [:], camera: camera)
        if scope == "direct" || scope == "zero" {
            let before = try #require(original.layers.first)
            let after = try #require(result.layers.first)
            #expect(canonical.layers.first?.passes == before.passes)
            #expect(canonical.layers.first?.effectPublication != nil)
            #expect(after.effectPublication == nil)
            #expect(before.passes.count == 3 && after.passes.count == 2)
            #expect(after.passes[1].pass.target == .scene)
            #expect(after.passes[1].pass.blending == "disabled")
            #expect(after.passes[1].pass.id == before.passes[1].pass.id)
            #expect(after.passes[1].pass.authoredJSON == before.passes[1].pass.authoredJSON)
            #expect(after.passes[1].shader == before.passes[1].shader)
            #expect(after.passes[1].stageUniformBindings == before.passes[1].stageUniformBindings)
            let request = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: after.passes[1], recordFailure: false))
            let originalRequest = try #require(try WPEMetalRenderExecutor.makeCompileRequest(for: before.passes[1], recordFailure: false))
            #expect(!request.premultipliedOutput)
            #expect(originalRequest.premultipliedOutput)
            #expect(request.translationCacheKey != originalRequest.translationCacheKey)
            #expect(WPEMetalRenderExecutor.compiledShaderEntryKey(for: after.passes[1])
                != WPEMetalRenderExecutor.compiledShaderEntryKey(for: before.passes[1]))
            #expect(request.processedVertexSource == originalRequest.processedVertexSource)
            #expect(request.processedFragmentSource == originalRequest.processedFragmentSource)
        } else {
            #expect(result == original)
        }
    }

    @Test("Admitted terminal image effects preserve authored cull provenance while normalizing native semantics",
          arguments: ["omitted", "nocull", "normal", "inverted", "back", "front", "probe_unknown_cull"], [1.2, -1.2])
    func terminalEffectCullVocabulary(raw: String, scaleX: Double) throws {
        var material: [String: Any] = ["shader": "cull-probe", "blending": "disabled"]
        if raw != "omitted" {
            material["cullmode"] = raw
        }
        func json(_ value: Any) throws -> String {
            try #require(String(data: JSONSerialization.data(withJSONObject: value), encoding: .utf8))
        }
        let fixture = try makeFixture(files: [
            "models/solid.json": #"{"material":"materials/base.json"}"#,
            "materials/base.json": #"{"passes":[{"shader":"solidlayer","blending":"normal","cullmode":"nocull"}]}"#,
            "materials/probe.json": json(["passes": [material]]),
            "effects/probe.json": #"{"passes":[{"material":"materials/probe.json"}]}"#,
            "shaders/cull-probe.vert": """
            attribute vec3 a_Position;
            attribute vec2 a_TexCoord;
            uniform mat4 g_ModelViewProjectionMatrix;
            varying vec2 uv;
            void main() { gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1); uv = a_TexCoord; }
            """,
            "shaders/cull-probe.frag": "varying vec2 uv; void main() { gl_FragColor = vec4(uv, 0.25, 1); }",
        ])
        defer { fixture.cleanup() }
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 256, "height": 128]],
            "objects": [["id": 1, "image": "models/solid.json", "origin": "144 52 0", "size": "160 96",
                         "scale": "\(scaleX) 0.8 1", "angles": "0 0 0.17",
                         "effects": [["id": 3, "file": "effects/probe.json"]]]],
        ]))
        let graph = try WPERenderGraphBuilder(cacheRootURL: fixture.root).build(document: document)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: document.general.orthogonalProjection, sceneCamera: document.camera)
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)
        let original = try builder.build(graph: graph)
        let canonical = try builder.build(graph: graph, proceduralPublicationCamera: camera)
        let result = canonical.resolvingEffectPublication(passVisibility: [:], camera: camera)
        let before = try #require(original.layers.first)
        let after = try #require(result.layers.first)
        #expect(canonical.layers.first?.passes == before.passes)
        #expect(canonical.layers.first?.effectPublication != nil)
        #expect(before.passes.count == 3 && after.passes.count == 2)
        let terminal = after.passes[1]
        #expect(terminal.pass.target == .scene)
        #expect(terminal.pass.cullMode == (raw == "nocull" ? "nocull" : "back"))
        #expect(terminal.pass.authoredJSON.materialPass?["cullmode"] == (raw == "omitted" ? nil : .string(raw)))
        #expect(terminal.pass.authoredJSON == before.passes[1].pass.authoredJSON)
        #expect(terminal.pass.id == before.passes[1].pass.id)
        #expect(terminal.pass.constants == before.passes[1].pass.constants)
        #expect(terminal.textureBindings == before.passes[1].textureBindings)
        #expect(terminal.shader == before.passes[1].shader)
        #expect(after.passes[0] == before.passes[0])
        #expect(after.graphLayer.passes == after.passes.map(\.pass))
        #expect(WPEMetalRenderExecutor.canSupplyAuthoredObjectQuad(layer: after.graphLayer, camera: camera))
    }

    @Test("Official TEXnFORMAT ABI values stay independent from decoder raw values")
    func officialTextureFormatABIValues() {
        #expect(WPEOfficialTextureFormatABI.rgba8888 == 0)
        #expect(WPEOfficialTextureFormatABI.rgb888 == 1)
        #expect(WPEOfficialTextureFormatABI.rgb565 == 2)
        #expect(WPEOfficialTextureFormatABI.etc1RGB8 == 3)
        #expect(WPEOfficialTextureFormatABI.dxt5 == 4)
        #expect(WPEOfficialTextureFormatABI.etc2RGBA8 == 5)
        #expect(WPEOfficialTextureFormatABI.dxt3 == 6)
        #expect(WPEOfficialTextureFormatABI.dxt1 == 7)
        #expect(WPEOfficialTextureFormatABI.rg88 == 8)
        #expect(WPEOfficialTextureFormatABI.r8 == 9)
        #expect(WPEOfficialTextureFormatABI.rg1616F == 10)
        #expect(WPEOfficialTextureFormatABI.r16F == 11)
        #expect(WPEOfficialTextureFormatABI.bc7 == 12)
        #expect(WPEOfficialTextureFormatABI.shaderValue(forTextureFormatCode: 3) == 3)
        #expect(WPEOfficialTextureFormatABI.shaderValue(forTextureFormatCode: 12) == 12)
        #expect(WPEOfficialTextureFormatABI.shaderValue(forTextureFormatCode: 13) == nil)
    }

    @Test("TEXnFORMAT comes from bound TEXI headers and participates in compile identity")
    func textureFormatsComeFromBoundHeadersAndCompileIdentity() throws {
        func makeGraph() -> WPERenderGraph {
            WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "format",
                    objectName: "Format probe",
                    imagePath: "normal",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "format.0",
                            phase: .effect(file: "effects/format_probe/effect.json"),
                            shader: "effects/format_probe",
                            source: .image("normal"),
                            target: .scene,
                            textures: [
                                1: .image("mask"),
                                2: .image("native.png"),
                                3: .fbo("_rt_NormalScratch"),
                                5: .image("broken.tex"),
                                6: .image("missing.tex")
                            ],
                            binds: [:],
                            constants: [:],
                            // A material-authored value must not override runtime TEXI.
                            combos: ["TEX1FORMAT": 999],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
        }

        let shaderFiles = [
            "shaders/effects/format_probe.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/format_probe.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture1;
            void main() {
            #if TEX0FORMAT == FORMAT_DXT5
                gl_FragColor = DecompressNormal(texSample2D(g_Texture1, vec2(0.5))).xyzz;
            #else
                gl_FragColor = texSample2D(g_Texture0, vec2(0.5));
            #endif
            }
            """
        ]
        let first = try makeFixture(
            files: shaderFiles.merging(["native.png": "not decoded by the header probe"]) { lhs, _ in lhs },
            dataFiles: [
                "materials/normal.tex": makeHeaderOnlyTex(formatCode: 4),
                "materials/mask.tex": makeHeaderOnlyTex(formatCode: 8),
                "broken.tex": Data("not-a-tex".utf8)
            ]
        )
        defer { first.cleanup() }

        let firstPass = try #require(
            WPERenderPipelineBuilder(cacheRootURL: first.root)
                .build(graph: makeGraph()).layers.first?.passes.first
        )
        #expect(firstPass.comboValues["TEX0FORMAT"] == WPEOfficialTextureFormatABI.dxt5)
        #expect(firstPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rg88)
        #expect(firstPass.comboValues["TEX2FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX3FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX4FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX5FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX6FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.comboValues["TEX7FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(firstPass.shader?.fragmentSource.contains("#define TEX0FORMAT 4") == true)
        #expect(firstPass.shader?.fragmentSource.contains("#define TEX1FORMAT 8") == true)

        let second = try makeFixture(
            files: shaderFiles,
            dataFiles: [
                "materials/normal.tex": makeHeaderOnlyTex(formatCode: 12),
                "materials/mask.tex": makeHeaderOnlyTex(formatCode: 8)
            ]
        )
        defer { second.cleanup() }
        let secondPass = try #require(
            WPERenderPipelineBuilder(cacheRootURL: second.root)
                .build(graph: makeGraph()).layers.first?.passes.first
        )
        let firstRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: firstPass, recordFailure: false)
        )
        let secondRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: secondPass, recordFailure: false)
        )
        #expect(secondPass.comboValues["TEX0FORMAT"] == WPEOfficialTextureFormatABI.bc7)
        #expect(firstRequest.sourceHash != secondRequest.sourceHash)
        #expect(firstRequest.translationCacheKey != secondRequest.translationCacheKey)
    }

    @Test("TEXnFORMAT follows model and material JSON to the bound TEX")
    func textureFormatFollowsIndirectImageReference() throws {
        let fixture = try makeFixture(
            files: [
                "models/wrapped.json": #"{"material":"materials/wrapped.json"}"#,
                "materials/wrapped.json": #"{"passes":[{"textures":["wrapped-normal"]}]}"#,
                "shaders/effects/format_probe.vert": """
                attribute vec3 a_Position;
                void main() { gl_Position = vec4(a_Position, 1.0); }
                """,
                "shaders/effects/format_probe.frag": """
                #include "common_fragment.h"
                uniform sampler2D g_Texture0;
                void main() {
                #if TEX0FORMAT == FORMAT_RG88
                    gl_FragColor = DecompressNormal(texSample2D(g_Texture0, vec2(0.5))).xyzz;
                #else
                    gl_FragColor = texSample2D(g_Texture0, vec2(0.5));
                #endif
                }
                """,
            ],
            dataFiles: [
                "materials/wrapped-normal.tex": makeHeaderOnlyTex(formatCode: 8),
            ]
        )
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "indirect-format",
                objectName: "Indirect format probe",
                imagePath: "models/wrapped.json",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "indirect-format.0",
                        phase: .effect(file: "effects/format_probe/effect.json"),
                        shader: "effects/format_probe",
                        source: .image("models/wrapped.json"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                ]
            ),
        ])

        let pass = try #require(
            WPERenderPipelineBuilder(cacheRootURL: fixture.root)
                .build(graph: graph).layers.first?.passes.first
        )
        #expect(pass.comboValues["TEX0FORMAT"] == WPEOfficialTextureFormatABI.rg88)
        #expect(pass.shader?.fragmentSource.contains("#define TEX0FORMAT 8") == true)
    }

    @Test("TEXnFORMAT for an FBO slot comes from the layer's authored FBO format")
    func textureFormatsForFBOSlotsComeFromTheGraph() throws {
        /// Reporting RGBA8888 for an rg88 or r8 target would send a branch-on-format shader down the wrong channel swizzle.
        func makeGraph(scratchFormat: String) -> WPERenderGraph {
            WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "fboformat",
                    objectName: "FBO format probe",
                    imagePath: "normal",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [
                        WPERenderFBO(name: "_rt_Scratch", scale: 1, format: scratchFormat),
                        WPERenderFBO(name: "_rt_Mask", scale: 1, format: "r8")
                    ],
                    passes: [
                        WPERenderPass(
                            id: "fboformat.0",
                            phase: .effect(file: "effects/format_probe/effect.json"),
                            shader: "effects/format_probe",
                            source: .image("normal"),
                            target: .scene,
                            textures: [
                                1: .fbo("_rt_Scratch"),
                                2: .fbo("_rt_Mask"),
                                3: .fbo("_rt_FullFrameBuffer"),
                                4: .previous
                            ],
                            binds: [:],
                            constants: [:],
                            combos: [:],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
        }

        let shaderFiles = [
            "shaders/effects/format_probe.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/format_probe.frag": """
            #include "common_fragment.h"
            void main() { gl_FragColor = vec4(1.0); }
            """
        ]

        let fixture = try makeFixture(files: shaderFiles, dataFiles: [:])
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)

        let rg88Pass = try #require(
            builder.build(graph: makeGraph(scratchFormat: "rg88")).layers.first?.passes.first
        )
        #expect(rg88Pass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rg88)
        #expect(rg88Pass.comboValues["TEX2FORMAT"] == WPEOfficialTextureFormatABI.r8)
        // A scene alias is not a layer-local FBO; it resolves to the RGBA scene target.
        #expect(rg88Pass.comboValues["TEX3FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(rg88Pass.comboValues["TEX4FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(rg88Pass.shader?.fragmentSource.contains("#define TEX1FORMAT 8") == true)

        // Same shader, different authored target format ⇒ different compile identity,
        // or the two variants would share one cached MSL translation.
        let r16fPass = try #require(
            builder.build(graph: makeGraph(scratchFormat: "r16f")).layers.first?.passes.first
        )
        #expect(r16fPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.r16F)
        let rg88Request = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: rg88Pass, recordFailure: false)
        )
        let r16fRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: r16fPass, recordFailure: false)
        )
        #expect(rg88Request.sourceHash != r16fRequest.sourceHash)
        #expect(rg88Request.translationCacheKey != r16fRequest.translationCacheKey)
    }

    @Test("TEXnFORMAT for a `.previous` slot inherits the pass target's authored FBO format")
    func textureFormatsForPreviousSlotsInheritThePassTargetFormat() throws {
        /// `.previous` samples the prior frame of the pass's OWN target, so a feedback
        /// pass into an rg1616f FBO must compile with that format, not RGBA.
        func makeGraph(targetFormat: String) -> WPERenderGraph {
            WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "prevformat",
                    objectName: "Previous format probe",
                    imagePath: "normal",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [
                        WPERenderFBO(name: "_rt_Feedback", scale: 1, format: targetFormat),
                        WPERenderFBO(name: "_rt_Aux", scale: 1, format: "r8"),
                    ],
                    passes: [
                        WPERenderPass(
                            id: "prevformat.0",
                            phase: .effect(file: "effects/format_probe/effect.json"),
                            shader: "effects/format_probe",
                            source: .image("normal"),
                            target: .fbo(name: "_rt_Feedback"),
                            textures: [
                                1: .previous,
                                2: .fbo("_rt_Aux"),
                                3: .image("mask"),
                            ],
                            binds: [:],
                            constants: [:],
                            combos: [:],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        ),
                    ]
                ),
            ])
        }

        let shaderFiles = [
            "shaders/effects/format_probe.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/format_probe.frag": """
            #include "common_fragment.h"
            void main() { gl_FragColor = vec4(1.0); }
            """,
        ]

        let fixture = try makeFixture(
            files: shaderFiles,
            dataFiles: ["materials/mask.tex": makeHeaderOnlyTex(formatCode: 8)]
        )
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)

        let rg1616fPass = try #require(
            builder.build(graph: makeGraph(targetFormat: "rg1616f")).layers.first?.passes.first
        )
        #expect(rg1616fPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rg1616F)
        #expect(rg1616fPass.comboValues["TEX2FORMAT"] == WPEOfficialTextureFormatABI.r8)
        #expect(rg1616fPass.comboValues["TEX3FORMAT"] == WPEOfficialTextureFormatABI.rg88)

        let r16fPass = try #require(
            builder.build(graph: makeGraph(targetFormat: "r16f")).layers.first?.passes.first
        )
        #expect(r16fPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.r16F)
        let rg1616fRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: rg1616fPass, recordFailure: false)
        )
        let r16fRequest = try #require(
            try WPEMetalRenderExecutor.makeCompileRequest(for: r16fPass, recordFailure: false)
        )
        #expect(rg1616fRequest.sourceHash != r16fRequest.sourceHash)
        #expect(rg1616fRequest.translationCacheKey != r16fRequest.translationCacheKey)

        let rgbaPass = try #require(
            builder.build(graph: makeGraph(targetFormat: "rgba8888")).layers.first?.passes.first
        )
        #expect(rgbaPass.comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)

        // The target format may influence ONLY the `.previous` slot: every other slot must
        // resolve identically across target formats, or plumbing leaked into unrelated keys.
        for slot in 0 ..< WPEShaderTranspiler.customTextureSlotLimit where slot != 1 {
            let macro = "TEX\(slot)FORMAT"
            #expect(rg1616fPass.comboValues[macro] == rgbaPass.comboValues[macro])
        }
    }

    private static let crossLayerFormats: [(authored: String, abi: Int)] = [
        ("rg88", WPEOfficialTextureFormatABI.rg88),
        ("r8", WPEOfficialTextureFormatABI.r8),
        ("rg1616f", WPEOfficialTextureFormatABI.rg1616F),
    ]

    @Test(
        "TEXnFORMAT for an FBO declared by another layer follows that declaration (the pool allocates it that way)",
        arguments: crossLayerFormats.indices
    )
    func textureFormatsForCrossLayerFBOReferencesFollowTheDeclaringLayer(formatIndex: Int) throws {
        let format = Self.crossLayerFormats[formatIndex]
        let writer = WPERenderLayer(
            objectID: "writer",
            objectName: "Declares and writes the FBO",
            imagePath: "normal",
            materialPath: nil,
            geometry: .identity,
            compositeA: "wa",
            compositeB: "wb",
            localFBOs: [WPERenderFBO(name: "_rt_CrossLayer", scale: 1, format: format.authored)],
            passes: [formatProbePass(id: "writer.0", target: .fbo(name: "_rt_CrossLayer"), textures: [:])]
        )
        let reader = WPERenderLayer(
            objectID: "reader",
            objectName: "Samples the other layer's FBO",
            imagePath: "normal",
            materialPath: nil,
            geometry: .identity,
            compositeA: "ra",
            compositeB: "rb",
            localFBOs: [],
            passes: [
                formatProbePass(
                    id: "reader.0",
                    target: .scene,
                    textures: [1: .fbo("_rt_CrossLayer"), 2: .previous, 3: .fbo("_rt_FullFrameBuffer")]
                ),
                // Feedback into the other layer's FBO: `.previous` inherits its declared format too.
                formatProbePass(id: "reader.1", target: .fbo(name: "_rt_CrossLayer"), textures: [1: .previous]),
            ]
        )
        let fixture = try makeFixture(files: formatProbeShaderFiles)
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: WPERenderGraph(layers: [writer, reader]))
        let readerPasses = try #require(pipeline.layers.last?.passes)
        #expect(readerPasses[0].comboValues["TEX1FORMAT"] == format.abi)
        #expect(readerPasses[0].comboValues["TEX2FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(readerPasses[0].comboValues["TEX3FORMAT"] == WPEOfficialTextureFormatABI.rgba8888)
        #expect(readerPasses[1].comboValues["TEX1FORMAT"] == format.abi)
    }

    @Test("Duplicate FBO names across layers resolve to the last declaration, matching the pool's allocation")
    func duplicateFBONamesResolveToTheLastDeclarationLikeThePool() throws {
        let first = WPERenderLayer(
            objectID: "first",
            objectName: "First declaration",
            imagePath: "normal",
            materialPath: nil,
            geometry: .identity,
            compositeA: "fa",
            compositeB: "fb",
            localFBOs: [WPERenderFBO(name: "_rt_Dup", scale: 1, format: "rg1616f")],
            passes: [formatProbePass(id: "first.0", target: .scene, textures: [1: .fbo("_rt_Dup")])]
        )
        let second = WPERenderLayer(
            objectID: "second",
            objectName: "Last declaration wins",
            imagePath: "normal",
            materialPath: nil,
            geometry: .identity,
            compositeA: "sa",
            compositeB: "sb",
            localFBOs: [WPERenderFBO(name: "_rt_Dup", scale: 1, format: "r8")],
            passes: [formatProbePass(id: "second.0", target: .scene, textures: [1: .fbo("_rt_Dup")])]
        )
        let fixture = try makeFixture(files: formatProbeShaderFiles)
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: WPERenderGraph(layers: [first, second]))
        for layer in pipeline.layers {
            #expect(
                layer.passes[0].comboValues["TEX1FORMAT"] == WPEOfficialTextureFormatABI.r8,
                Comment(rawValue: layer.graphLayer.objectID)
            )
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        pool.prepare(pipeline: pipeline)
        #expect(pool.zeroFilledPlaceholderTexture(forDeclaredFBO: "_rt_Dup")?.pixelFormat == .r8Unorm)
    }

    private var formatProbeShaderFiles: [String: String] {
        [
            "shaders/effects/format_probe.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/format_probe.frag": """
            #include "common_fragment.h"
            void main() { gl_FragColor = vec4(1.0); }
            """,
        ]
    }

    private func formatProbePass(
        id: String, target: WPERenderTarget, textures: [Int: WPETextureReference]
    ) -> WPERenderPass {
        WPERenderPass(
            id: id,
            phase: .effect(file: "effects/format_probe/effect.json"),
            shader: "effects/format_probe",
            source: .image("normal"),
            target: target,
            textures: textures,
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
    }

    @Test("SceneScript transform journal overlays current-generation assignments before geometry preparation")
    func sceneScriptTransformJournalGeometryMerge() throws {
        let layer = WPERenderLayer(
            objectID: "mover",
            objectName: "Mover",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(10, 20, 30),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 100, height: 50),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [])
        ])
        var animated = WPEMetalSceneRenderer.LiveScriptTransforms()
        animated.origins["mover"] = SIMD3<Double>(11, 22, 33)
        animated.scales["mover"] = SIMD3<Double>(1.25, 1.5, 1.75)
        animated.angles["mover"] = SIMD3<Double>(0.1, 0.2, 0.3)

        var journal = WPESceneScriptTransformMutationJournal()
        journal.record(
            WPELayerScriptTransformMutation(origin: SIMD3<Double>(100, 200, 300)),
            objectID: "mover",
            generation: 7
        )
        // Same objectID from a retired load must not affect generation 7.
        journal.record(
            WPELayerScriptTransformMutation(scale: SIMD3<Double>(9, 9, 9)),
            objectID: "mover",
            generation: 6
        )
        let merged = journal.applying(to: animated, generation: 7)
        let geometry = try #require(pipeline.applyingLayerTransforms(
            origins: merged.origins,
            scales: merged.scales,
            angles: merged.angles
        ).layers.first).graphLayer.geometry

        #expect(geometry.origin == SIMD3<Double>(100, 200, 300))
        #expect(geometry.scale == SIMD3<Double>(1.25, 1.5, 1.75))
        #expect(geometry.angles == SIMD3<Double>(0.1, 0.2, 0.3))

        journal.record(
            WPELayerScriptTransformMutation(angles: SIMD3<Double>(0, 0, 90)),
            objectID: "mover",
            generation: 7
        )
        let angleMerged = journal.applying(to: animated, generation: 7)
        #expect(abs((angleMerged.angles["mover"]?.z ?? 0) - .pi / 2) < 0.000_001)
    }

    @Test("Normalizes built-in shader aliases consistently")
    func normalizesBuiltinShaderAliasesConsistently() {
        #expect(WPEBuiltinShaderName.normalized("materials/util/solidlayer.json") == "solidlayer")
        #expect(WPEBuiltinShaderName.normalized("materials/effects/blur/blur.json") == "effect_blur")
        #expect(WPEBuiltinShaderName.normalized("composelayer") == "compose")
        #expect(WPEBuiltinShaderName.normalized("materials/util/composelayer.json") == "compose")
        #expect(WPEBuiltinShaderName.normalized("effects/distort/distort") == "effect_water")
        #expect(WPEBuiltinShaderName.normalized("genericimage2") == "genericimage2")
        #expect(WPEBuiltinShaderName.normalized("generic4") == "genericimage4")
        #expect(WPEBuiltinShaderName.normalized("genericimage2", genericImageAsCopy: true) == "copy")
        #expect(WPEBuiltinShaderName.normalized("genericimage_custom", genericImageAsCopy: true) == "genericimage_custom")
    }

    @Test("Script-driven alpha/transform rewrites keep shape:quad points")
    func scriptAlphaAndTransformRewritesKeepShapeQuadPoints() throws {
        let points = [
            SIMD2<Double>(0.4, 0.25),
            SIMD2<Double>(0.6, 0.25),
            SIMD2<Double>(0.94451, 0.83623),
            SIMD2<Double>(0.09498, 0.88795)
        ]
        let layer = WPERenderLayer(
            objectID: "96",
            objectName: "beam",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(100, 200, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 200, height: 100),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1,
                shapePoints: points
            ),
            compositeA: "_rt_imageLayerComposite_96_a",
            compositeB: "_rt_imageLayerComposite_96_b",
            localFBOs: [],
            passes: []
        )

        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: layer, passes: [])
        ])

        let faded = try #require(pipeline.applyingFrameOverlay(WPEFrameOverlay(alpha: ["96": 0.5])).layers.first).graphLayer
        #expect(faded.geometry.alpha == 0.5)
        #expect(faded.geometry.shapePoints == points)

        let animatedColor = WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[.init(frame: 0, value: 0)], [.init(frame: 0, value: 1)], [.init(frame: 0, value: 0)]],
                fps: 30, length: 30, mode: "loop", wrapLoop: true
            ),
            scalarFallback: nil,
            vectorFallback: [0, 1, 0]
        )
        let animatedLayer = WPERenderLayer(
            objectID: "96",
            objectName: "beam",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(100, 200, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 200, height: 100),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                colorAnimation: animatedColor,
                brightness: 1
            ),
            compositeA: "_rt_imageLayerComposite_96_a",
            compositeB: "_rt_imageLayerComposite_96_b",
            localFBOs: [],
            passes: []
        )
        let animatedPipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: animatedLayer, passes: [])
        ])
        let movedAnimated = try #require(animatedPipeline.applyingLayerTransforms(
            origins: ["96": SIMD3<Double>(150, 250, 0)],
            scales: [:],
            angles: [:]
        ).layers.first).graphLayer
        #expect(
            movedAnimated.geometry.colorAnimation != nil,
            "a live transform must not discard the layer's authored color animation"
        )

        let tinted = try #require(
            pipeline.applyingFrameOverlay(WPEFrameOverlay(colors: ["96": SIMD3<Double>(0.2, 0.4, 0.6)])).layers.first
        ).graphLayer
        #expect(tinted.geometry.color == SIMD3<Double>(0.2, 0.4, 0.6))
        #expect(tinted.geometry.colorAnimation == nil, "the override must not be re-collapsed per frame")
        #expect(tinted.geometry.alpha == 1, "color override must not disturb alpha")

        let moved = try #require(pipeline.applyingLayerTransforms(
            origins: ["96": SIMD3<Double>(150, 250, 0)],
            scales: [:],
            angles: [:]
        ).layers.first).graphLayer
        #expect(moved.geometry.origin == SIMD3<Double>(150, 250, 0))
        #expect(moved.geometry.shapePoints == points)
    }

    @Test("Builds prepared shader programs from render graph passes")
    func buildsPreparedShaderProgramsFromGraphPasses() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/custom.vert": """
            // [COMBO] {"combo":"KERNEL","default":1}
            #include "common.h"
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/custom.frag": """
            uniform sampler2D g_Texture0;
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "genericimage2",
                        source: .image("materials/base.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "7.1",
                        phase: .effect(file: "effects/custom/effect.json"),
                        shader: "effects/custom",
                        source: .fbo("_rt_imageLayerComposite_7_a"),
                        target: .scene,
                        textures: [:],
                        binds: [0: .previous],
                        constants: [:],
                        combos: ["KERNEL": 2],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let layer = try #require(pipeline.layers.first)

        #expect(layer.passes.map(\.pass.shader) == ["genericimage2", "effects/custom"])
        #expect(layer.passes[0].shader?.isBuiltin == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("#define KERNEL 2") == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("wpe_common_included") == true)
        #expect(layer.passes[1].shader?.vertexSource.contains("#include") == false)
        #expect(layer.passes[1].shader?.fragmentSource.contains("#define texSample2D") == true)
    }

    @Test("Texture-declared combo (MASK) auto-enables when its sampler slot is bound")
    func textureDeclaredComboEnablesWhenSamplerSlotBound() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/masked.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/masked.frag": """
            uniform sampler2D g_Texture0; // {"hidden":true}
            uniform sampler2D g_Texture1; // {"mode":"opacitymask","combo":"MASK"}
            void main() {
            #if MASK
                float mask = texSample2D(g_Texture1, vec2(0.5)).r;
            #else
                float mask = 1.0;
            #endif
                gl_FragColor = texSample2D(g_Texture0, vec2(0.5)) * mask;
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "9",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_9_a",
                compositeB: "_rt_imageLayerComposite_9_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "9.0",
                        phase: .material,
                        shader: "genericimage2",
                        source: .image("materials/base.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_9_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    ),
                    WPERenderPass(
                        id: "9.1",
                        phase: .effect(file: "effects/masked/effect.json"),
                        shader: "effects/masked",
                        source: .fbo("_rt_imageLayerComposite_9_a"),
                        target: .scene,
                        textures: [1: .asset("masks/waterwaves_mask")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let effect = try #require(pipeline.layers.first?.passes.last?.shader)
        #expect(effect.fragmentSource.contains("#define MASK 1"))
    }

    @Test("Loads puppet model from render graph layer path")
    func loadsPuppetModelFromRenderGraphLayerPath() throws {
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": makeSingleTrianglePuppetMDL()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "models/layer.json",
                materialPath: "materials/layer.json",
                puppetPath: "models/layer_puppet.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/layer.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let mesh = try #require(pipeline.layers.first?.puppetModel?.meshes.first)

        #expect(mesh.vertices.count == 3)
        #expect(mesh.indices == [0, 1, 2])
        #expect(mesh.parts == [WPEPuppetMeshPart(id: 7, start: 0, count: 3)])
    }

    @Test(
        "A pre-v19 puppet loads: assembly comes from the data, not the generation number",
        arguments: [13, 17]
    )
    func legacyPuppetGenerationLoadsInsteadOfRefusing(version: Int) throws {
        var mdl = makeLegacyPuppetMDLBelow19()
        mdl.replaceSubrange(0 ..< 8, with: String(format: "MDLV%04d", version).utf8)
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": mdl,
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [puppetLayer()])
        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let model = try #require(pipeline.layers.first?.puppetModel)
        #expect(model.version == version)
    }

    @Test("An MDLV0019 character-sheet puppet loads (it is assembled by skinning, not refused)")
    func mdlv19PuppetLoadsInsteadOfRefusing() throws {
        var mdl = makeSingleTrianglePuppetMDL()
        mdl.replaceSubrange(0..<8, with: "MDLV0019".utf8)
        let fixture = try makeFixture(dataFiles: [
            "models/layer_puppet.mdl": mdl
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [puppetLayer()])
        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let model = try #require(pipeline.layers.first?.puppetModel)
        #expect(model.version == 19)
    }

    private func puppetLayer() -> WPERenderLayer {
        WPERenderLayer(
            objectID: "7",
            objectName: "Layer",
            imagePath: "models/layer.json",
            materialPath: "materials/layer.json",
            puppetPath: "models/layer_puppet.mdl",
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_7_a",
            compositeB: "_rt_imageLayerComposite_7_b",
            localFBOs: [],
            passes: [
                WPERenderPass(
                    id: "7.0",
                    phase: .material,
                    shader: "generic4",
                    source: .image("materials/layer.png"),
                    target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: [:],
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )
            ]
        )
    }

    @Test("MDLV16 direct scene model loads as static mesh instead of legacy puppet")
    func mdlv16DirectSceneModelLoadsAsStaticMesh() throws {
        let fixture = try makeFixture(dataFiles: [
            "models/ring.mdl": makeSingleTriangleMDLV16SceneModel()
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "ring",
                objectName: "Ring",
                imagePath: "models/ring.mdl",
                materialPath: "materials/ring.json",
                puppetPath: "models/ring.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_ring_a",
                compositeB: "_rt_imageLayerComposite_ring_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "ring.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("models/ring.mdl"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "enabled",
                        depthWrite: "enabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let model = try #require(pipeline.layers.first?.puppetModel)

        #expect(model.version == 16)
        #expect(model.meshes.first?.materialPath == "materials/models/Hollow Cylinder/diffuse_0.json")
    }

    @Test("Loads puppet model through dependency mounts")
    func loadsPuppetModelThroughDependencyMounts() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let dependencyRoot = fixture.root.appendingPathComponent("dependency-123", isDirectory: true)
        let modelURL = dependencyRoot.appendingPathComponent("models/layer_puppet.mdl")
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeSingleTrianglePuppetMDL().write(to: modelURL)

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "models/layer.json",
                materialPath: "materials/layer.json",
                puppetPath: "../123/models/layer_puppet.mdl",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/layer.png"),
                        target: .layerComposite(name: "_rt_imageLayerComposite_7_a"),
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(
            cacheRootURL: fixture.root,
            dependencyMounts: [WPEAssetMount(workshopID: "123", rootURL: dependencyRoot)]
        ).build(graph: graph)
        let mesh = try #require(pipeline.layers.first?.puppetModel?.meshes.first)

        #expect(mesh.vertices.count == 3)
        #expect(mesh.indices == [0, 1, 2])
    }

    @Test("Shader annotation numeric defaults stay numeric")
    func shaderAnnotationNumericDefaultsStayNumeric() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/custom.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/custom.frag": """
            uniform sampler2D g_Texture0;
            uniform float u_alpha; // {"material":"Opacity","default":1,"range":[0,1]}
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)) * u_alpha; }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "7",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: "materials/base.json",
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_7_a",
                compositeB: "_rt_imageLayerComposite_7_b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "7.0",
                        phase: .effect(file: "effects/custom/effect.json"),
                        shader: "effects/custom",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let alpha = try #require(pipeline.layers.first?.passes.first?.uniformValues["u_alpha"])

        #expect(alpha.numberValue == 1)
    }

    @Test("WPE shader prelude defines M_PI_2 as full turn")
    func shaderPreludeDefinesMPI2AsFullTurn() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/shake.frag": """
            #include "common.h"
            uniform float g_Time;
            void main() {
                float offset = sin(frac(g_Time / M_PI_2) * M_PI_2);
                gl_FragColor = vec4(offset);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shake/effect.json"),
                        shader: "effects/shake",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragment = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragment.contains("#define M_PI_2 6.28318530717958647692"))
    }

    @Test("Missing shader source is reported with the pass shader name")
    func missingShaderSourceReportsName() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let pass = WPERenderPass(
            id: "1.0",
            phase: .effect(file: "effects/missing/effect.json"),
            shader: "effects/missing",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [pass]
            )
        ])

        #expect(throws: WPERenderPipelineError.self) {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        }
    }

    @Test("Expands WPE composite helper include used by blur combine shaders")
    func expandsCompositeHelperInclude() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/blur_combine.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/blur_combine.frag": """
            // [COMBO] {"combo":"COMPOSITE","default":0}
            #include "common_composite.h"
            uniform sampler2D g_Texture0;
            uniform vec4 g_Texture0Resolution;
            void main() {
                vec2 uv = ApplyCompositeOffset(vec2(0.5), g_Texture0Resolution.xy);
                gl_FragColor = ApplyComposite(vec4(0.0), texSample2D(g_Texture0, uv));
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur/effect.json"),
                        shader: "effects/blur_combine",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragmentSource.contains("wpe_common_composite_included"))
        #expect(fragmentSource.contains("vec2 ApplyCompositeOffset"))
        #expect(fragmentSource.contains("vec4 ApplyComposite"))
        #expect(fragmentSource.contains("#include") == false)
    }

    @Test("common_blur.h provides radial blur helpers used by blur_radial_gaussian")
    func commonBlurProvidesRadialBlurHelpers() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/blur_radial_gaussian.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/blur_radial_gaussian.frag": """
            // [COMBO] {"combo":"KERNEL","default":0}
            #include "common_blur.h"
            varying vec2 v_TexCoord;
            uniform sampler2D g_Texture0;
            uniform float u_Scale;
            uniform vec2 u_Center;
            void main() {
            #if KERNEL == 0
                vec4 albedo = blurRadial13a(v_TexCoord.xy, u_Center, u_Scale);
            #endif
                gl_FragColor = albedo;
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur_radial/effect.json"),
                        shader: "effects/blur_radial_gaussian",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: shader.name,
            preprocessedSource: shader.fragmentSource,
            comboValues: pass.comboValues
        )

        #expect(result.mslSource.contains("blurRadial13a"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test("Staged official headers take precedence over builtin fallbacks")
    func stagedOfficialHeadersPrecedeBuiltinFallbacks() throws {
        let fixture = try makeFixture(files: [
            "shaders/common_vertex.h": "#define OFFICIAL_COMMON_VERTEX 1",
            "shaders/common_perspective.h": "#define OFFICIAL_COMMON_PERSPECTIVE 1",
            "shaders/common_blur.h": "#define OFFICIAL_COMMON_BLUR 1",
            "shaders/common_fragment.h": "#define OFFICIAL_COMMON_FRAGMENT 1",
            "shaders/common_blending.h": "#define OFFICIAL_COMMON_BLENDING 1",
            "shaders/effects/header_probe.vert": """
            #include "common_vertex.h"
            #include "common_perspective.h"
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/header_probe.frag": """
            #include "common_blur.h"
            #include "common_fragment.h"
            #include "common_blending.h"
            void main() { gl_FragColor = vec4(1.0); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [WPERenderPass(
                    id: "1.0",
                    phase: .effect(file: "effects/header_probe/effect.json"),
                    shader: "effects/header_probe",
                    source: .image("materials/base.png"),
                    target: .scene,
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: [:],
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)
        #expect(shader.vertexSource.contains("OFFICIAL_COMMON_VERTEX"))
        #expect(shader.vertexSource.contains("OFFICIAL_COMMON_PERSPECTIVE"))
        #expect(shader.fragmentSource.contains("OFFICIAL_COMMON_BLUR"))
        #expect(shader.fragmentSource.contains("OFFICIAL_COMMON_FRAGMENT"))
        #expect(shader.fragmentSource.contains("OFFICIAL_COMMON_BLENDING"))
        #expect(!shader.vertexSource.contains("wpe_common_vertex_included"))
        #expect(!shader.vertexSource.contains("wpe_common_perspective_included"))
        #expect(!shader.fragmentSource.contains("wpe_common_blur_included"))
        #expect(!shader.fragmentSource.contains("wpe_common_fragment_included"))
        #expect(!shader.fragmentSource.contains("wpe_common_blending_included"))
    }

    @Test("Builtin composite resolves the canonical compile-time blending ABI")
    func builtinCompositeUsesResolvedBlendingHeader() throws {
        let fixture = try makeFixture(files: [
            "shaders/common_blending.h": """
            #define OFFICIAL_BLEND_ABI 1
            vec3 ApplyBlending(const int ignoredMode, in vec3 base, in vec3 blend, in float opacity) {
            #if BLENDMODE == 31
                return base + blend * opacity;
            #else
                return mix(base, blend, opacity);
            #endif
            }
            """,
            "shaders/effects/composite_probe.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/composite_probe.frag": """
            // [COMBO] {"combo":"COMPOSITE","default":1}
            // [COMBO] {"combo":"BLENDMODE","default":31}
            #include "common_composite.h"
            void main() { gl_FragColor = ApplyComposite(vec4(0.1), vec4(0.2)); }
            """,
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [WPERenderLayer(
            objectID: "1", objectName: "Layer", imagePath: "materials/base.png",
            materialPath: nil, geometry: .identity, compositeA: "a", compositeB: "b",
            localFBOs: [], passes: [WPERenderPass(
                id: "1.0", phase: .effect(file: "effects/composite_probe/effect.json"),
                shader: "effects/composite_probe", source: .image("materials/base.png"),
                target: .scene, textures: [:], binds: [:], constants: [:], combos: [:],
                blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
            )]
        )])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)
        #expect(shader.fragmentSource.contains("OFFICIAL_BLEND_ABI"))
        #expect(!shader.fragmentSource.contains("wpe_common_blending_included"))
        #expect(shader.fragmentSource.contains("#include") == false)

        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: shader.name,
            preprocessedSource: shader.fragmentSource,
            comboValues: pass.comboValues
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: options)
    }

    @Test("Resolved headers expand once per shader stage even without include guards")
    func resolvedHeadersAreIncludeOnce() throws {
        let fixture = try makeFixture(files: [
            "shaders/common_blur.h": "float official_once_marker = 1.0;",
            "shaders/effects/nested.h": "#include \"common_blur.h\"",
            "shaders/effects/include_once.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/include_once.frag": """
            #include "nested.h"
            #include "common_blur.h"
            void main() { gl_FragColor = vec4(official_once_marker); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [WPERenderPass(
                    id: "1.0",
                    phase: .effect(file: "effects/include_once/effect.json"),
                    shader: "effects/include_once",
                    source: .image("materials/base.png"),
                    target: .scene,
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: [:],
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let effective = try effectiveFragmentSource(of: pass)
        #expect(occurrences(of: "official_once_marker = 1.0", in: effective) == 1)
        #expect(!effective.contains("#include"))
        try compileFragment(of: pass)
    }

    @Test("An include inside a dead `#if 0` branch does not consume the once-only slot of a later live include")
    func includeInsideDeadBranchDoesNotConsumeIncludeOnce() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/once_h.h": "float once_h_marker(float x) { return x * 2.0; }",
            "shaders/effects/dead_include.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/dead_include.frag": """
            #if 0
            #include "once_h.h"
            #endif
            #include "once_h.h"
            void main() { gl_FragColor = vec4(once_h_marker(0.5)); }
            """,
        ])
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: includeProbeGraph(shader: "effects/dead_include"))
        let pass = try #require(pipeline.layers.first?.passes.first)
        let effective = try effectiveFragmentSource(of: pass)
        #expect(occurrences(of: "float once_h_marker(float x)", in: effective) == 1)
        try compileFragment(of: pass)
    }

    @Test("Nested includes reached through a dead branch still expand exactly once each")
    func nestedIncludeThroughDeadBranchKeepsOneCopyEach() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/once_g.h": "float once_g_marker(float x) { return x + 1.0; }",
            "shaders/effects/once_h.h": """
            #include "once_g.h"
            float once_h_marker(float x) { return once_g_marker(x) * 2.0; }
            """,
            "shaders/effects/nested_dead.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/nested_dead.frag": """
            #if 0
            #include "once_h.h"
            #endif
            #include "once_h.h"
            #include "once_g.h"
            void main() { gl_FragColor = vec4(once_h_marker(0.5)); }
            """,
        ])
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: includeProbeGraph(shader: "effects/nested_dead"))
        let pass = try #require(pipeline.layers.first?.passes.first)
        let effective = try effectiveFragmentSource(of: pass)
        #expect(occurrences(of: "float once_g_marker(float x)", in: effective) == 1)
        #expect(occurrences(of: "float once_h_marker(float x)", in: effective) == 1)
        try compileFragment(of: pass)
    }

    @Test("A combo-gated include takes effect only in the branch the combo selects", arguments: [0, 1])
    func comboGatedIncludeFollowsComboValue(comboValue: Int) throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/once_h.h": "float once_h_marker(float x) { return x * 2.0; }",
            "shaders/effects/once_k.h": "float once_k_marker(float x) { return x + 1.0; }",
            "shaders/effects/combo_include.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/combo_include.frag": """
            // [COMBO] {"combo":"PROBEINCLUDE","default":0}
            #if PROBEINCLUDE
            #include "once_h.h"
            #else
            #include "once_k.h"
            #endif
            #include "once_k.h"
            void main() {
                gl_FragColor = vec4(once_k_marker(0.5));
            #if PROBEINCLUDE
                gl_FragColor += vec4(once_h_marker(0.5));
            #endif
            }
            """,
        ])
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: includeProbeGraph(shader: "effects/combo_include", combos: ["PROBEINCLUDE": comboValue]))
        let pass = try #require(pipeline.layers.first?.passes.first)
        let effective = try effectiveFragmentSource(of: pass)
        #expect(occurrences(of: "float once_k_marker(float x)", in: effective) == 1)
        #expect(occurrences(of: "float once_h_marker(float x)", in: effective) == comboValue)
        try compileFragment(of: pass)
    }

    @Test("`#ifdef`/`#undef` gate includes by the macro state at that point of the source")
    func ifdefAndUndefGateIncludes() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/once_h.h": "float once_h_marker(float x) { return x * 2.0; }",
            "shaders/effects/once_k.h": "float once_k_marker(float x) { return x + 1.0; }",
            "shaders/effects/ifdef_include.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/ifdef_include.frag": """
            #ifdef NEVER_DEFINED_PROBE
            #include "once_h.h"
            #endif
            #define WANT_ONCE_H
            #ifdef WANT_ONCE_H
            #include "once_h.h"
            #endif
            #undef WANT_ONCE_H
            #ifdef WANT_ONCE_H
            #include "once_k.h"
            #endif
            #ifndef WANT_ONCE_H
            #include "once_h.h"
            #endif
            void main() { gl_FragColor = vec4(once_h_marker(0.5)); }
            """,
        ])
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: includeProbeGraph(shader: "effects/ifdef_include"))
        let pass = try #require(pipeline.layers.first?.passes.first)
        let effective = try effectiveFragmentSource(of: pass)
        #expect(occurrences(of: "float once_h_marker(float x)", in: effective) == 1)
        #expect(occurrences(of: "float once_k_marker(float x)", in: effective) == 0)
        try compileFragment(of: pass)
    }

    @Test("An unguarded official header and a builtin header both compile when included twice")
    func repeatedUnguardedOfficialAndBuiltinHeadersCompile() throws {
        // Modelled on the official `common_blending.h`, which ships without an include guard.
        let fixture = try makeFixture(files: [
            "shaders/common_blending.h": """
            vec3 BlendLinearDodge(vec3 base, vec3 blend) { return base + blend; }
            vec3 BlendOpacityProbe(vec3 base, vec3 blend, float opacity) { return mix(base, BlendLinearDodge(base, blend), opacity); }
            """,
            "shaders/effects/twice.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/twice.frag": """
            #include "common_blending.h"
            #include "common_composite.h"
            #include "common_blending.h"
            #include "common_composite.h"
            void main() { gl_FragColor = vec4(BlendOpacityProbe(vec3(0.1), vec3(0.2), 0.5), 1.0); }
            """,
        ])
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: includeProbeGraph(shader: "effects/twice"))
        let pass = try #require(pipeline.layers.first?.passes.first)
        let effective = try effectiveFragmentSource(of: pass)
        #expect(occurrences(of: "vec3 BlendLinearDodge(vec3 base, vec3 blend)", in: effective) == 1)
        #expect(occurrences(of: "wpe_common_composite_included", in: effective) == 1)
        try compileFragment(of: pass)
    }

    @Test("A real include cycle still throws includeCycle; a missing header still throws includeMissing")
    func includeCycleAndMissingHeaderStillThrow() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/cycle_a.h": "#include \"cycle_b.h\"",
            "shaders/effects/cycle_b.h": "#include \"cycle_a.h\"",
            "shaders/effects/self.h": "#include \"self.h\"",
            "shaders/effects/cycle.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/cycle.frag": "#include \"cycle_a.h\"\nvoid main() { gl_FragColor = vec4(1.0); }",
            "shaders/effects/selfcycle.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/selfcycle.frag": "#include \"self.h\"\nvoid main() { gl_FragColor = vec4(1.0); }",
            "shaders/effects/missing.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/missing.frag": "#include \"nope.h\"\nvoid main() { gl_FragColor = vec4(1.0); }",
        ])
        defer { fixture.cleanup() }
        let builder = WPERenderPipelineBuilder(cacheRootURL: fixture.root)

        #expect(throws: WPERenderPipelineError.includeCycle(path: "cycle_a.h")) {
            try builder.build(graph: includeProbeGraph(shader: "effects/cycle"))
        }
        #expect(throws: WPERenderPipelineError.includeCycle(path: "self.h")) {
            try builder.build(graph: includeProbeGraph(shader: "effects/selfcycle"))
        }
        #expect(throws: WPERenderPipelineError.includeMissing(path: "nope.h", requestedBy: "shaders/effects/missing.frag")) {
            try builder.build(graph: includeProbeGraph(shader: "effects/missing"))
        }
    }

    @Test("A commented-out `#include` line is not expanded")
    func commentedIncludeLineIsIgnored() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/once_h.h": "float once_h_marker(float x) { return x * 2.0; }",
            "shaders/effects/commented.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/commented.frag": """
            // #include "nope.h"
            /* #include "nope.h" */
            #include "once_h.h" // trailing comment
            void main() { gl_FragColor = vec4(once_h_marker(0.5)); }
            """,
        ])
        defer { fixture.cleanup() }

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root)
            .build(graph: includeProbeGraph(shader: "effects/commented"))
        let pass = try #require(pipeline.layers.first?.passes.first)
        let effective = try effectiveFragmentSource(of: pass)
        #expect(occurrences(of: "float once_h_marker(float x)", in: effective) == 1)
        try compileFragment(of: pass)
    }

    private func includeProbeGraph(shader: String, combos: [String: Int] = [:]) -> WPERenderGraph {
        WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [WPERenderPass(
                    id: "1.0",
                    phase: .effect(file: "\(shader)/effect.json"),
                    shader: shader,
                    source: .image("materials/base.png"),
                    target: .scene,
                    textures: [:],
                    binds: [:],
                    constants: [:],
                    combos: combos,
                    blending: "normal",
                    cullMode: "nocull",
                    depthTest: "disabled",
                    depthWrite: "disabled"
                )]
            ),
        ])
    }

    /// The fragment source after the same branch stripping the transpiler applies; raw expansion text is not what compiles.
    private func effectiveFragmentSource(of pass: WPEPreparedRenderPass) throws -> String {
        let source = try #require(pass.shader?.fragmentSource)
        return WPEShaderTranspiler.stripInactivePreprocessorBranches(in: source)
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func compileFragment(of pass: WPEPreparedRenderPass) throws {
        let shader = try #require(pass.shader)
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: shader.name,
            preprocessedSource: shader.fragmentSource,
            comboValues: pass.comboValues
        )
        let device = try #require(MTLCreateSystemDefaultDevice())
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        _ = try device.makeLibrary(source: result.mslSource, options: options)
    }

    @Test("Expands common_fragment.h ConvertSampleR8 used by WPE 2.8 font.frag")
    func expandsCommonFragmentConvertSampleR8() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/font_like.vert": """
            void main() { gl_Position = vec4(0.0); }
            """,
            "shaders/effects/font_like.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture0;
            uniform vec4 g_Color4;
            void main() {
                float a = ConvertSampleR8(texSample2D(g_Texture0, vec2(0.5)));
                gl_FragColor = vec4(g_Color4.rgb, a * g_Color4.a);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/font/effect.json"),
                        shader: "effects/font_like",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)

        #expect(fragmentSource.contains("wpe_common_fragment_included"))
        #expect(fragmentSource.contains("float ConvertSampleR8"))
        #expect(fragmentSource.contains("#include") == false)
    }

    @Test("common_fragment.h FORMAT_* constants keep formatcombo branches off the R8 path")
    func commonFragmentFormatConstantsKeepFormatcomboBranchesOffR8() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shafts_like.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shafts_like.frag": """
            #include "common_fragment.h"
            uniform sampler2D g_Texture2; // {"default":"gradient/gradient_iridescent","formatcombo":true}
            void main() {
            #if TEX2FORMAT == FORMAT_R8 || TEX2FORMAT == FORMAT_RG88
                vec3 gradColor = texSample2D(g_Texture2, vec2(0.5)).rrr;
            #else
                vec3 gradColor = texSample2D(g_Texture2, vec2(0.5)).rgb;
            #endif
                gl_FragColor = vec4(gradColor, 1.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shafts/effect.json"),
                        shader: "effects/shafts_like",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let fragmentSource = try #require(pass.shader?.fragmentSource)

        #expect(fragmentSource.contains("#define FORMAT_R8 9"))
        #expect(fragmentSource.contains("#define FORMAT_RG88 8"))
        #expect(fragmentSource.contains("#define FORMAT_R8 0") == false)
        #expect(fragmentSource.contains("#define FORMAT_RG88 0") == false)
        #expect(fragmentSource.contains("#define TEX2FORMAT 0"))
        #expect(pass.textureBindings[2] == WPETextureReference.asset("gradient/gradient_iridescent"))
    }

    @Test("Treats generic image shader variants as builtins")
    func treatsGenericImageShaderVariantsAsBuiltins() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "generic4",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.name == "generic4")
        #expect(shader.isBuiltin)
    }

    @Test("Dynamic transform on a non-rendered parent propagates to child geometry")
    func dynamicParentTransformPropagatesToChildGeometry() {
        let childGeometry = WPERenderLayerGeometry(
            origin: SIMD3<Double>(10, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            alignment: .center,
            size: CGSize(width: 10, height: 10),
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1
        )
        let graphLayer = WPERenderLayer(
            objectID: "child",
            objectName: "Child",
            imagePath: "materials/base.png",
            materialPath: nil,
            parentObjectID: "group",
            geometry: childGeometry,
            localGeometry: childGeometry,
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: graphLayer, passes: [])
        ])

        let transformed = pipeline.applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(0, 0, Double.pi / 2)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(0, 0, 0),
                    scale: SIMD3<Double>(1, 1, 1),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        )
        let geometry = transformed.layers[0].graphLayer.geometry

        #expect(abs(geometry.origin.x) < 0.0001)
        #expect(abs(geometry.origin.y - 10) < 0.0001)
        #expect(abs(geometry.angles.z - Double.pi / 2) < 0.0001)
    }

    @Test("Dynamic parent transform rotates child origin around X and Y")
    func dynamicParentTransformRotatesChildOriginAroundXAndY() {
        func makePipeline(childOrigin: SIMD3<Double>) -> WPEPreparedRenderPipeline {
            let childGeometry = WPERenderLayerGeometry(
                origin: childOrigin,
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 10, height: 10),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
            let graphLayer = WPERenderLayer(
                objectID: "child",
                objectName: "Child",
                imagePath: "materials/base.png",
                materialPath: nil,
                parentObjectID: "group",
                geometry: childGeometry,
                localGeometry: childGeometry,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: []
            )
            return WPEPreparedRenderPipeline(layers: [
                WPEPreparedRenderLayer(graphLayer: graphLayer, passes: [])
            ])
        }

        let xRotated = makePipeline(childOrigin: SIMD3<Double>(0, 1, 0)).applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(Double.pi / 2, 0, 0)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(1, 2, 3),
                    scale: SIMD3<Double>(2, 3, 4),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        ).layers[0].graphLayer.geometry

        #expect(abs(xRotated.origin.x - 1) < 0.0001)
        #expect(abs(xRotated.origin.y - 2) < 0.0001)
        #expect(abs(xRotated.origin.z - 6) < 0.0001)
        #expect(abs(xRotated.angles.x - Double.pi / 2) < 0.0001)

        let yRotated = makePipeline(childOrigin: SIMD3<Double>(0, 0, 1)).applyingLayerTransforms(
            origins: [:],
            scales: [:],
            angles: ["group": SIMD3<Double>(0, Double.pi / 2, 0)],
            parentByID: ["child": "group"],
            hostTransforms: [
                "group": WPERenderObjectTransform(
                    origin: SIMD3<Double>(1, 2, 3),
                    scale: SIMD3<Double>(2, 3, 4),
                    angles: SIMD3<Double>(0, 0, 0)
                )
            ]
        ).layers[0].graphLayer.geometry

        #expect(abs(yRotated.origin.x - 5) < 0.0001)
        #expect(abs(yRotated.origin.y - 2) < 0.0001)
        #expect(abs(yRotated.origin.z - 3) < 0.0001)
        #expect(abs(yRotated.angles.y - Double.pi / 2) < 0.0001)
    }

    @Test("Live alpha override also updates a composelayer-group child's group-local alpha")
    func liveAlphaOverrideUpdatesGroupLocalGeometry() {
        func geometry(alpha: Double) -> WPERenderLayerGeometry {
            WPERenderLayerGeometry(
                origin: SIMD3<Double>(5, 7, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0),
                alignment: .center,
                size: CGSize(width: 40, height: 30),
                alpha: alpha,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            )
        }
        let child = WPERenderLayer(
            objectID: "child",
            objectName: "Child",
            imagePath: "materials/base.png",
            materialPath: nil,
            parentObjectID: "group",
            geometry: geometry(alpha: 1),
            localGeometry: geometry(alpha: 1),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: [],
            groupRenderTarget: "_rt_layerGroup_group",
            groupLocalGeometry: geometry(alpha: 1)
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(graphLayer: child, passes: [])
        ])

        let faded = pipeline.applyingFrameOverlay(WPEFrameOverlay(alpha: ["child": 0.25])).layers[0].graphLayer
        #expect(abs(faded.geometry.alpha - 0.25) < 0.0001)
        #expect(abs((faded.groupLocalGeometry?.alpha ?? -1) - 0.25) < 0.0001)
        #expect(faded.groupLocalGeometry?.alphaAnimation == nil)
        #expect(faded.groupLocalGeometry?.origin == SIMD3<Double>(5, 7, 0))
    }

    @Test("Prefers scene-provided source for WPE effect aliases")
    func prefersSceneProvidedSourceForWPEEffectAliases() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shake.frag": """
            uniform sampler2D g_Texture0;
            void main() {
                vec4 sampled = texSample2D(g_Texture0, vec2(0.5));
                gl_FragColor = sampled + vec4(0.123, 0.0, 0.0, 0.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/shake/effect.json"),
                        shader: "effects/shake",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.isBuiltin == false)
        #expect(shader.executionClassification == .officialSource)
        #expect(shader.fragmentSource.contains("0.123"))
    }

    @Test("Expands WPE imageblending mode 31 as additive blending")
    func expandsWPEImageBlendingMode31AsAdditiveBlending() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/lightblend.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/lightblend.frag": """
            // [COMBO] {"material":"ui_editor_properties_blend_mode","combo":"BLENDMODE","type":"imageblending","default":31}
            #include "common_blending.h"
            uniform sampler2D g_Texture0;
            void main() {
                vec4 albedo = texSample2D(g_Texture0, vec2(0.5));
                gl_FragColor = vec4(ApplyBlending(BLENDMODE, albedo.rgb, vec3(0.25), 1.0), albedo.a);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/lightblend/effect.json"),
                        shader: "effects/lightblend",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)
        let shader = try #require(pass.shader)

        #expect(pass.comboValues["BLENDMODE"] == 31)
        #expect(shader.fragmentSource.contains("#define BLENDMODE 31"))
        #expect(shader.fragmentSource.contains("blendMode == 31"))
        #expect(shader.fragmentSource.contains("vec3 ApplyBlending(int blendMode, vec3 A, vec3 B, vec3 opacity)"))
        #expect(shader.fragmentSource.contains("#include") == false)
    }

    @Test("Builds built-in solid color shader")
    func buildsBuiltinSolidColorShader() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Solid",
                imagePath: "models/util/solidlayer.json",
                materialPath: "models/util/solidlayer.json",
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .material,
                        shader: "solidcolor",
                        source: .image("models/util/solidlayer.json"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: ["g_Color": .vector([1, 0, 0, 1])],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.name == "solidcolor")
        #expect(shader.isBuiltin)
        #expect(shader.fragmentSource.contains("uniform vec4 g_Color"))
    }

    @Test("Builds executable copy command passes")
    func buildsExecutableCopyCommandPasses() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .command(file: "effects/copy/effect.json"),
                        shader: "commands/copy",
                        source: .fbo("_rt_Previous"),
                        target: .fbo(name: "_rt_Target"),
                        textures: [0: .fbo("_rt_Source")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)

        #expect(pass.shader?.name == "commands/copy")
        #expect(pass.shader?.isBuiltin == true)
        #expect(pass.shader?.executionClassification == .nativeApproximation)
        #expect(pass.textureBindings[0] == .fbo("_rt_Source"))
    }

    @Test("Merges shader annotation defaults into prepared pass metadata")
    func mergesShaderAnnotationDefaultsIntoPreparedPassMetadata() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/annotated.vert": """
            // [COMBO] {"combo":"QUALITY","default":2}
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/annotated.frag": """
            uniform sampler2D g_Texture1; // {"material":"noise","default":"util/noise","hidden":true}
            uniform sampler2D g_Texture2; // {"material":"flow","combo":"FLOWMASK"}
            uniform float u_Strength; // {"material":"strength","default":0.2}
            void main() { gl_FragColor = texSample2D(g_Texture1, vec2(u_Strength)); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/annotated/effect.json"),
                        shader: "effects/annotated",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [2: .asset("masks/flow")],
                        binds: [:],
                        constants: ["strength": .number(0.75)],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let pass = try #require(pipeline.layers.first?.passes.first)

        #expect(pass.comboValues["QUALITY"] == 2)
        #expect(pass.comboValues["FLOWMASK"] == 1)
        #expect(pass.textureBindings[0] == .image("materials/base.png"))
        #expect(pass.textureBindings[1] == .asset("util/noise"))
        #expect(pass.textureBindings[2] == .asset("masks/flow"))
        #expect(pass.uniformValues["u_Strength"]?.numberValue == 0.75)
    }

    @Test("Legacy generic2 reflection default binds only when REFLECTION is enabled")
    func legacyGeneric2ReflectionDefaultFollowsCombo() throws {
        let fixture = try makeFixture(files: [
            "shaders/generic2.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/generic2.frag": """
            uniform sampler2D g_Texture0; // {"default":"util/white"}
            uniform sampler2D g_Texture2; // {"default":"_rt_Reflection","hidden":true}
            void main() {
            #if REFLECTION
                gl_FragColor = texSample2D(g_Texture2, vec2(0.5));
            #else
                gl_FragColor = texSample2D(g_Texture0, vec2(0.5));
            #endif
            }
            """
        ])
        defer { fixture.cleanup() }

        func preparedPass(reflection: Int?) throws -> WPEPreparedRenderPass {
            let combos = reflection.map { ["REFLECTION": $0] } ?? [:]
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "3470948192",
                    objectName: "generic2",
                    imagePath: "util/white",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "3470948192.0",
                            phase: .material,
                            shader: "generic2",
                            source: .asset("util/white"),
                            target: .scene,
                            textures: [:],
                            binds: [:],
                            constants: [:],
                            combos: combos,
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "enabled",
                            depthWrite: "enabled"
                        )
                    ]
                )
            ])
            return try #require(
                WPERenderPipelineBuilder(cacheRootURL: fixture.root)
                    .build(graph: graph)
                    .layers.first?.passes.first
            )
        }

        let implicitOff = try preparedPass(reflection: nil)
        let explicitOff = try preparedPass(reflection: 0)
        let enabled = try preparedPass(reflection: 1)

        #expect(implicitOff.textureBindings[2] == nil)
        #expect(explicitOff.textureBindings[2] == nil)
        #expect(enabled.textureBindings[2] == .fbo("_rt_Reflection"))
    }

    @Test("shake/pulse opacity mask slot 2 defaults to white unless explicitly bound")
    func effectOpacityMaskSlot2DefaultsToWhite() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/shake.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/shake.frag": """
            uniform sampler2D g_Texture0;
            uniform sampler2D g_Texture2; // {"default":"util/black"}
            void main() { gl_FragColor = texSample2D(g_Texture0, vec2(0.5)); }
            """
        ])
        defer { fixture.cleanup() }

        func builtPass(textures: [Int: WPETextureReference]) throws -> WPEPreparedRenderPass {
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "161",
                    objectName: "Layer",
                    imagePath: "materials/base.png",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "161.1",
                            phase: .effect(file: "effects/shake/effect.json"),
                            shader: "effects/shake",
                            source: .image("materials/base.png"),
                            target: .scene,
                            textures: textures,
                            binds: [:],
                            constants: [:],
                            combos: [:],
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
            let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
            return try #require(pipeline.layers.first?.passes.first)
        }

        let defaulted = try builtPass(textures: [:])
        #expect(defaulted.textureBindings[2] == .asset("util/white"))

        let explicit = try builtPass(textures: [2: .asset("masks/pulse__mask_9913c181")])
        #expect(explicit.textureBindings[2] == .asset("masks/pulse__mask_9913c181"))
    }

    @Test("Sampler defaults honor shader require conditions")
    func samplerDefaultsHonorShaderRequireConditions() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/conditional.vert": """
            attribute vec3 a_Position;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/conditional.frag": """
            // [COMBO] {"combo":"RENDERING","default":0}
            uniform sampler2D g_Texture1; // {"default":"gradient/gradient_iridescent","require":{"RENDERING":1}}
            void main() { gl_FragColor = vec4(1.0); }
            """
        ])
        defer { fixture.cleanup() }

        func buildPass(combos: [String: Int]) throws -> WPEPreparedRenderPass {
            let graph = WPERenderGraph(layers: [
                WPERenderLayer(
                    objectID: "1",
                    objectName: "Layer",
                    imagePath: "materials/base.png",
                    materialPath: nil,
                    geometry: .identity,
                    compositeA: "a",
                    compositeB: "b",
                    localFBOs: [],
                    passes: [
                        WPERenderPass(
                            id: "1.0",
                            phase: .effect(file: "effects/conditional/effect.json"),
                            shader: "effects/conditional",
                            source: .image("materials/base.png"),
                            target: .scene,
                            textures: [:],
                            binds: [:],
                            constants: [:],
                            combos: combos,
                            blending: "normal",
                            cullMode: "nocull",
                            depthTest: "disabled",
                            depthWrite: "disabled"
                        )
                    ]
                )
            ])
            let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
            return try #require(pipeline.layers.first?.passes.first)
        }

        let inactivePass = try buildPass(combos: [:])
        #expect(inactivePass.comboValues["RENDERING"] == 0)
        #expect(inactivePass.textureBindings[1] == nil)

        let activePass = try buildPass(combos: ["RENDERING": 1])
        #expect(activePass.comboValues["RENDERING"] == 1)
        #expect(activePass.textureBindings[1] == WPETextureReference.asset("gradient/gradient_iridescent"))
    }

    @Test("Comments require directives and emits WPE compatibility prelude")
    func commentsRequireDirectivesAndEmitsCompatibilityPrelude() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/compat.vert": """
            #require SOME_FEATURE
            attribute vec3 a_Position;
            varying vec2 v_TexCoord;
            void main() { gl_Position = vec4(a_Position, 1.0); }
            """,
            "shaders/effects/compat.frag": """
            varying vec2 v_TexCoord;
            void main() { gl_FragColor = lerp(vec4(0.0), vec4(1.0), 0.5); }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/compat/effect.json"),
                        shader: "effects/compat",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.vertexSource.contains("#require") == false)
        #expect(shader.vertexSource.contains("#define attribute in"))
        #expect(shader.fragmentSource.contains("out vec4 out_FragColor"))
        #expect(shader.fragmentSource.contains("gl_FragColor") == false)
        #expect(shader.fragmentSource.contains("#define texSample2DLod textureLod"))
        #expect(shader.fragmentSource.contains("#define lerp mix"))
    }

    @Test("Compatibility prelude keeps GLSL atan2 compiling through Metal")
    func compatibilityPreludeAtan2CompilesThroughMetal() throws {
        let fixture = try makeFixture(files: [
            "shaders/effects/atan.vert": """
            attribute vec3 a_Position;
            varying vec2 v_TexCoord;
            void main() {
                gl_Position = vec4(a_Position, 1.0);
                v_TexCoord = a_Position.xy;
            }
            """,
            "shaders/effects/atan.frag": """
            varying vec2 v_TexCoord;
            void main() {
                float angle = atan2(v_TexCoord.y - 0.5, v_TexCoord.x - 0.5);
                gl_FragColor = vec4(angle, 0.0, 0.0, 1.0);
            }
            """
        ])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/atan/effect.json"),
                        shader: "effects/atan",
                        source: .image("materials/base.png"),
                        target: .scene,
                        textures: [:],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let fragmentSource = try #require(pipeline.layers.first?.passes.first?.shader?.fragmentSource)
        let result = try WPEShaderTranspiler.translateFragment(
            shaderName: "effects/atan",
            preprocessedSource: fragmentSource
        )

        let device = try #require(MTLCreateSystemDefaultDevice())
        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0

        #expect(result.mslSource.contains("atan2(v_TexCoord.y - 0.5, v_TexCoord.x - 0.5)"))
        _ = try device.makeLibrary(source: result.mslSource, options: opts)
    }

    @Test(
        "Recognises effect aliases under bare, effects/, and materials/ paths",
        arguments: [
            "blur",
            "effects/blur",
            "effects/blur/blur",
            "materials/effects/blur/blur",
            "materials/effects/blur/blur.json",
            "MATERIALS/Effects/Blur/Blur.JSON"
        ]
    )
    func recognisesEffectAliasesAcrossPathStyles(shaderName: String) throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "1",
                objectName: "Layer",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [
                    WPERenderPass(
                        id: "1.0",
                        phase: .effect(file: "effects/blur/effect.json"),
                        shader: shaderName,
                        source: .fbo("_rt_Source"),
                        target: .scene,
                        textures: [0: .fbo("_rt_Source")],
                        binds: [:],
                        constants: [:],
                        combos: [:],
                        blending: "normal",
                        cullMode: "nocull",
                        depthTest: "disabled",
                        depthWrite: "disabled"
                    )
                ]
            )
        ])

        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: graph)
        let shader = try #require(pipeline.layers.first?.passes.first?.shader)

        #expect(shader.isBuiltin)
        #expect(shader.name == shaderName)
        #expect(shader.executionClassification == .nativeApproximation)
    }

    @Test("Unmapped effect_ source absence is marked as copy fallback")
    func unmappedEffectSourceAbsenceIsMarkedAsCopyFallback() throws {
        let fixture = try makeFixture(files: [:])
        defer { fixture.cleanup() }

        let pass = WPERenderPass(
            id: "fallback.0",
            phase: .effect(file: "effects/unmapped/effect.json"),
            shader: "effect_unmapped",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [:],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let graph = WPERenderGraph(layers: [
            WPERenderLayer(
                objectID: "fallback",
                objectName: "Fallback",
                imagePath: "materials/base.png",
                materialPath: nil,
                geometry: .identity,
                compositeA: "a",
                compositeB: "b",
                localFBOs: [],
                passes: [pass]
            )
        ])

        let prepared = try #require(
            WPERenderPipelineBuilder(cacheRootURL: fixture.root)
                .build(graph: graph).layers.first?.passes.first?.shader
        )
        #expect(prepared.isBuiltin)
        #expect(prepared.executionClassification == .copyFallback)
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(
        files: [String: String] = [:],
        dataFiles: [String: Data] = [:]
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPERenderPipelineBuilderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (relativePath, contents) in files {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: fileURL)
        }
        for (relativePath, contents) in dataFiles {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: fileURL)
        }
        return Fixture(root: root)
    }

    private func makeHeaderOnlyTex(formatCode: Int32) -> Data {
        var data = Data()
        data.append(contentsOf: "TEXV0005".utf8)
        data.append(0)
        data.append(contentsOf: "TEXI0001".utf8)
        data.append(0)
        data.appendLE(UInt32(bitPattern: formatCode))
        data.appendLE(UInt32(0)) // flags
        data.appendLE(UInt32(4)) // texture width
        data.appendLE(UInt32(4)) // texture height
        data.appendLE(UInt32(4)) // image width
        data.appendLE(UInt32(4)) // image height
        data.appendLE(UInt32(0)) // unknownInt0
        return data
    }

    private func makeSingleTrianglePuppetMDL() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0023".utf8))
        data.appendLE(UInt32(0x80000900))
        data.append(UInt8(1))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/layer.json")
        data.appendLE(UInt32(0))
        data.appendLE(Float(-10))
        data.appendLE(Float(-20))
        data.appendLE(Float(0))
        data.appendLE(Float(10))
        data.appendLE(Float(20))
        data.appendLE(Float(0))
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(-10, -20, 0), SIMD2<Float>(0, 1)),
            (SIMD3<Float>(10, -20, 0), SIMD2<Float>(1, 1)),
            (SIMD3<Float>(0, 20, 0), SIMD2<Float>(0.5, 0))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        data.append(UInt8(0))
        data.append(UInt8(1))
        data.appendLE(UInt32(16))
        data.appendLE(UInt32(7))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(3))

        return data
    }

    private func makeLegacyPuppetMDLBelow19() -> Data {
        // Real MDLV0017 header layout (9-byte NUL-terminated tag + flags + skin count +
        // mesh count), so the version guard — not a parse failure — is what refuses the scene.
        var data = Data()
        data.append(contentsOf: Array("MDLV0017".utf8))
        data.append(UInt8(0))
        data.appendLE(UInt32(0x180000f))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/layer.json")
        data.appendLE(UInt32(0))
        for _ in 0..<6 { data.appendLE(Float(0)) }
        data.appendLE(UInt32(0x180000f))
        let vertexData = Data.puppetVertices([
            (SIMD3<Float>(0, 0, 0), SIMD2<Float>(0.5, 0.5))
        ])
        data.appendLE(UInt32(vertexData.count))
        data.append(vertexData)
        data.appendLE(UInt32(0))

        return data
    }

    private func makeSingleTriangleMDLV16SceneModel() -> Data {
        var data = Data()
        data.append(contentsOf: Array("MDLV0016".utf8))
        data.appendLE(UInt32(0x00000f00))
        data.append(UInt8(0))
        data.appendLE(UInt32(1))
        data.appendLE(UInt32(1))

        data.appendCString("materials/models/Hollow Cylinder/diffuse_0.json")
        data.appendLE(UInt32(0))
        data.appendLE(UInt32(0x0000000f))

        var vertices = Data()
        vertices.appendSceneModelVertex(position: SIMD3<Float>(-1, -1, 0), uv: SIMD2<Float>(0, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(1, -1, 0), uv: SIMD2<Float>(1, 1))
        vertices.appendSceneModelVertex(position: SIMD3<Float>(0, 1, 0), uv: SIMD2<Float>(0.5, 0))
        data.appendLE(UInt32(vertices.count))
        data.append(vertices)

        data.appendLE(UInt32(3 * MemoryLayout<UInt16>.size))
        data.appendLE(UInt16(0))
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(2))

        return data
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: Float) {
        appendLE(value.bitPattern)
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(UInt8(0))
    }

    static func puppetVertices(_ vertices: [(position: SIMD3<Float>, uv: SIMD2<Float>)]) -> Data {
        var data = Data()
        for vertex in vertices {
            data.appendLE(vertex.position.x)
            data.appendLE(vertex.position.y)
            data.appendLE(vertex.position.z)
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(1))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(Float(0))
            data.appendLE(vertex.uv.x)
            data.appendLE(vertex.uv.y)
        }
        return data
    }

    mutating func appendSceneModelVertex(position: SIMD3<Float>, uv: SIMD2<Float>) {
        appendLE(position.x)
        appendLE(position.y)
        appendLE(position.z)
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(Float(1))
        appendLE(Float(0))
        appendLE(Float(0))
        appendLE(Float(1))
        appendLE(uv.x)
        appendLE(uv.y)
    }
}

extension WPERenderPipelineBuilderTests {
    @Test("Include expansion rejects an acyclic exponential DAG with a bounded work error")
    func includeDAGWorkBudget() throws {
        var files = ["shaders/effects/budget0.h": "float budget_leaf(float x) { return x; }"]
        for depth in 1 ... 13 {
            files["shaders/effects/budget\(depth).h"] = "#include \"budget\(depth - 1).h\"\n#include \"budget\(depth - 1).h\""
        }
        files["shaders/effects/budget.vert"] = "void main() { gl_Position = vec4(0.0); }"
        files["shaders/effects/budget.frag"] = "#include \"budget13.h\"\nvoid main() { gl_FragColor = vec4(1.0); }"
        let fixture = try makeFixture(files: files)
        defer { fixture.cleanup() }
        do {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: includeProbeGraph(shader: "effects/budget"))
            Issue.record("Exponential include expansion escaped its work limit")
        } catch let WPERenderPipelineError.sourceExpansionLimit(_, limit) {
            #expect(limit == "include visits (4096)")
        }
    }

    @Test("Include expansion rejects excessive depth before recursive stack growth")
    func includeDepthBudget() throws {
        var files = ["shaders/effects/depth0.h": "float depth_leaf(float x) { return x; }"]
        for depth in 1 ... 70 {
            files["shaders/effects/depth\(depth).h"] = "#include \"depth\(depth - 1).h\""
        }
        files["shaders/effects/depth.vert"] = "void main() { gl_Position = vec4(0.0); }"
        files["shaders/effects/depth.frag"] = "#include \"depth70.h\"\nvoid main() { gl_FragColor = vec4(1.0); }"
        let fixture = try makeFixture(files: files)
        defer { fixture.cleanup() }
        do {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: includeProbeGraph(shader: "effects/depth"))
            Issue.record("Deep include expansion escaped its depth limit")
        } catch let WPERenderPipelineError.sourceExpansionLimit(_, limit) {
            #expect(limit == "include depth (64)")
        }
    }

    @Test("Include expanded-byte budget covers repeated large bodies, even inside a dead branch")
    func includeOutputByteBudget() throws {
        let body = "//" + String(repeating: "x", count: 1024 * 1024)
        let includes = Array(repeating: "#include \"large.h\"", count: 9).joined(separator: "\n")
        let fixture = try makeFixture(files: [
            "shaders/effects/large.h": body,
            "shaders/effects/large.vert": "void main() { gl_Position = vec4(0.0); }",
            "shaders/effects/large.frag": "#if 0\n" + includes + "\n#endif\nvoid main() { gl_FragColor = vec4(1.0); }",
        ])
        defer { fixture.cleanup() }
        do {
            _ = try WPERenderPipelineBuilder(cacheRootURL: fixture.root).build(graph: includeProbeGraph(shader: "effects/large"))
            Issue.record("Large include expansion escaped its byte limit")
        } catch let WPERenderPipelineError.sourceExpansionLimit(_, limit) {
            #expect(limit == "expanded bytes (8 MiB)")
        }
    }
}
