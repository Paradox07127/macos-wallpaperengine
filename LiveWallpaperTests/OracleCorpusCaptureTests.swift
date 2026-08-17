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

        private enum CodingKeys: String, CodingKey {
            case corpusRoot, engineAssetsRoot, label, scenes, perPass, dumpPNGs, memoryAuditLog, frames, frameStepSeconds
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
        if let explicitPath = ProcessInfo.processInfo.environment["WPE_ORACLE_CAPTURE_CONFIG"],
           !explicitPath.isEmpty {
            let explicitURL = URL(fileURLWithPath: explicitPath)
            return FileManager.default.fileExists(atPath: explicitURL.path) ? explicitURL : nil
        }
        let temporaryURL = URL(
            fileURLWithPath: "/private/tmp/livewallpaper-oracle-evidence.json"
        )
        if FileManager.default.fileExists(atPath: temporaryURL.path) {
            return temporaryURL
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        let configURL = base
            .appendingPathComponent("LiveWallpaper")
            .appendingPathComponent("oracle-capture.json")
        return FileManager.default.fileExists(atPath: configURL.path) ? configURL : nil
    }

    @MainActor
    @Test(
        "Capture oracle traces for a scene corpus (opt-in via container config file)",
        .enabled(if: captureConfigURL != nil)
    )
    func captureCorpus() async throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appendingPathComponent("LiveWallpaper")
        let configURL = try #require(Self.captureConfigURL)
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(Config.self, from: data)
        try #require(!config.corpusRoot.isEmpty, "oracle-capture.json corpusRoot must not be empty")
        let root = URL(fileURLWithPath: config.corpusRoot)
        let outDir = base.appendingPathComponent("oracle-out").appendingPathComponent(config.label)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let filter = config.scenes.map(Set.init)
        print("[oracle-capture] config: corpusRoot=\(config.corpusRoot) label=\(config.label) "
              + "scenes=\(config.scenes ?? ["<all>"]) frames=\(config.frames) step=\(config.frameStepSeconds)")

        WPEOracleMode.testingOverride = true
        WPESceneDebugArtifacts.shared.setEnabledForTesting(true)
        if config.perPass {
            UserDefaults.standard.set(true, forKey: "WPEOraclePerPassHashes")
        }
        if config.memoryAuditLog {
            UserDefaults.standard.set(true, forKey: "WPEMemoryAuditLog")
        }
        defer {
            WPEOracleMode.testingOverride = nil
            WPEOracleMode.frameAdvanceSeconds = 0
            WPESceneDebugArtifacts.shared.setEnabledForTesting(nil)
            if config.perPass {
                UserDefaults.standard.removeObject(forKey: "WPEOraclePerPassHashes")
            }
            if config.dumpPNGs {
                UserDefaults.standard.removeObject(forKey: "WPEDumpScenePasses")
            }
            if config.memoryAuditLog {
                UserDefaults.standard.removeObject(forKey: "WPEMemoryAuditLog")
            }
        }

        let device = try #require(MTLCreateSystemDefaultDevice())
        let engineAssetsRoot = config.engineAssetsRoot.map { URL(fileURLWithPath: $0) }
            ?? WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
        print("[oracle-capture] engineAssetsRoot=\(engineAssetsRoot?.path ?? "<nil>")")

        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var captured = 0, skipped = 0, failed = 0, builtinPassesCaptured = 0
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

            if config.dumpPNGs {
                UserDefaults.standard.set(id, forKey: "WPEDumpScenePasses")
            }
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
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    device: device,
                    // WPE's captured frame carries its own pointer; centring ours
                    // shifts every mouse-driven parallax/effect uniform.
                    pointerSampler: .fixed(Self.replayPointer())
                )
                let renderActor = WPEDisplayRenderActor(backing: .main)
                await renderActor.adopt(WPERendererHandoff(renderer: renderer).renderer)
                try await renderActor.load()
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
                if let trace = Self.awaitLatestTrace(forID: id) {
                    let builtinSummary = try Self.validateBuiltinPasses(in: trace, sceneID: id)
                    builtinPassesCaptured += builtinSummary.count
                    let dest = outDir.appendingPathComponent("\(id).json")
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.copyItem(at: trace, to: dest)
                    captured += 1
                    print("[oracle-capture] [\(id)] ✅ trace → \(dest.lastPathComponent)")
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
        #expect(captured > 0, "no scene produced a trace — check corpus root / engine assets")
        #expect(builtinPassesCaptured > 0, "captured traces contained no hand-authored Metal builtin pass")
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
                    descriptor: summary
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
    private static func awaitLatestTrace(forID id: String) -> URL? {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if let trace = latestTrace(forID: id) { return trace }
            usleep(20_000)
        } while Date() < deadline
        return latestTrace(forID: id)
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
    private static let configURL = URL(
        fileURLWithPath: "/private/tmp/livewallpaper-oracle-evidence.json"
    )
    private static var configExists: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    @Test(
        "Scan packaged scene JSON for real copy/opaque text examples",
        .enabled(if: configExists)
    )
    func scanTextBackgroundModes() throws {
        let config = try JSONDecoder().decode(
            RootConfig.self,
            from: Data(contentsOf: Self.configURL)
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
