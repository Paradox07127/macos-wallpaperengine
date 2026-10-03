#if !LITE_BUILD
import AppKit
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Oracle corpus capture")
struct OracleCorpusCaptureTests {
    private enum VideoMode: String, Codable {
        case liveWallClock, firstFrameStill
    }

    private struct Config: Codable {
        let corpusRoot: String
        /// A test process gets its own empty `ConfigurationDirectory`, so without an explicit path every scene pulling a builtin model dies on `fileMissing`.
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
        var videoMode: VideoMode = .liveWallClock
        var authoredVertexExecution: Bool = true
        var propertyOverridesByScene: [String: [String: WallpaperEngineProjectPropertyValue]] = [:]
        var pixelProbeCoordinates: [[Int]]?
        var captureStages: Bool = false
        /// Test input injection, not a product texture-quality setting.
        var sourceMipLevel: Int?
        var scriptOrder: WPESceneScriptBatchDispatcher.SubmissionOrder = .parallelWorkers
        /// Test-only SceneScript input injection, not settings UI or property-patch acceptance.
        var propertySequence: [[String: WallpaperEngineProjectPropertyValue]] = []
        var sequenceWarmupFrames: Int = 8
        var sequenceCaptureFrames: Int = 3

        private enum CodingKeys: String, CodingKey {
            case corpusRoot, engineAssetsRoot, label, scenes, perPass, dumpPNGs, memoryAuditLog, frames, frameStepSeconds, audioProbeLayer
            case jobId, replayFrame, resolution, captureGPU, videoMode, scriptOrder, authoredVertexExecution, propertyOverridesByScene, pixelProbeCoordinates, captureStages
            case sourceMipLevel
            case propertySequence, sequenceWarmupFrames, sequenceCaptureFrames
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
            videoMode = try container.decodeIfPresent(VideoMode.self, forKey: .videoMode) ?? .liveWallClock
            scriptOrder = try container.decodeIfPresent(WPESceneScriptBatchDispatcher.SubmissionOrder.self, forKey: .scriptOrder) ?? .parallelWorkers
            authoredVertexExecution = try container.decodeIfPresent(Bool.self, forKey: .authoredVertexExecution) ?? true
            propertyOverridesByScene = try container.decodeIfPresent([String: [String: WallpaperEngineProjectPropertyValue]].self, forKey: .propertyOverridesByScene) ?? [:]
            pixelProbeCoordinates = try container.decodeIfPresent([[Int]].self, forKey: .pixelProbeCoordinates)
            captureStages = try container.decodeIfPresent(Bool.self, forKey: .captureStages) ?? false
            sourceMipLevel = try container.decodeIfPresent(Int.self, forKey: .sourceMipLevel)
            if let sourceMipLevel, !(0 ... 14).contains(sourceMipLevel) {
                throw DecodingError.dataCorruptedError(forKey: .sourceMipLevel, in: container,
                                                       debugDescription: "sourceMipLevel must be in 0...14")
            }
            frames = try container.decodeIfPresent(Int.self, forKey: .frames) ?? 1
            frameStepSeconds = try container.decodeIfPresent(Double.self, forKey: .frameStepSeconds) ?? (1.0 / 60.0)
            propertySequence = try container.decodeIfPresent([[String: WallpaperEngineProjectPropertyValue]].self, forKey: .propertySequence) ?? []
            sequenceWarmupFrames = try container.decodeIfPresent(Int.self, forKey: .sequenceWarmupFrames) ?? 8
            sequenceCaptureFrames = try container.decodeIfPresent(Int.self, forKey: .sequenceCaptureFrames) ?? 3
            if !propertySequence.isEmpty {
                guard propertySequence.count <= 16, (1 ... 60).contains(sequenceWarmupFrames),
                      (2 ... 8).contains(sequenceCaptureFrames), scriptOrder == .parallelWorkers,
                      propertySequence.allSatisfy({ values in
                          guard case let .number(stage)? = values["stage"] else { return false }
                          return stage.isFinite && stage.rounded(.towardZero) == stage && (0 ... 999).contains(stage)
                      }) else {
                    throw DecodingError.dataCorruptedError(forKey: .propertySequence, in: container,
                                                           debugDescription: "Bounded stage sequence requires parallelWorkers and integer stage values")
                }
            }
        }
    }

