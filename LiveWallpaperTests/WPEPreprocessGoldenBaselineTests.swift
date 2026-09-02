#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing

/// Opt-in byte-level gate over the GLSL preprocess chain (stage 3
/// `WPERenderPipelineBuilder.preprocess` + stage 4 `WPEShaderPreprocessor`):
/// every non-builtin pass of every local workshop scene is run through
/// `WPEMetalRenderExecutor.makeCompileRequest` and its processed sources are
/// hashed. `capture` writes the baseline; `compare` fails on the first byte
/// that moved. Never added to the fast-app-contract shard.
///
/// Env: `WPE_PREPROCESS_GOLDEN=capture|compare`, `WPE_PREPROCESS_GOLDEN_PATH=<json>`.
/// Corpus/engine-assets discovery mirrors `WPETranspileCoverageCorpusReportTests`.
@Suite("WPE preprocess golden baseline", .serialized)
struct WPEPreprocessGoldenBaselineTests {
    private enum Mode: String {
        case capture, compare
    }

    private struct Entry: Codable, Equatable {
        let vertexSHA256: String
        let fragmentSHA256: String
        let sourceHash: String
    }

    private static var mode: Mode? {
        ProcessInfo.processInfo.environment["WPE_PREPROCESS_GOLDEN"].flatMap(Mode.init(rawValue:))
    }

    private static var baselinePath: String? {
        let path = ProcessInfo.processInfo.environment["WPE_PREPROCESS_GOLDEN_PATH"] ?? ""
        return path.isEmpty ? nil : path
    }

