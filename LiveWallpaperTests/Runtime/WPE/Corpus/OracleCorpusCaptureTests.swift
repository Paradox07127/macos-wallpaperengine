#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("Oracle corpus capture")
struct OracleCorpusCaptureTests {

    private struct Config: Codable {
        let corpusRoot: String
        /// `ConfigurationDirectory` hands a test process its own empty root, so the
        /// app's engine-assets bookmark is invisible here and every scene that pulls
        /// a builtin model dies on `fileMissing`. An explicit path is the way in.
        var engineAssetsRoot: String?
        var label: String = "capture"
        var scenes: [String]?
        var perPass: Bool = false
        var dumpPNGs: Bool = false
        var memoryAuditLog: Bool = false
        var frames: Int = 1
        var frameStepSeconds: Double = 1.0 / 60.0
        var audioProbeLayer: String?
        var jobId: String?
        var replayFrame: [String: Double]?
        var resolution: [Int]?
        var captureGPU: Bool = false

        private enum CodingKeys: String, CodingKey {
            case corpusRoot, engineAssetsRoot, label, scenes, perPass, dumpPNGs, memoryAuditLog, frames, frameStepSeconds, audioProbeLayer
            case jobId, replayFrame, resolution, captureGPU
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            corpusRoot = try container.decode(String.self, forKey: .corpusRoot)
            engineAssetsRoot = try container.decodeIfPresent(String.self, forKey: .engineAssetsRoot)
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? "capture"
            scenes = try container.decodeIfPresent([String].self, forKey: .scenes)
            perPass = try container.decodeIfPresent(Bool.self, forKey: .perPass) ?? false
            dumpPNGs = try container.decodeIfPresent(Bool.self, forKey: .dumpPNGs) ?? false
            memoryAuditLog = try container.decodeIfPresent(Bool.self, forKey: .memoryAuditLog) ?? false
            audioProbeLayer = try container.decodeIfPresent(String.self, forKey: .audioProbeLayer)
            jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
            replayFrame = try container.decodeIfPresent([String: Double].self, forKey: .replayFrame)
            resolution = try container.decodeIfPresent([Int].self, forKey: .resolution)
            captureGPU = try container.decodeIfPresent(Bool.self, forKey: .captureGPU) ?? false
            frames = try container.decodeIfPresent(Int.self, forKey: .frames) ?? 1
            frameStepSeconds = try container.decodeIfPresent(Double.self, forKey: .frameStepSeconds) ?? (1.0 / 60.0)
        }
    }

    /// Opt-in gate as an `.enabled` trait: a missing config must surface as a
    /// SKIPPED test, not a vacuous pass that reads as coverage.
    /// The pointer WPE's capture recorded, threaded in via the same
    /// `WPEOracleReplayPointer*` defaults `oracle.py fidelity` prints. Defaults to
    /// centre when a capture predates pointer recording.
    private static func replayPointer() -> SIMD2<Double> {
        let defaults = UserDefaults.standard
        let x = (defaults.object(forKey: "WPEOracleReplayPointerX") as? Double) ?? 0.5
        let y = (defaults.object(forKey: "WPEOracleReplayPointerY") as? Double) ?? 0.5
        return SIMD2<Double>(x, y)
    }