    /// The pointer WPE's capture recorded, read from the `WPEOracleReplayPointer*` defaults; 0.5/0.5 when a capture predates pointer recording.
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
        arguments["WPETracePassLabels"] = config.captureGPU
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
        try #require(config.sourceMipLevel == nil || config.frames > 1,
                     "Mip injection occurs after load; capture at least one subsequent frame")
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
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var captured = 0, skipped = 0, failed = 0, builtinPassesCaptured = 0
        var graphLayers = 0, authoredJSONLayers = 0, authoredSceneObjectNodes = 0
        var authoredImageDescriptors = 0, malformedAuthoredLayerLinks = 0
        var graphPasses = 0, authoredJSONPasses = 0, malformedAuthoredPassLinks = 0
        var synthesizedPasses = 0, missingAuthoredPasses = 0
        for folder in folders {
            let id = folder.lastPathComponent
            if let filter, !filter.contains(id) {
                continue
            }
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
                // `project.json` lives BESIDE scene.pkg and holds every user-property default; without it each
                // `{"user":K,"value":V}` envelope falls back to its baked literal and the capture renders something else.
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
                capabilityTier: .degraded,
                propertyOverrides: config.propertyOverridesByScene[id] ?? [:]
            )
            let renderActor = WPEDisplayRenderActor(backing: .main)
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
                // Config resolution is expressed in pixels. The convenience initializer
                // receives AppKit points, whose backing scale can otherwise double HDR
                // captures while SDR scenes hide the mistake behind their canvas cap.
                renderer.updateSurfaceGeometry(drawableSize: CGSize(width: size[0], height: size[1]))
                renderer.oracleSceneScriptBatchOrder = config.scriptOrder
                renderer.executor.authoredVertexExecutionEnabled = config.authoredVertexExecution
                renderer.executor.oracleSceneStagesEnabled = config.captureStages
                if config.videoMode == .firstFrameStill {
                    // A zero-ticket local admission uses the existing deterministic
                    // still extraction path; it does not change the process budget.
                    renderer.oracleVideoDecoderAdmission = WPEVideoDecoderAdmission(limit: 0)
                }
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
                try Self.awaitSceneScriptBatch(renderer)
                let mipInjection: [[String: Any]] = if let sourceMipLevel = config.sourceMipLevel {
                    try await Self.injectSourceMip(level: sourceMipLevel, renderer: renderer)
                } else {
                    []
                }
                let authoredSummary = Self.authoredJSONSummary(renderer.renderGraph)
                graphLayers += authoredSummary.layers
                authoredJSONLayers += authoredSummary.authoredLayers
                authoredSceneObjectNodes += authoredSummary.sceneObjectNodes
                authoredImageDescriptors += authoredSummary.imageDescriptors
                malformedAuthoredLayerLinks += authoredSummary.malformedLayerLinks
                graphPasses += authoredSummary.passes
                authoredJSONPasses += authoredSummary.authoredPasses
                malformedAuthoredPassLinks += authoredSummary.malformedPassLinks
                synthesizedPasses += authoredSummary.synthesizedPasses
                missingAuthoredPasses += authoredSummary.missingAuthoredPasses
                Self.printTextEvidence(renderer: renderer, sceneID: id)
                let advancedFrame = try Self.advanceToTracedFrame(
                    renderer: renderer,
                    id: id,
                    entryFile: descriptor.entryFile,
                    stage: stage,
                    frames: config.frames,
                    stepSeconds: config.frameStepSeconds,
                    perPass: config.perPass || config.dumpPNGs
                )
                if config.captureGPU, config.propertySequence.isEmpty {
                    captureManager.stopCapture()
                }
                let frameTrace: URL?
                if config.frames > 1 {
                    // Use the exact last frame returned by the recorder. Shader dumps
                    // from load can update an older session directory after this one,
                    // making directory modification time an unreliable frame selector.
                    let data = try #require(advancedFrame?.trace, "Final-frame canonical trace serialization failed")
                    let url = outDir.appendingPathComponent("\(id)-raw-frame.json")
                    try data.write(to: url, options: .atomic)
                    frameTrace = url
                } else {
                    frameTrace = Self.awaitLatestTrace(forID: id, after: captureStarted)
                }
                if let trace = frameTrace {
                    let builtinSummary = try Self.validateBuiltinPasses(in: trace, sceneID: id)
                    builtinPassesCaptured += builtinSummary.count
                    let dest = outDir.appendingPathComponent("\(id).json")
                    try #require(!FileManager.default.fileExists(atPath: dest.path), "Refusing to overwrite an oracle trace")
                    var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: trace)) as? [String: Any])
                    var capture = document["capture"] as? [String: Any] ?? [:]
                    var determinism = capture["determinism"] as? [String: Any] ?? [:]
                    determinism["scriptScheduling"] = "bounded-batch-completion-between-capture-frames"
                    determinism["scriptOrder"] = config.scriptOrder.rawValue
                    determinism["liveScriptSchedulingValidated"] = false
                    determinism["authoredVertexExecution"] = config.authoredVertexExecution
                    determinism["metalValidationConfiguration"] = Self.metalValidationConfiguration()
                    determinism["videoMode"] = config.videoMode.rawValue
                    determinism["videoPlaybackValidated"] = false
                    if let sourceMipLevel = config.sourceMipLevel {
                        determinism["sourceMipInputInjection"] = [
                            "sourceMipLevel": sourceMipLevel,
                            "scope": "test-only-closed-static-source-input",
                            "productQualitySettingValidated": false,
                            "configSHA256": Self.sha256(data),
                            "sources": mipInjection,
                        ]
                    }
                    capture["determinism"] = determinism
                    if let points = config.pixelProbeCoordinates {
                        let texture = try #require(advancedFrame?.texture ?? renderer.outputTexture)
                        capture["pixelProbe"] = try WPEOraclePixelProbe.stageEvidence(
                            stage: "post-color-correction", texture: texture, coordinates: points,
                            commandQueue: renderer.executor.commandQueue,
                            frameOrdinal: config.frames - 1, time: renderer.lastRuntimeUniforms?.time ?? 0
                        )
                    }
                    if config.captureStages {
                        let source = try #require(advancedFrame?.texture ?? renderer.outputTexture)
                        let terminal = try WPEOraclePixelProbe.terminalLinearTexture(source: source, executor: renderer.executor)
                        let snapshots = renderer.executor.scenePassDumps.filter { $0.label.hasPrefix("oracle.") }
                        try #require(snapshots.count == 3, "Missing oracle scene stage snapshots")
                        let points = config.pixelProbeCoordinates ?? [[source.width / 2, source.height / 2]]
                        let stages = snapshots.map { (String($0.label.dropFirst("oracle.".count)), $0.texture) }
                            + [("terminal-linear", terminal)]
                        capture["stages"] = try stages.map { name, texture in
                            try WPEOraclePixelProbe.stageEvidence(
                                stage: name, texture: texture, coordinates: points,
                                commandQueue: renderer.executor.commandQueue,
                                frameOrdinal: config.frames - 1, time: renderer.lastRuntimeUniforms?.time ?? 0
                            )
                        }
                    }
                    capture["propertyOverrides"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor.propertyOverrides))
                    capture["propertyOverridesSource"] = config.propertyOverridesByScene[id] == nil ? "project-defaults" : "explicit-capture-config"
                    let solidStats = renderer.executor.lastSolidSceneBatchStats
                    var renderWork = capture["renderWork"] as? [String: Any] ?? [:]
                    let diagnostics = renderer.executor.lastDiagnosticFrameStats
                    renderWork["diagnosticControls"] = [
                        "waterShaderOptimizationsEnabled": WPEShaderTranspiler.waterOptimizationsEnabled,
                        "disableParticleBatching": diagnostics.controls.disableParticleBatching,
                        "disableSolidBatching": diagnostics.controls.disableSolidBatching,
                        "disableFBOAliasing": diagnostics.controls.disableFBOAliasing,
                        "disableSceneAliasDirectBind": diagnostics.controls.disableSceneAliasDirectBind,
                        "canonicalCompositeRotationEnabled": renderer.lastCanonicalRotation.enabled,
                        "fullFramePassthroughElisionEnabled": renderer.lastFullFramePassthroughElision.enabled,
                        "particleBatchingEnabled": diagnostics.particleBatchingEnabled,
                        "solidBatchingEnabled": diagnostics.solidBatchingEnabled,
                        "sceneQuadBatchingEnabled": diagnostics.sceneQuadBatchingEnabled,
                        "fboAliasingEnabled": diagnostics.fboAliasingEnabled,
                        "perPassReadbackActive": diagnostics.perPassReadbackActive,
                        "particleEncoderCount": diagnostics.particleEncoderCount,
                        "particleSystemsEncoded": diagnostics.particleSystemsEncoded,
                        "plannedAliasIntervalCount": diagnostics.plannedAliasIntervalCount,
                        "submittedAliasIntervalCount": diagnostics.aliasIntervalCount,
                        "sceneAliasSnapshotBlits": diagnostics.sceneAliasSnapshotBlits,
                        "sceneAliasDirectBinds": diagnostics.sceneAliasDirectBinds,
                    ] as [String: Any]
                    print("[oracle-capture] [\(id)] diagnostics particles=\(diagnostics.particleEncoderCount)/\(diagnostics.particleSystemsEncoded) aliasIntervals=\(diagnostics.aliasIntervalCount)/\(diagnostics.plannedAliasIntervalCount) readback=\(diagnostics.perPassReadbackActive)")
                    let quadStats = renderer.executor.lastSceneQuadBatchStats
                    renderWork["sceneQuads"] = [
                        "enabled": renderer.executor.sceneQuadBatchingEnabled,
                        "encoders": quadStats.encoders,
                        "draws": quadStats.draws,
                        "texturedDraws": quadStats.texturedDraws,
                        "rejectedLayers": quadStats.rejectedPasses,
                    ] as [String: Any]
                    renderWork["solidScene"] = ["encoders": solidStats.encoders, "draws": solidStats.draws]
                    renderWork["canonicalRotation"] = [
                        "enabled": renderer.lastCanonicalRotation.enabled,
                        "decisions": renderer.lastCanonicalRotation.decisions,
                    ] as [String: Any]
                    renderWork["fullFramePassthroughElision"] = [
                        "enabled": renderer.lastFullFramePassthroughElision.enabled,
                        "decisions": renderer.lastFullFramePassthroughElision.decisions,
                    ] as [String: Any]
                    let clearStats = renderer.executor.lastInitialSceneClearStats
                    renderWork["layerInputSnapshots"] = Self.layerInputSnapshots(renderer)
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
                if !config.propertySequence.isEmpty {
                    try Self.capturePropertySequence(renderer: renderer, id: id, entryFile: descriptor.entryFile,
                                                     stage: stage, outputRoot: outDir, config: config)
                    if config.captureGPU {
                        captureManager.stopCapture()
                    }
                }
            } catch {
                print("[oracle-capture] [\(id)] load failed: \(String(describing: error).prefix(200))")
                failed += 1
            }
            await renderActor.teardownRenderer()
            _ = await renderActor.shutdown()
        }
        print("=== oracle-capture: captured=\(captured) skipped=\(skipped) failed=\(failed) → \(outDir.path) ===")
        print("=== authored-json: graphLayers=\(graphLayers) authoredLayers=\(authoredJSONLayers) "
            + "sceneObjectNodes=\(authoredSceneObjectNodes) imageDescriptors=\(authoredImageDescriptors) "
            + "malformedLayerLinks=\(malformedAuthoredLayerLinks) graphPasses=\(graphPasses) "
            + "authoredPasses=\(authoredJSONPasses) synthesizedPasses=\(synthesizedPasses) "
            + "missingAuthoredPasses=\(missingAuthoredPasses) malformedPassLinks=\(malformedAuthoredPassLinks) ===")
        #expect(captured > 0, "no scene produced a trace — check corpus root / engine assets")
        #expect(failed == 0, "one or more requested scenes failed")
        if let filter {
            #expect(captured == filter.count && skipped == 0, "requested scene coverage is incomplete")
        }
        #expect(builtinPassesCaptured > 0, "captured traces contained no hand-authored Metal builtin pass")
        #expect(authoredJSONLayers > 0, "real-scene render graphs exposed no authored scene/model layer JSON")
        #expect(malformedAuthoredLayerLinks == 0, "layer-level authored scene ancestry was lost")
        #expect(graphPasses > 0 && authoredJSONPasses + synthesizedPasses == graphPasses,
                "Every pass must retain authored JSON or match a specific synthesized graph path")
        #expect(missingAuthoredPasses == 0, "Material/effect pass provenance is missing or incomplete")
        #expect(malformedAuthoredPassLinks == 0, "pass-level authored JSON lost its parent document")
    }

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
        #expect(config.authoredVertexExecution)
        #expect(config.propertyOverridesByScene.isEmpty)
        #expect(config.sourceMipLevel == nil)
    }

    @Test("Oracle source mip injection is explicit and accepts only integer levels 0 through 14")
    func sourceMipConfigValidation() throws {
        for value in ["0", "1", "14"] {
            let config = try JSONDecoder().decode(Config.self, from: Data("{\"corpusRoot\":\"/tmp\",\"sourceMipLevel\":\(value)}".utf8))
            #expect(config.sourceMipLevel == Int(value))
        }
        for value in ["-1", "15", "1.5", "true", "\"1\""] {
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(Config.self, from: Data("{\"corpusRoot\":\"/tmp\",\"sourceMipLevel\":\(value)}".utf8))
            }
        }
    }

    private enum SourceMipInjectionError: Error {
        case invalidLevel, dynamicSource, missingMip, invalidDimensions
    }

    private static func sourceMipUpload(_ payload: WPETexTexturePayload, level: Int) throws -> WPETexTexturePayload {
        guard (0 ... 14).contains(level) else { throw SourceMipInjectionError.invalidLevel }
        guard !payload.hasAnimationFrames, payload.animationTrack == nil, payload.videoPayload == nil else {
            throw SourceMipInjectionError.dynamicSource
        }
        guard let mip = payload.mipmaps.first(where: { $0.index == level }), !mip.bytes.isEmpty else {
            throw SourceMipInjectionError.missingMip
        }
        let info = payload.info
        guard info.imageWidth > 0, info.imageHeight > 0,
              mip.width == max(1, info.width >> level), mip.height == max(1, info.height >> level) else {
            throw SourceMipInjectionError.invalidDimensions
        }
        let uploadInfo = WPETexInfo(
            containerVersion: info.containerVersion, infoVersion: info.infoVersion,
            width: mip.width, height: mip.height, textureFormatCode: info.textureFormatCode,
            format: info.format, mipmapCount: 1, flags: info.flags,
            imageWidth: max(1, info.imageWidth >> level), imageHeight: max(1, info.imageHeight >> level)
        )
        return WPETexTexturePayload(info: uploadInfo,
                                    mipmaps: [.init(index: 0, width: mip.width, height: mip.height, bytes: mip.bytes)],
                                    hasAnimationFrames: false)
    }

    @Test("Oracle mip injection selects actual bytes, floors mapped dimensions and refuses missing/dynamic sources")
    func sourceMipUploadSelection() throws {
        let info = WPETexInfo(containerVersion: 5, infoVersion: 1, width: 32, height: 48,
                              textureFormatCode: WPETexFormat.rgba8888.rawValue, format: .rgba8888,
                              mipmapCount: 2, flags: 2, imageWidth: 31, imageHeight: 47)
        let mips = [WPETexTextureMipmap(index: 0, width: 32, height: 48, bytes: Data(repeating: 7, count: 32 * 48 * 4)),
                    WPETexTextureMipmap(index: 1, width: 16, height: 24, bytes: Data(repeating: 9, count: 16 * 24 * 4))]
        let payload = WPETexTexturePayload(info: info, mipmaps: mips, hasAnimationFrames: false)
        let upload = try Self.sourceMipUpload(payload, level: 1)
        #expect(upload.mipmaps.count == 1)
        #expect(upload.mipmaps[0].index == 0)
        #expect(upload.mipmaps[0].bytes == mips[1].bytes)
        #expect(upload.info.imageWidth == 15 && upload.info.imageHeight == 23)
        #expect(upload.info.width == 16 && upload.info.height == 24)
        #expect(upload.info.flags == info.flags)
        #expect(try Self.sourceMipUpload(payload, level: 0).mipmaps[0].bytes == mips[0].bytes)
        #expect(throws: SourceMipInjectionError.self) { _ = try Self.sourceMipUpload(payload, level: 2) }
        let dynamic = WPETexTexturePayload(info: info, mipmaps: mips, hasAnimationFrames: true)
        #expect(throws: SourceMipInjectionError.self) { _ = try Self.sourceMipUpload(dynamic, level: 1) }
        let video = WPETexTexturePayload(info: info, mipmaps: mips, hasAnimationFrames: false,
                                         videoPayload: .init(bytes: Data([0]), fileExtension: "mp4"))
        #expect(throws: SourceMipInjectionError.self) { _ = try Self.sourceMipUpload(video, level: 1) }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    private static func injectSourceMip(level: Int, renderer: WPEMetalSceneRenderer) async throws -> [[String: Any]] {
        let pipeline = try #require(renderer.renderPipeline)
        var evidence: [[String: Any]] = []
        var injectedPaths = Set<String>()
        for layer in pipeline.layers {
            guard let extent = layer.graphLayer.compositeSourceExtent else { continue }
            let pass = try #require(layer.passes.first)
            let path = try #require(renderer.externalTexturePath(for: pass.textureBindings[0] ?? pass.pass.source))
            guard injectedPaths.insert(path).inserted else { continue }
            try #require(renderer.dynamicTextureSources[path] == nil && renderer.loadedTextures[path] != nil,
                         "Mip injection requires a resident static texture: \(path)")
            var probe: SceneResourceResolver.ResolvedTextureFormatProbe?
            for candidate in renderer.textureCandidates(for: path) {
                do {
                    probe = try renderer.resourceResolver.resolveTextureFormatProbe(relativePath: candidate, optional: true)
                    break
                } catch SceneResourceResolver.ResolveError.fileMissing {
                    continue
                }
            }
            let resolved = try #require(probe, "Missing source: \(path)")
            let span = try #require(resolved.texPayload, "Mip injection requires original TEX bytes: \(path)")
            let decoder = WPETexDecoder()
            try #require(try decoder.probeStaticImage(span: span) != nil, "Dynamic/encoded TEX cannot be injected")
            let payload = try decoder.extractTexturePayload(span: span).get()
            try #require(extent.textureSize == CGSize(width: payload.info.width, height: payload.info.height)
                && extent.imageSize == CGSize(width: payload.info.imageWidth, height: payload.info.imageHeight),
                "Injected asset must match the admitted source extent")
            let upload = try sourceMipUpload(payload, level: level)
            let texture = try await renderer.textureLoader.makeTexture(from: upload, label: "oracle-mip-\(level) \(path)")
            WPEMetalTextureMetadataRegistry.shared.register(
                texture: texture, imageWidth: upload.info.imageWidth, imageHeight: upload.info.imageHeight,
                clampUVs: payload.info.clampUVs, noInterpolation: payload.info.noInterpolation,
                worldWidth: payload.info.width, worldHeight: payload.info.height, sourceMipLevel: level
            )
            renderer.recordLoadedStaticTexture(path: path, layerName: layer.graphLayer.objectName,
                                               candidates: renderer.textureCandidates(for: path), texture: texture)
            evidence.append([
                "reference": path, "resolvedPath": resolved.relativePath, "sourceMipLevel": level,
                "texSHA256": sha256(span.materializedData()), "uploadedBytesSHA256": sha256(upload.mipmaps[0].bytes),
                "originalPhysicalSize": [payload.info.width, payload.info.height],
                "originalImageSize": [payload.info.imageWidth, payload.info.imageHeight],
                "uploadedPhysicalSize": [texture.width, texture.height],
                "uploadedImageSize": [upload.info.imageWidth, upload.info.imageHeight],
            ])
        }
        try #require(!evidence.isEmpty, "No admitted closed static source for mip injection")
        renderer.renderPipeline = pipeline.resolvingSourceMipLevels { reference in
            guard let path = renderer.externalTexturePath(for: reference), injectedPaths.contains(path),
                  let texture = renderer.loadedTextures[path] else { return nil }
            return WPEMetalTextureMetadataRegistry.shared.resolution(for: texture).sourceMipLevel
        }
        renderer.executor.releaseRenderScaleDependentResources()
        renderer.executor.invalidateUniformPlans()
        return evidence
    }

    @Test("Config decode accepts an explicit multi-frame capture")
    func configDecodeAcceptsFrames() throws {
        let json = Data(#"{"corpusRoot": "/tmp/corpus", "frames": 4, "frameStepSeconds": 0.5}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        #expect(config.frames == 4)
        #expect(config.frameStepSeconds == 0.5)
    }

    @Test("Capture properties preserve scalar types per scene and reject unsupported values")
    func configPropertyOverrides() throws {
        let data = Data(#"{"corpusRoot":"/tmp","propertyOverridesByScene":{"2370927443":{"musicnotes":true,"gain":0.5,"label":"night"},"3554161528":{"intro":false}}}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: data)
        #expect(config.propertyOverridesByScene["2370927443"] == ["musicnotes": .bool(true), "gain": .number(0.5), "label": .string("night")])
        #expect(config.propertyOverridesByScene["3554161528"] == ["intro": .bool(false)])
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","propertyOverridesByScene":{"1":{"gain":[1,2]}}}"#.utf8))
        }
    }

    @Test("Property sequence capture is bounded opt-in input injection without oracle ordering override")
    func configPropertySequence() throws {
        let ordinary = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp"}"#.utf8))
        #expect(ordinary.propertySequence.isEmpty)
        let valid = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","propertySequence":[{"stage":0},{"stage":1},{"stage":2},{"stage":0}]}"#.utf8))
        #expect(valid.propertySequence.map { $0["stage"] } == [.number(0), .number(1), .number(2), .number(0)])
        #expect(valid.sequenceWarmupFrames == 8 && valid.sequenceCaptureFrames == 3)
        for extra in [
            #""scriptOrder":"submissionOrder""#,
            #""sequenceWarmupFrames":0"#,
            #""sequenceWarmupFrames":61"#,
            #""sequenceCaptureFrames":1"#,
        ] {
            let json = "{\"corpusRoot\":\"/tmp\",\"propertySequence\":[{\"stage\":0}],\(extra)}"
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
            }
        }
        for values in [#"{}"#, #"{"stage":true}"#, #"{"stage":1.5}"#] {
            let json = "{\"corpusRoot\":\"/tmp\",\"propertySequence\":[\(values)]}"
            #expect(throws: (any Error).self) {
                _ = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
            }
        }
    }

    @Test("Video capture modes are explicit and unknown modes fail")
    func configVideoModes() throws {
        let ordinary = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp"}"#.utf8))
        #expect(ordinary.videoMode == .liveWallClock)
        #expect(ordinary.scriptOrder == .parallelWorkers)
        let pinned = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","videoMode":"firstFrameStill"}"#.utf8))
        #expect(pinned.videoMode == .firstFrameStill)
        let ordered = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","scriptOrder":"submissionOrder"}"#.utf8))
        #expect(ordered.scriptOrder == .submissionOrder)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","scriptOrder":"unknown"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","videoMode":"unknown"}"#.utf8))
        }
    }

    @Test("Authored vertex isolation mode is explicit and typed")
    func configAuthoredVertexIsolationMode() throws {
        let disabled = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","authoredVertexExecution":false}"#.utf8))
        #expect(!disabled.authoredVertexExecution)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","authoredVertexExecution":"false"}"#.utf8))
        }
    }

    @Test("Stage capture is opt-in and rejects malformed configuration")
    func configStages() throws {
        let ordinary = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp"}"#.utf8))
        let staged = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","captureStages":true}"#.utf8))
        #expect(!ordinary.captureStages && staged.captureStages)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(Config.self, from: Data(#"{"corpusRoot":"/tmp","captureStages":"true"}"#.utf8))
        }
    }

    private static func metalValidationConfiguration(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        ["api": environment["MTL_DEBUG_LAYER"] ?? "unspecified",
         "shader": environment["MTL_SHADER_VALIDATION"] ?? "unspecified",
         "proof": "environment-request; verify runtime startup log separately"]
    }

    @Test("Capture records validation requests without assuming a missing flag is disabled")
    func validationRequestsAreExplicit() {
        #expect(Self.metalValidationConfiguration(environment: [:])["api"] == "unspecified")
        let configured = Self.metalValidationConfiguration(environment: ["MTL_DEBUG_LAYER": "1", "MTL_SHADER_VALIDATION": "1"])
        #expect(configured["api"] == "1" && configured["shader"] == "1")
        #expect(Self.metalValidationConfiguration(environment: ["MTL_SHADER_VALIDATION": "0"])["shader"] == "0")
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

    private struct TracedFrame {
        let trace: Data?
        let texture: MTLTexture
    }

    @MainActor
    private static func advanceToTracedFrame(
        renderer: WPEMetalSceneRenderer,
        id: String,
        entryFile: String,
        stage: URL,
        frames: Int,
        stepSeconds: Double,
        perPass: Bool,
        startingFrameOrdinal: Int = 0
    ) throws -> TracedFrame? {
        guard frames > 1 else { return nil }
        var finalFrame: TracedFrame?
        let summary = "\(id) oracle-capture frames=\(frames) step=\(stepSeconds)"
        for offset in 1 ..< frames {
            let index = startingFrameOrdinal + offset
            WPEOracleMode.frameAdvanceSeconds = Double(index) * stepSeconds
            let isLast = offset == frames - 1
            if isLast {
                _ = WPESceneDebugArtifacts.shared.beginSession(workshopID: id, descriptor: summary)
                WPECanonicalTraceRecorder.shared.beginScene(
                    workshopID: id,
                    projectJsonPath: stage.appendingPathComponent(entryFile).path,
                    descriptor: summary,
                    shaderImplementationInventory: renderer.shaderImplementationInventory
                )
            }
            // Drain per frame like WPERenderThread does in-app; without it the loop accumulates every autoreleased Metal object.
            let texture = try autoreleasepool {
                try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            }
            try Self.awaitSceneScriptBatch(renderer)
            guard isLast else { continue }
            if perPass {
                renderer.dumpScenePassesIfRequested(suffix: "-f\(index)")
            }
            let finalTrace = WPECanonicalTraceRecorder.shared.finishFrame(
                outputTexture: texture,
                runtimeUniforms: renderer.lastRuntimeUniforms,
                firstFrameStats: WPEMetalTextureVisualStats.analyze(texture: texture),
                resolutionDiagnostics: renderer.resolutionTracer.snapshot(),
                frameOrdinal: index
            )
            finalFrame = TracedFrame(trace: finalTrace, texture: texture)
            if let image = WPEMetalTextureSnapshotter.shared.snapshot(from: texture) {
                WPESceneDebugArtifacts.shared.recordFirstFrame(image: image)
            }
            WPESceneDebugArtifacts.shared.endSession()
            print("[oracle-capture] [\(id)] advanced to frame \(index) "
                + "(t=\(renderer.lastRuntimeUniforms.map { String(format: "%.4f", $0.time) } ?? "?"))")
        }
        return finalFrame
    }

    @MainActor
    private static func capturePropertySequence(
        renderer: WPEMetalSceneRenderer,
        id: String,
        entryFile: String,
        stage: URL,
        outputRoot: URL,
        config: Config
    ) throws {
        let shared = try #require(renderer.sceneScriptSharedState)
        let owners = shared.layers.sorted { $0.index < $1.index }.compactMap { layer in
            renderer.layerScriptInstances[layer.id].map { (layer.id, $0) }
        }
        let gates = renderer.effectVisibilityScriptInstances.sorted { $0.key < $1.key }
        let gateBindings: [[String: Any]] = renderer.renderPipeline?.layers.flatMap { layer in
            layer.passes.compactMap { prepared -> [String: Any]? in
                guard let gate = prepared.pass.visibilityGate else { return nil }
                return ["gateID": gate.id, "objectID": layer.graphLayer.objectID,
                        "passID": prepared.pass.id, "initialVisible": gate.initialVisible]
            }
        } ?? []
        try #require(!owners.isEmpty || !gates.isEmpty, "Sequence injection requires visible owners or effect gates")
        var ordinal = config.frames - 1
        var records: [[String: Any]] = []
        for (stepIndex, values) in config.propertySequence.enumerated() {
            try awaitSceneScriptBatch(renderer)
            let properties = WPEMetalSceneRenderer.bridgeUserProperties(values)
            var inputReceipts: [[String: Any]] = []
            var familyInputReceipts: [[String: Any]] = []
            for (objectID, instance) in owners {
                let readback = instance.injectOracleUserProperties(properties)
                let receipt = try #require(readback, "Oracle input injection did not complete for \(objectID)")
                try #require(receipt == properties, "Actual VM inputs differ from the requested sequence step")
                inputReceipts.append(["objectID": objectID, "properties": receipt.mapValues(\.jsBridged)])
                familyInputReceipts.append(["family": "visible-owner", "objectID": objectID,
                                            "properties": receipt.mapValues(\.jsBridged)])
            }
            for (gateID, instance) in gates {
                let readback = instance.injectOracleUserProperties(properties)
                let receipt = try #require(readback, "Oracle input injection did not complete for gate \(gateID)")
                try #require(receipt == properties, "Actual gate VM inputs differ from the requested sequence step")
                familyInputReceipts.append(["family": "effect-gate", "gateID": gateID,
                                            "properties": receipt.mapValues(\.jsBridged)])
            }
            _ = try advanceToTracedFrame(
                renderer: renderer, id: id, entryFile: entryFile, stage: stage,
                frames: config.sequenceWarmupFrames + 1, stepSeconds: config.frameStepSeconds,
                perPass: false, startingFrameOrdinal: ordinal
            )
            ordinal += config.sequenceWarmupFrames
            for sampleIndex in 0 ..< config.sequenceCaptureFrames {
                let advanced = try advanceToTracedFrame(
                    renderer: renderer, id: id, entryFile: entryFile, stage: stage,
                    frames: 2, stepSeconds: config.frameStepSeconds,
                    perPass: config.perPass || config.dumpPNGs, startingFrameOrdinal: ordinal
                )
                let frame = try #require(advanced)
                ordinal += 1
                let stem = "\(id)-s\(String(format: "%02d", stepIndex))-n\(sampleIndex)"
                let traceName = stem + ".json"
                let pngName = stem + ".png"
                let traceURL = outputRoot.appendingPathComponent(traceName)
                let pngURL = outputRoot.appendingPathComponent(pngName)
                try #require(!FileManager.default.fileExists(atPath: traceURL.path) && !FileManager.default.fileExists(atPath: pngURL.path))
                let traceData = try #require(frame.trace)
                let traceObject = try JSONSerialization.jsonObject(with: traceData)
                var trace = try #require(traceObject as? [String: Any])
                var capture = trace["capture"] as? [String: Any] ?? [:]
                capture["jobId"] = config.jobId ?? config.label
                capture["frameOrdinal"] = ordinal
                capture["sequenceStepIndex"] = stepIndex
                capture["sequenceSampleIndex"] = sampleIndex
                capture["inputScope"] = "test-only-script-user-property-injection"
                capture["scriptOrder"] = config.scriptOrder.rawValue
                capture["propertyPatchOrSettingsUIValidated"] = false
                capture["pixelProbe"] = try WPEOraclePixelProbe.stageEvidence(
                    stage: "post-color-correction", texture: frame.texture,
                    coordinates: config.pixelProbeCoordinates ?? [[frame.texture.width / 2, frame.texture.height / 2]],
                    commandQueue: renderer.executor.commandQueue, frameOrdinal: ordinal,
                    time: renderer.lastRuntimeUniforms?.time ?? 0
                )
                trace["capture"] = capture
                try JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys]).write(to: traceURL, options: .atomic)
                _ = try validateBuiltinPasses(in: traceURL, sceneID: id)
                let snapshot = WPEMetalTextureSnapshotter.shared.snapshot(from: frame.texture)
                let image = try #require(snapshot)
                let tiff = try #require(image.tiffRepresentation)
                let representation = NSBitmapImageRep(data: tiff)
                let bitmap = try #require(representation)
                let encodedPNG = bitmap.representation(using: .png, properties: [:])
                let png = try #require(encodedPNG)
                try png.write(to: pngURL, options: .atomic)
                let propertyData = try JSONEncoder().encode(values)
                let propertyObject = try JSONSerialization.jsonObject(with: propertyData)
                var record: [String: Any] = [
                    "stepIndex": stepIndex, "sampleIndex": sampleIndex, "frameOrdinal": ordinal,
                    "properties": propertyObject,
                    "inputReceipts": inputReceipts,
                    "familyInputReceipts": familyInputReceipts,
                    "effectGateBindings": gateBindings,
                    "effectGateStates": renderer.liveEffectVisibility,
                    "framePassTopology": ["traceFile": traceName, "jsonPointer": "/passes"],
                    "traceFile": traceName, "pngFile": pngName,
                    "renderOrder": (renderer.lastFramePipeline ?? renderer.renderPipeline)?.layers.map(\.graphLayer.objectID) ?? [],
                    "ownerSourceOrder": owners.map(\.0),
                    "sharedOrderEnabled": shared.isAuthoredLayerOrderingEnabled,
                    "payloadSampling": "after-frame-batch-completion; require-stable-consecutive-captures",
                ]
                if let payload = shared.get("configProbe") as? String {
                    record["configProbe"] = payload
                }
                if let order = renderer.committedAuthoredLayerOrder {
                    record["committedOrder"] = ["objectIDs": order.objectIDs, "revision": order.revision, "hasOverride": order.hasOverride]
                }
                records.append(record)
            }
        }
        let document: [String: Any] = [
            "schema": 1, "sceneID": id, "jobId": config.jobId ?? config.label,
            "sequenceKind": "test-only-script-user-property-injection", "scriptOrder": config.scriptOrder.rawValue,
            "propertyPatchOrSettingsUIValidated": false, "records": records,
        ]
        let outputURL = outputRoot.appendingPathComponent("\(id)-sequence.json")
        try #require(!FileManager.default.fileExists(atPath: outputURL.path))
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: outputURL, options: .atomic)
    }

    private static func layerInputSnapshots(_ renderer: WPEMetalSceneRenderer) -> [[String: Any]] {
        (renderer.lastFramePipeline ?? renderer.renderPipeline)?.layers.map { layer in
            let geometry = layer.graphLayer.geometry
            return ["objectID": layer.graphLayer.objectID, "visible": layer.graphLayer.visible,
                    "alpha": geometry.alpha, "brightness": geometry.brightness,
                    "color": [geometry.color.x, geometry.color.y, geometry.color.z],
                    "origin": [geometry.origin.x, geometry.origin.y, geometry.origin.z],
                    "scale": [geometry.scale.x, geometry.scale.y, geometry.scale.z],
                    "angles": [geometry.angles.x, geometry.angles.y, geometry.angles.z],
                    "scope": "prepared-layer-parameters-not-gpu-uniform-reflection"] as [String: Any]
        } ?? []
    }

    private static func awaitSceneScriptBatch(_ renderer: WPEMetalSceneRenderer) throws {
        // This preserves the product's previous-frame publication semantics while
        // removing queue timing from the next capture frame's input selection.
        let complete = renderer.lastOracleSceneScriptBatchCompletion?.wait(timeout: .now() + 2) ?? true
        try #require(complete, "Oracle SceneScript batch did not finish within the capture deadline")
    }

    private static func latestTrace(forID id: String) -> URL? {
        guard let root = WPESceneDebugArtifacts.rootURL else { return nil }
        let sessions = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
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

    /// `recordNote` writes on the artifacts utility queue, so wait for that bounded handoff instead of
    /// racing `fileExists` straight after `finishFrame`.
    private static func awaitLatestTrace(forID id: String, after: Date = .distantPast) -> URL? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let trace = latestTrace(forID: id),
               let modified = try? trace.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               modified >= after {
                return trace
            }
            usleep(20000)
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
        malformedPassLinks: Int,
        synthesizedPasses: Int,
        missingAuthoredPasses: Int
    ) {
        guard let graph else { return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        var authoredLayers = 0
        var sceneObjectNodes = 0
        var imageDescriptors = 0
        var malformedLayerLinks = 0
        var passes = 0
        var authoredPasses = 0
        var malformedPassLinks = 0
        var synthesizedPasses = 0
        var missingAuthoredPasses = 0
        for layer in graph.layers {
            let authored = layer.authoredJSON
            if authored != .empty {
                authoredLayers += 1
            }
            sceneObjectNodes += authored.sceneObjects.count
            if authored.imageDescriptor != nil {
                imageDescriptors += 1
            }
            if authored.sceneObjects.isEmpty {
                malformedLayerLinks += 1
            }
        }
        for (layer, pass) in graph.layers.flatMap({ layer in layer.passes.map { (layer, $0) } }) {
            passes += 1
            let authored = pass.authoredJSON
            if authored != .empty {
                authoredPasses += 1
            }
            switch passProvenance(materialPath: layer.materialPath, phase: pass.phase, shader: pass.shader, authored: authored) {
            case .authored: break
            case .synthesized: synthesizedPasses += 1
            case .missing: missingAuthoredPasses += 1
            }
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
            malformedPassLinks,
            synthesizedPasses,
            missingAuthoredPasses
        )
    }

    private enum PassProvenance { case authored, synthesized, missing }

    private static func passProvenance(
        materialPath: String?, phase: WPERenderPassPhase, shader: String,
        authored: WPERenderPassAuthoredJSON
    ) -> PassProvenance {
        if authored == .empty {
            // Match the builder's synthetic constructors, not shader.isBuiltin: authored
            // materials also dispatch builtins and must retain their original documents.
            if phase == .material, let path = materialPath {
                let solid = ["models/util/solidlayer.json", "models/util/solidlayer_depthtest.json"].contains(path.lowercased())
                if solid, shader == WPEBuiltinShaderKind.solidLayer.rawValue {
                    return .synthesized
                }
                if WPETextLayerSynthesis.isTargetPath(path), shader == WPETextLayerSynthesis.glyphPassShader {
                    return .synthesized
                }
            }
            if phase == .command(file: WPERenderPassPhase.sceneCopyCommandFile),
               shader == WPERenderPassPhase.sceneCopyCommandFile || shader == WPEBuiltinShaderKind.blendComposite.rawValue {
                return .synthesized
            }
            return .missing
        }
        let materialComplete = authored.materialDocument != nil && authored.materialPass != nil
        let effectComplete = authored.effectDocument != nil && authored.effectPass != nil
        switch phase {
        case .material: return materialComplete ? .authored : .missing
        case .effect: return materialComplete && effectComplete ? .authored : .missing
        case .command: return effectComplete ? .authored : .missing
        }
    }

    @Test("Pass provenance exempts only actual synthesized graph paths")
    func passProvenanceClassification() {
        let solid = WPEBuiltinShaderKind.solidLayer.rawValue
        for path in ["models/util/solidlayer.json", "models/util/solidlayer_depthtest.json"] {
            #expect(Self.passProvenance(materialPath: path, phase: .material, shader: solid, authored: .empty) == .synthesized)
            #expect(Self.passProvenance(materialPath: path, phase: .effect(file: "effects/test.json"), shader: solid, authored: .empty) == .missing)
        }
        #expect(Self.passProvenance(materialPath: "materials/custom.json", phase: .material, shader: solid, authored: .empty) == .missing)
        #expect(Self.passProvenance(materialPath: "models/util/solidlayer.json", phase: .material, shader: "custom", authored: .empty) == .missing)
        #expect(Self.passProvenance(materialPath: WPETextLayerSynthesis.renderPath(objectID: "7", mode: .direct),
                                    phase: .material, shader: WPETextLayerSynthesis.glyphPassShader, authored: .empty) == .synthesized)
        let copy = WPERenderPassPhase.sceneCopyCommandFile
        #expect(Self.passProvenance(materialPath: nil, phase: .command(file: copy), shader: copy, authored: .empty) == .synthesized)
        #expect(Self.passProvenance(materialPath: nil, phase: .command(file: "effects/custom.json"), shader: copy, authored: .empty) == .missing)
        let document = WPESceneJSONValue.object([:])
        let material = WPERenderPassAuthoredJSON(materialDocument: document, materialPass: document)
        #expect(Self.passProvenance(materialPath: "materials/custom.json", phase: .material, shader: solid, authored: material) == .authored)
        #expect(Self.passProvenance(materialPath: nil, phase: .material, shader: solid,
                                    authored: .init(materialDocument: document)) == .missing)
        #expect(Self.passProvenance(materialPath: nil, phase: .effect(file: "effects/test.json"), shader: solid, authored: material) == .missing)
        let effect = WPERenderPassAuthoredJSON(materialDocument: document, materialPass: document, effectDocument: document, effectPass: document)
        #expect(Self.passProvenance(materialPath: nil, phase: .effect(file: "effects/test.json"), shader: solid, authored: effect) == .authored)
        #expect(Self.passProvenance(materialPath: nil, phase: .command(file: "effects/test.json"), shader: "commands/copy",
                                    authored: .init(effectDocument: document, effectPass: document)) == .authored)
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
        let copy = pairs.filter(\.0.copyBackground)
        let opaque = pairs.filter(\.0.opaqueBackground)
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
                if object.copyBackground {
                    copyExamples.append(identity)
                }
                if object.opaqueBackground {
                    opaqueExamples.append(identity)
                }
            }
        }

        print("[text-corpus-evidence] parsedScenes=\(parsedScenes) "
            + "copy=\(copyExamples.count){\(copyExamples.joined(separator: ","))} "
            + "opaque=\(opaqueExamples.count){\(opaqueExamples.joined(separator: ","))}")
        #expect(parsedScenes > 0)
    }
}
#endif