    /// The test host is sandboxed, so `homeDirectoryForCurrentUser` is the app
    /// CONTAINER home; the user's real home comes from the passwd entry.
    private static var homeCandidates: [URL] {
        var homes: [URL] = []
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            homes.append(URL(fileURLWithPath: String(cString: dir), isDirectory: true))
        }
        homes.append(FileManager.default.homeDirectoryForCurrentUser)
        return homes
    }

    private static var corpusRoot: URL? {
        let contentSuffix = "Steam/steamapps/workshop/content/431960"
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["WPE_COVERAGE_CORPUS_ROOT"],
           !explicit.isEmpty {
            candidates.append(URL(fileURLWithPath: explicit, isDirectory: true))
        }
        for home in homeCandidates {
            candidates.append(home.appendingPathComponent(
                "Library/Application Support/\(contentSuffix)", isDirectory: true
            ))
            for bundleID in ["com.loomscreen.pro", "com.loomscreen"] {
                candidates.append(home.appendingPathComponent(
                    "Library/Containers/\(bundleID)/Data/Library/Application Support/\(contentSuffix)",
                    isDirectory: true
                ))
            }
        }
        return candidates.first {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    @MainActor
    private static func engineAssetsRoot(corpusRoot: URL) -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["WPE_COVERAGE_ENGINE_ASSETS_ROOT"],
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let derived = corpusRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("common/wallpaper_engine", isDirectory: true)
        // Same macl-gate caveat as the coverage report: only accept a root the
        // sandboxed host can actually open.
        let probe = derived.appendingPathComponent(
            "assets/models/util/projectlayer.json", isDirectory: false
        )
        if let handle = try? FileHandle(forReadingFrom: probe) {
            try? handle.close()
            return derived
        }
        return WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    @Test(
        "Preprocessed shader sources match the golden baseline byte for byte",
        .enabled(if: mode != nil, "opt-in: set WPE_PREPROCESS_GOLDEN=capture|compare"),
        .enabled(if: mode == nil || baselinePath != nil, "set WPE_PREPROCESS_GOLDEN_PATH"),
        .enabled(if: mode == nil || corpusRoot != nil,
                 "no workshop corpus found (steamcmd content root missing)"),
        .enabled(if: mode == nil || MTLCreateSystemDefaultDevice() != nil, "no Metal device")
    )
    func goldenBaseline() async throws {
        let mode = try #require(Self.mode)
        let baselinePath = try #require(Self.baselinePath)
        let baselineURL = URL(fileURLWithPath: baselinePath)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = try #require(Self.corpusRoot)
        let engineRoot = Self.engineAssetsRoot(corpusRoot: root)
        print("[preprocess-golden] mode=\(mode.rawValue) corpusRoot=\(root.path)")
        print("[preprocess-golden] engineAssetsRoot=\(engineRoot?.path ?? "<nil>")")

        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var entries: [String: Entry] = [:]
        var scenes = 0
        var loadFailed: [String] = []
        for folder in folders {
            let id = folder.lastPathComponent
            guard let project = try? WallpaperEngineProject.read(from: folder),
                  project.type == .scene else { continue }

            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("wpe-golden-\(id)-\(UUID().uuidString)")
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
                    for item in try FileManager.default.contentsOfDirectory(
                        at: folder, includingPropertiesForKeys: nil
                    ) {
                        try FileManager.default.copyItem(
                            at: item, to: stage.appendingPathComponent(item.lastPathComponent)
                        )
                    }
                }
                let projectJSON = folder.appendingPathComponent("project.json")
                let stagedProject = stage.appendingPathComponent("project.json")
                if FileManager.default.fileExists(atPath: projectJSON.path),
                   !FileManager.default.fileExists(atPath: stagedProject.path) {
                    try FileManager.default.copyItem(at: projectJSON, to: stagedProject)
                }
            } catch {
                print("[preprocess-golden] [\(id)] extract failed: \(String(describing: error).prefix(160))")
                loadFailed.append(id)
                continue
            }

            let descriptor = SceneDescriptor(
                workshopID: id,
                cacheRelativePath: "wpe-golden-cache/\(id)",
                entryFile: project.entryFile.isEmpty ? "scene.json" : project.entryFile,
                capabilityTier: .degraded
            )
            do {
                let renderer = try WPEMetalSceneRenderer(
                    descriptor: descriptor,
                    cacheRootURL: stage,
                    dependencyMounts: [],
                    engineAssetsRootURL: engineRoot,
                    frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    device: device,
                    pointerSampler: .fixed(SIMD2<Double>(0.5, 0.5))
                )
                defer { renderer.releaseDebugActorIfNeeded() }
                try await renderer.load()
                let passes = renderer.renderPipeline?.layers.flatMap(\.passes) ?? []
                // Ordinal in the key: pass ids are unique per pipeline in
                // practice, but the ordinal makes a collision impossible to hide.
                for (ordinal, pass) in passes.enumerated() {
                    guard let shader = pass.shader, !shader.isBuiltin else { continue }
                    let key = "\(id)|\(ordinal)|\(pass.id)|\(shader.name)"
                    do {
                        guard let request = try WPEMetalRenderExecutor.makeCompileRequest(
                            for: pass, recordFailure: false
                        ) else { continue }
                        entries[key] = Entry(
                            vertexSHA256: Self.sha256(request.processedVertexSource),
                            fragmentSHA256: Self.sha256(request.processedFragmentSource),
                            sourceHash: request.sourceHash
                        )
                    } catch {
                        // A preprocess failure is part of the behaviour under test.
                        entries[key] = Entry(
                            vertexSHA256: "error",
                            fragmentSHA256: "error",
                            sourceHash: String(describing: error)
                        )
                    }
                }
                scenes += 1
            } catch {
                print("[preprocess-golden] [\(id)] load failed: \(String(describing: error).prefix(160))")
                loadFailed.append(id)
            }
        }

        print("[preprocess-golden] scenes=\(scenes) entries=\(entries.count) "
            + "loadFailed=\(loadFailed.count)\(loadFailed.isEmpty ? "" : " [\(loadFailed.joined(separator: ","))]")")
        #expect(!entries.isEmpty, "no non-builtin pass captured — check corpus root / engine assets")

        switch mode {
        case .capture:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: baselineURL)
            print("[preprocess-golden] wrote \(entries.count) entries to \(baselineURL.path)")
        case .compare:
            let baseline = try JSONDecoder().decode(
                [String: Entry].self, from: Data(contentsOf: baselineURL)
            )
            var differences: [String] = []
            for key in Set(baseline.keys).union(entries.keys).sorted() {
                switch (baseline[key], entries[key]) {
                case (nil, _?):
                    differences.append("\(key): missing from baseline")
                case (_?, nil):
                    differences.append("\(key): missing from current run")
                case let (old?, new?) where old != new:
                    var fields: [String] = []
                    if old.vertexSHA256 != new.vertexSHA256 {
                        fields.append("vertex")
                    }
                    if old.fragmentSHA256 != new.fragmentSHA256 {
                        fields.append("fragment")
                    }
                    if old.sourceHash != new.sourceHash {
                        fields.append("sourceHash")
                    }
                    differences.append("\(key): \(fields.joined(separator: ","))")
                default:
                    break
                }
            }
            print("[preprocess-golden] baseline=\(baseline.count) current=\(entries.count) diff=\(differences.count)")
            for line in differences.prefix(20) {
                print("[preprocess-golden] DIFF \(line)")
            }
            #expect(
                differences.isEmpty,
                Comment(rawValue: "\(differences.count) preprocess outputs moved; first: \(differences.prefix(20).joined(separator: " | "))")
            )
        }
    }
}
#endif