    private static var captureConfigURL: URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_ORACLE_CAPTURE_CONFIG")
    }

    private static var captureOutputRoot: URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_ORACLE_CAPTURE_OUTPUT")
    }

    @MainActor
    @Test(
        "Capture oracle traces for a scene corpus (opt-in via explicit config path)",
        .enabled(if: captureConfigURL != nil && captureOutputRoot != nil)
    )
    func captureCorpus() async throws {
        let configURL = try #require(Self.captureConfigURL)
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Config.self, from: data)
        let captureStarted = Date()
        let defaults = UserDefaults.standard
        let previousArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previousArguments
        arguments["WPEOraclePerPassHashes"] = config.perPass
        arguments["WPEMemoryAuditLog"] = config.memoryAuditLog
        arguments["WPEMetalFXRenderScale"] = 1.0
        if let replay = config.replayFrame {
            for (field, key) in [("time", "WPEOracleReplayTime"), ("daytime", "WPEOracleReplayDaytime"),
                                 ("pointerX", "WPEOracleReplayPointerX"), ("pointerY", "WPEOracleReplayPointerY")] {
                let value = try #require(replay[field], "Missing replay field: \(field)")
                try #require(value.isFinite && value >= 0, "Invalid replay field: \(field)")
                arguments[key] = value
            }
        }
        let size = config.resolution ?? [1920, 1080]
        try #require(size.count == 2 && size.allSatisfy { $0 > 0 && $0 <= 16384 })
        try #require(config.frames > 0 && config.frameStepSeconds.isFinite && config.frameStepSeconds >= 0)
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }
        try #require(!config.corpusRoot.isEmpty, "oracle-capture.json corpusRoot must not be empty")
        let root = URL(fileURLWithPath: config.corpusRoot)
        let outDir = try #require(Self.captureOutputRoot)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let filter = config.scenes.map(Set.init)
        print("[oracle-capture] config: corpusRoot=\(config.corpusRoot) label=\(config.label) "
              + "scenes=\(config.scenes ?? ["<all>"]) frames=\(config.frames) step=\(config.frameStepSeconds)")

        WPEOracleMode.testingOverride = true
        WPESceneDebugArtifacts.shared.setEnabledForTesting(true)
        defer {
            WPEOracleMode.testingOverride = nil
            WPEOracleMode.frameAdvanceSeconds = 0
            WPESceneDebugArtifacts.shared.setEnabledForTesting(nil)
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let engineAssetsRoot = config.engineAssetsRoot.map { URL(fileURLWithPath: $0) }
            ?? TestScratch.externalFixtureURL(pathKey: "WPE_COVERAGE_ENGINE_ASSETS_ROOT")
        print("[oracle-capture] engineAssetsRoot=\(engineAssetsRoot?.path ?? "<nil>")")

        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var captured = 0, skipped = 0, failed = 0, builtinPassesCaptured = 0
        var graphLayers = 0, authoredJSONLayers = 0, authoredSceneObjectNodes = 0
        var authoredImageDescriptors = 0, malformedAuthoredLayerLinks = 0
        var graphPasses = 0, authoredJSONPasses = 0, malformedAuthoredPassLinks = 0
        for folder in folders {
            let id = folder.lastPathComponent
            if let filter, !filter.contains(id) { continue }
            guard let project = try? WallpaperEngineProject.read(from: folder), project.type == .scene else {
                skipped += 1
                continue
            }

            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("wpe-oracle-\(id)-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: stage) }
            do {
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                let pkgURL = folder.appendingPathComponent("scene.pkg")
                if FileManager.default.fileExists(atPath: pkgURL.path) {
                    let handle = try FileHandle(forReadingFrom: pkgURL)
                    defer { try? handle.close() }
                    let pkg = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
                    try pkg.extractAll(streamingFrom: handle, to: stage)
                } else {
                    for item in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                        try FileManager.default.copyItem(at: item, to: stage.appendingPathComponent(item.lastPathComponent))
                    }
                }
                // `project.json` lives BESIDE scene.pkg, never inside it, and it
                // holds every user-property default. Without it each
                // `{"user":K,"value":V}` envelope falls back to the baked literal
                // and the capture silently renders a different wallpaper than WPE
                // did — 3554161528's u_strength read 1.5 where the slider said 0.5.
                let projectJSON = folder.appendingPathComponent("project.json")
                let stagedProject = stage.appendingPathComponent("project.json")
                if FileManager.default.fileExists(atPath: projectJSON.path),
                   !FileManager.default.fileExists(atPath: stagedProject.path) {
                    try FileManager.default.copyItem(at: projectJSON, to: stagedProject)
                }
            } catch {
                print("[oracle-capture] [\(id)] extract failed: \(error)")
                failed += 1
                continue
            }

            arguments["WPEDumpScenePasses"] = config.dumpPNGs ? id : ""
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            WPEOracleMode.frameAdvanceSeconds = 0
            let descriptor = SceneDescriptor(
                workshopID: id,
                cacheRelativePath: "wpe-oracle-cache/\(id)",
                entryFile: project.entryFile.isEmpty ? "scene.json" : project.entryFile,
                capabilityTier: .degraded
            )
            do {
                let renderer = try WPEMetalSceneRenderer(
                    descriptor: descriptor,
                    cacheRootURL: stage,
                    dependencyMounts: [],
                    engineAssetsRootURL: engineAssetsRoot,
                    frame: CGRect(x: 0, y: 0, width: size[0], height: size[1]),
                    device: device,
                    // WPE's captured frame carries its own pointer; centring ours
                    // shifts every mouse-driven parallax/effect uniform.
                    pointerSampler: .fixed(Self.replayPointer())
                )
                let renderActor = WPEDisplayRenderActor(backing: .main)
                await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)
                let captureManager = MTLCaptureManager.shared()
                if config.captureGPU {
                    try #require(captureManager.supportsDestination(.gpuTraceDocument))
                    let capture = MTLCaptureDescriptor()
                    capture.captureObject = device
                    capture.destination = .gpuTraceDocument
                    capture.outputURL = outDir.appendingPathComponent("\(id).gputrace")
                    try captureManager.startCapture(with: capture)
                }
                defer {
                    if config.captureGPU, captureManager.isCapturing {
                        captureManager.stopCapture()
                    }
                }
                try await renderActor.load()
                let authoredSummary = Self.authoredJSONSummary(renderer.renderGraph)
                graphLayers += authoredSummary.layers
                authoredJSONLayers += authoredSummary.authoredLayers
                authoredSceneObjectNodes += authoredSummary.sceneObjectNodes
                authoredImageDescriptors += authoredSummary.imageDescriptors
                malformedAuthoredLayerLinks += authoredSummary.malformedLayerLinks
                graphPasses += authoredSummary.passes
                authoredJSONPasses += authoredSummary.authoredPasses
                malformedAuthoredPassLinks += authoredSummary.malformedPassLinks
                Self.printTextEvidence(renderer: renderer, sceneID: id)
                try Self.advanceToTracedFrame(
                    renderer: renderer,
                    id: id,
                    entryFile: descriptor.entryFile,
                    stage: stage,
                    frames: config.frames,
                    stepSeconds: config.frameStepSeconds,
                    perPass: config.perPass || config.dumpPNGs
                )
                if config.captureGPU {
                    captureManager.stopCapture()
                }
                if let trace = Self.awaitLatestTrace(forID: id, after: captureStarted) {
                    let builtinSummary = try Self.validateBuiltinPasses(in: trace, sceneID: id)
                    builtinPassesCaptured += builtinSummary.count
                    let dest = outDir.appendingPathComponent("\(id).json")
                    try #require(!FileManager.default.fileExists(atPath: dest.path), "Refusing to overwrite an oracle trace")
                    var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: trace)) as? [String: Any])
                    var capture = document["capture"] as? [String: Any] ?? [:]
                    let solidStats = renderer.executor.lastSolidSceneBatchStats
                    var renderWork = capture["renderWork"] as? [String: Any] ?? [:]
                    renderWork["solidScene"] = ["encoders": solidStats.encoders, "draws": solidStats.draws]
                    let clearStats = renderer.executor.lastInitialSceneClearStats
                    renderWork["initialSceneClear"] = [
                        "passID": clearStats.passID ?? "", "skipped": clearStats.skipped,
                        "fallback": clearStats.fallback, "rejectReason": clearStats.rejectReason ?? "",
                    ]
                    print("[oracle-capture] [\(id)] final-frame initialSceneClear pass=\(clearStats.passID ?? "") skipped=\(clearStats.skipped) fallback=\(clearStats.fallback) reject=\(clearStats.rejectReason ?? "")")
                    if let first = (renderer.lastFramePipeline ?? renderer.renderPipeline)?.layers.first {
                        let graph = first.graphLayer
                        renderWork["initialLayer"] = [
                            "objectID": graph.objectID, "parentObjectID": graph.parentObjectID ?? "",
                            "hasAttachment": graph.attachment != nil, "hasPuppetPath": graph.puppetPath != nil,
                            "hasPuppetModel": first.puppetModel != nil, "hasGroupTarget": graph.groupRenderTarget != nil,
                            "hasGroupCompositeSource": graph.groupCompositeSource != nil,
                            "hasGroupLocalGeometry": graph.groupLocalGeometry != nil,
                        ]
                    }
                    capture["renderWork"] = renderWork
                    print("[oracle-capture] [\(id)] final-frame solidScene encoders=\(solidStats.encoders) draws=\(solidStats.draws)")
                    if let jobId = config.jobId {
                        capture["jobId"] = jobId
                    }
                    document["capture"] = capture
                    try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: dest, options: .atomic)
                    captured += 1
                    print("[oracle-capture] [\(id)] ✅ trace → \(dest.lastPathComponent)")
                    if let layerID = config.audioProbeLayer {
                        try Self.verifyAudioLayer(renderer: renderer, layerID: layerID, outputRoot: outDir)
                    }
                } else {
                    print("[oracle-capture] [\(id)] loaded but no trace written")
                    failed += 1
                }
            } catch {
                print("[oracle-capture] [\(id)] load failed: \(String(describing: error).prefix(200))")
                failed += 1
            }
        }
        print("=== oracle-capture: captured=\(captured) skipped=\(skipped) failed=\(failed) → \(outDir.path) ===")
        print("=== authored-json: graphLayers=\(graphLayers) authoredLayers=\(authoredJSONLayers) "
              + "sceneObjectNodes=\(authoredSceneObjectNodes) imageDescriptors=\(authoredImageDescriptors) "
              + "malformedLayerLinks=\(malformedAuthoredLayerLinks) graphPasses=\(graphPasses) "
              + "authoredPasses=\(authoredJSONPasses) malformedPassLinks=\(malformedAuthoredPassLinks) ===")
        #expect(captured > 0, "no scene produced a trace — check corpus root / engine assets")
        #expect(failed == 0, "one or more requested scenes failed")
        if let filter {
            #expect(captured == filter.count && skipped == 0, "requested scene coverage is incomplete")
        }
        #expect(builtinPassesCaptured > 0, "captured traces contained no hand-authored Metal builtin pass")
        #expect(authoredJSONLayers > 0, "real-scene render graphs exposed no authored scene/model layer JSON")
        #expect(malformedAuthoredLayerLinks == 0, "layer-level authored scene ancestry was lost")
        #expect(authoredJSONPasses > 0, "real-scene render graphs exposed no material/effect authored JSON")
        #expect(malformedAuthoredPassLinks == 0, "pass-level authored JSON lost its parent document")
    }

    /// Isolate a real scene layer, pin every other input, and drive its shader
    /// uniforms with silence/full-scale spectra. A live tap is neither required
    /// nor evidence of GPU consumption; the trace records the packed slots.
    @MainActor
    private static func verifyAudioLayer(
        renderer: WPEMetalSceneRenderer, layerID: String, outputRoot: URL
    ) throws {
        let layer = try #require(renderer.renderPipeline?.layers.first { $0.graphLayer.objectID == layerID })
        let pipeline = WPEPreparedRenderPipeline(layers: [layer])
        let executor = try WPEMetalRenderExecutor(device: renderer.executor.textureSourceDevice)
        var coverage: [Int] = []
        for level in [0.0, 1.0] {
            let id = "audio-\(layerID)-\(Int(level))"
            _ = WPESceneDebugArtifacts.shared.beginSession(workshopID: id, descriptor: "audio consumption probe")
            WPECanonicalTraceRecorder.shared.beginScene(
                workshopID: id, projectJsonPath: "scene.json", descriptor: "audio consumption probe"
            )
            let uniforms = WPEMetalRuntimeUniforms(
                time: 6, daytime: 0, brightness: 1, pointerPosition: SIMD2(0.5, 0.5),
                audioSpectrum: Array(repeating: level, count: 64)
            )
            let texture = try executor.render(
                pipeline: pipeline, size: renderer.sceneRenderSize, textures: renderer.loadedTextures,
                textureSamplingDescriptors: renderer.loadedTextureSamplingDescriptors,
                dynamicLayerIDs: [layerID], runtimeUniforms: uniforms,
                cameraUniforms: renderer.cameraUniforms, sceneID: id
            )
            let stats = try #require(WPEMetalTextureVisualStats.analyze(texture: texture))
            coverage.append(stats.nonBlackPixelCount)
            WPECanonicalTraceRecorder.shared.finishFrame(
                outputTexture: texture, runtimeUniforms: uniforms, firstFrameStats: stats,
                resolutionDiagnostics: renderer.resolutionTracer.snapshot()
            )
            WPESceneDebugArtifacts.shared.endSession()
            let trace = try #require(awaitLatestTrace(forID: id))
            let destination = outputRoot.appendingPathComponent("\(id).json")
            try FileManager.default.copyItem(at: trace, to: destination)
            print("[audio-probe] layer=\(layerID) spectrum=\(level) nonBlack=\(stats.nonBlackPixelCount)")
        }
        #expect(coverage[1] > coverage[0], "The real layer must draw more audio bars with nonzero spectra")
    }

    @Test("Config decode fills in defaults for keys a config file omits")
    func configDecodeFillsDefaultsForMissingKeys() throws {
        let json = Data(#"{"corpusRoot": "/tmp/corpus"}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.corpusRoot == "/tmp/corpus")
        #expect(config.label == "capture")
        #expect(config.scenes == nil)
        #expect(config.perPass == false)
        #expect(config.dumpPNGs == false)
        #expect(config.memoryAuditLog == false)
        #expect(config.frames == 1)
        #expect(config.frameStepSeconds == 1.0 / 60.0)
    }

    @Test("Config decode accepts an explicit multi-frame capture")
    func configDecodeAcceptsFrames() throws {
        let json = Data(#"{"corpusRoot": "/tmp/corpus", "frames": 4, "frameStepSeconds": 0.5}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.frames == 4)
        #expect(config.frameStepSeconds == 0.5)
    }

    @Test("Frozen clock advances with frameAdvanceSeconds, and is inert at 0")
    func frozenClockAdvancesWithFrameAdvance() throws {
        WPEOracleMode.testingOverride = true
        defer {
            WPEOracleMode.testingOverride = nil
            WPEOracleMode.frameAdvanceSeconds = 0
        }
        WPEOracleMode.frameAdvanceSeconds = 0
        let override = try #require(WPEOracleMode.loadFrameOverride())
        let frozen = override.time
        #expect(override.time == override.baseTime, "advance 0 must leave the clock exactly frozen")

        WPEOracleMode.frameAdvanceSeconds = 0.25
        #expect(override.time == frozen + 0.25)
        #expect(override.baseTime == frozen)
    }

    @Test("Config decode throws on a malformed config instead of silently defaulting")
    func configDecodeThrowsOnMalformedConfig() {
        let missingCorpusRoot = Data(#"{"label": "oops"}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: missingCorpusRoot)
        }

        let wrongShape = Data(#"{"corpusRoot": 12345}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: wrongShape)
        }
    }

    @MainActor
    private static func advanceToTracedFrame(
        renderer: WPEMetalSceneRenderer,
        id: String,
        entryFile: String,
        stage: URL,
        frames: Int,
        stepSeconds: Double,
        perPass: Bool
    ) throws {
        guard frames > 1 else { return }
        let summary = "\(id) oracle-capture frames=\(frames) step=\(stepSeconds)"
        for index in 1..<frames {
            WPEOracleMode.frameAdvanceSeconds = Double(index) * stepSeconds
            let isLast = index == frames - 1
            if isLast {
                _ = WPESceneDebugArtifacts.shared.beginSession(workshopID: id, descriptor: summary)
                WPECanonicalTraceRecorder.shared.beginScene(
                    workshopID: id,
                    projectJsonPath: stage.appendingPathComponent(entryFile).path,
                    descriptor: summary,
                    shaderImplementationInventory: renderer.shaderImplementationInventory
                )
            }
            // Drain per frame like WPERenderThread does in-app; without this the
            // loop accumulates every autoreleased Metal object (measured ~0.5 MB/frame).
            let texture = try autoreleasepool {
                try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            }
            guard isLast else { continue }
            if perPass {
                renderer.dumpScenePassesIfRequested(suffix: "-f\(index)")
            }
            WPECanonicalTraceRecorder.shared.finishFrame(
                outputTexture: texture,
                runtimeUniforms: renderer.lastRuntimeUniforms,
                firstFrameStats: WPEMetalTextureVisualStats.analyze(texture: texture),
                resolutionDiagnostics: renderer.resolutionTracer.snapshot(),
                frameOrdinal: index
            )
            WPESceneDebugArtifacts.shared.endSession()
            print("[oracle-capture] [\(id)] advanced to frame \(index) "
                  + "(t=\(renderer.lastRuntimeUniforms.map { String(format: "%.4f", $0.time) } ?? "?"))")
        }
    }

    private static func latestTrace(forID id: String) -> URL? {
        guard let root = WPESceneDebugArtifacts.rootURL else { return nil }
        let sessions = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-\(id)") }
        let newest = sessions.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let session = newest else { return nil }
        let trace = session.appendingPathComponent("trace.json")
        return FileManager.default.fileExists(atPath: trace.path) ? trace : nil
    }

    /// `recordNote` intentionally writes on the artifacts utility queue. Wait for
    /// that bounded handoff instead of racing `fileExists` immediately after
    /// `finishFrame`; the renderer itself remains fully asynchronous.
    private static func awaitLatestTrace(forID id: String, after: Date = .distantPast) -> URL? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let trace = latestTrace(forID: id),
               let modified = try? trace.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= after {
                return trace
            }
            usleep(20_000)
        } while Date() < deadline
        return nil
    }

    private static func validateBuiltinPasses(
        in traceURL: URL,
        sceneID: String
    ) throws -> (count: Int, kinds: [String]) {
        let data = try Data(contentsOf: traceURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let passes = try #require(root["passes"] as? [[String: Any]])
        var kinds: [String] = []
        for pass in passes {
            guard let builtin = pass["builtin"] as? [String: Any] else { continue }
            kinds.append((builtin["kind"] as? String) ?? "<missing>")
            let targets = try #require(pass["targets"] as? [String: Any])
            let colors = try #require(targets["color"] as? [[String: Any]])
            #expect(colors.first?["resource"] is String)
            let shaders = try #require(pass["shaders"] as? [String: Any])
            #expect(shaders["vs"] is String)
            #expect(shaders["fs"] is String)
            let draw = try #require(pass["draw"] as? [String: Any])
            #expect(draw["topology"] is String)
            let state = try #require(pass["state"] as? [String: Any])
            #expect(state["blend"] is [String: Any])
            let buffers = try #require(pass["constantBuffers"] as? [Any])
            #expect(buffers.isEmpty, "builtin passes must not fabricate GLSL reflection buffers")
        }
        let histogram = Dictionary(grouping: kinds, by: { $0 })
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        print("[oracle-capture] [\(sceneID)] trace-summary passes=\(passes.count) "
              + "builtin=\(kinds.count) kinds={\(histogram)}")
        return (kinds.count, kinds)
    }

    private static func authoredJSONSummary(
        _ graph: WPERenderGraph?
    ) -> (
        layers: Int,
        authoredLayers: Int,
        sceneObjectNodes: Int,
        imageDescriptors: Int,
        malformedLayerLinks: Int,
        passes: Int,
        authoredPasses: Int,
        malformedPassLinks: Int
    ) {
        guard let graph else { return (0, 0, 0, 0, 0, 0, 0, 0) }
        var authoredLayers = 0
        var sceneObjectNodes = 0
        var imageDescriptors = 0
        var malformedLayerLinks = 0
        var passes = 0
        var authoredPasses = 0
        var malformedPassLinks = 0
        for layer in graph.layers {
            let authored = layer.authoredJSON
            if authored != .empty { authoredLayers += 1 }
            sceneObjectNodes += authored.sceneObjects.count
            if authored.imageDescriptor != nil { imageDescriptors += 1 }
            if authored.sceneObjects.isEmpty { malformedLayerLinks += 1 }
        }
        for pass in graph.layers.flatMap(\.passes) {
            passes += 1
            let authored = pass.authoredJSON
            if authored != .empty { authoredPasses += 1 }
            if authored.materialPass != nil, authored.materialDocument == nil {
                malformedPassLinks += 1
            }
            if authored.effectPass != nil, authored.effectDocument == nil {
                malformedPassLinks += 1
            }
        }
        return (
            graph.layers.count,
            authoredLayers,
            sceneObjectNodes,
            imageDescriptors,
            malformedLayerLinks,
            passes,
            authoredPasses,
            malformedPassLinks
        )
    }

    @MainActor
    private static func printTextEvidence(
        renderer: WPEMetalSceneRenderer,
        sceneID: String
    ) {
        let pairs = Array(zip(renderer.textObjects, renderer.textRenderPlans))
        let direct = pairs.filter { $0.1.mode == .direct }
        let effect = pairs.filter { object, _ in
            object.effects.contains { $0.visible || $0.visibleScript != nil }
        }
        let copy = pairs.filter { $0.0.copyBackground }
        let opaque = pairs.filter { $0.0.opaqueBackground }
        let parented = pairs.filter { $0.0.parentObjectID != nil }
        func example(_ values: [(WPESceneTextObject, WPETextRenderPlan)]) -> String {
            guard let object = values.first?.0 else { return "-" }
            return "\(object.id):\(object.name)"
        }
        let fields = [
            "total=\(pairs.count)",
            "direct=\(direct.count)[\(example(direct))]",
            "effect=\(effect.count)[\(example(effect))]",
            "copy=\(copy.count)[\(example(copy))]",
            "opaque=\(opaque.count)[\(example(opaque))]",
            "parented=\(parented.count)[\(example(parented))]",
        ]
        print("[oracle-capture] [\(sceneID)] text-evidence " + fields.joined(separator: " "))
    }
}

@Suite("Oracle text corpus evidence")
struct OracleTextCorpusEvidenceTests {
    private struct RootConfig: Decodable { let corpusRoot: String }
    private static var configURL: URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_ORACLE_CAPTURE_CONFIG")
    }

    @Test(
        "Scan packaged scene JSON for real copy/opaque text examples",
        .enabled(if: configURL != nil)
    )
    func scanTextBackgroundModes() throws {
        let configURL = try #require(Self.configURL)
        let config = try JSONDecoder().decode(
            RootConfig.self,
            from: Data(contentsOf: configURL)
        )
        let root = URL(fileURLWithPath: config.corpusRoot, isDirectory: true)
        let folders = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        var copyExamples: [String] = []
        var opaqueExamples: [String] = []
        var parsedScenes = 0
        for folder in folders {
            guard let project = try? WallpaperEngineProject.read(from: folder),
                  project.type == .scene else { continue }
            let packageURL = folder.appendingPathComponent("scene.pkg")
            guard FileManager.default.fileExists(atPath: packageURL.path) else { continue }
            let handle = try FileHandle(forReadingFrom: packageURL)
            defer { try? handle.close() }
            let package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
            let entryName = (project.entryFile.isEmpty ? "scene.json" : project.entryFile).lowercased()
            guard let entry = package.nameIndex[entryName], entry.dataSize <= 64 * 1024 * 1024 else {
                continue
            }
            try handle.seek(toOffset: package.dataStart + entry.dataOffset)
            guard let data = try handle.read(upToCount: Int(entry.dataSize)),
                  data.count == Int(entry.dataSize),
                  let document = try? WPESceneDocumentParser.parse(data: data) else { continue }
            parsedScenes += 1
            for object in document.textObjects {
                let identity = "\(folder.lastPathComponent)/\(object.id):\(object.name)"
                if object.copyBackground { copyExamples.append(identity) }
                if object.opaqueBackground { opaqueExamples.append(identity) }
            }
        }

        print("[text-corpus-evidence] parsedScenes=\(parsedScenes) "
              + "copy=\(copyExamples.count){\(copyExamples.joined(separator: ","))} "
              + "opaque=\(opaqueExamples.count){\(opaqueExamples.joined(separator: ","))}")
        #expect(parsedScenes > 0)
    }
}
#endif
