#if !LITE_BUILD
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE preprocess golden baseline", .serialized)
struct WPEPreprocessGoldenBaselineTests {
    private enum Mode: String {
        case capture, compare, dump
    }

    private struct Entry: Codable, Equatable {
        let vertexSHA256: String
        let fragmentSHA256: String
        let sourceHash: String
    }

    private struct DumpEntry: Encodable {
        let sceneID: String
        let passOrdinal: Int
        let passID: String
        let shaderName: String
        let comboValues: [String: Int]
        let textureBindings: [Int: String]
        let vertexPath: String?
        let fragmentPath: String?
        let preprocessError: String?
    }

    private struct DumpIndex: Encodable {
        let schemaVersion = 1
        let loadedScenes: [String]
        let loadFailed: [String]
        let entries: [DumpEntry]
    }

    private static var mode: Mode? {
        guard ProcessInfo.processInfo.environment["LIVEWALLPAPER_EXTERNAL_FIXTURES"] == "1" else { return nil }
        return ProcessInfo.processInfo.environment["WPE_PREPROCESS_GOLDEN"].flatMap(Mode.init(rawValue:))
    }

    private static var baselinePath: String? {
        TestScratch.externalFixtureURL(pathKey: "WPE_PREPROCESS_GOLDEN_PATH")?.path
    }

    private static var dumpDirectory: URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_PREPROCESS_DUMP_DIR")
    }

    private static var corpusRoot: URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_COVERAGE_CORPUS_ROOT")
    }

    @MainActor
    private static func engineAssetsRoot(corpusRoot _: URL) -> URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_COVERAGE_ENGINE_ASSETS_ROOT")
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    @Test(
        "Preprocessed shader sources match the golden baseline byte for byte",
        .enabled(if: mode != nil, "opt-in: set WPE_PREPROCESS_GOLDEN=capture|compare|dump"),
        .enabled(if: mode == nil || mode == .dump || baselinePath != nil, "set WPE_PREPROCESS_GOLDEN_PATH"),
        .enabled(if: mode != .dump || dumpDirectory != nil, "set WPE_PREPROCESS_DUMP_DIR"),
        .enabled(if: mode == nil || corpusRoot != nil,
                 "set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_COVERAGE_CORPUS_ROOT"),
        .enabled(if: mode == nil || MTLCreateSystemDefaultDevice() != nil, "no Metal device")
    )
    func goldenBaseline() async throws {
        let mode = try #require(Self.mode)
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
        var dumpEntries: [DumpEntry] = []
        var dumpSources: [String: String] = [:]
        var loadedScenes: [String] = []
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
                        if mode == .dump {
                            let vertexPath = "\(id)-\(ordinal).vert"
                            let fragmentPath = "\(id)-\(ordinal).frag"
                            dumpSources[vertexPath] = request.processedVertexSource
                            dumpSources[fragmentPath] = request.processedFragmentSource
                            dumpEntries.append(DumpEntry(
                                sceneID: id, passOrdinal: ordinal, passID: pass.id,
                                shaderName: request.shaderName, comboValues: request.comboValues,
                                textureBindings: request.textureBindings,
                                vertexPath: vertexPath, fragmentPath: fragmentPath, preprocessError: nil
                            ))
                        }
                    } catch {
                        // A preprocess failure is part of the behaviour under test.
                        entries[key] = Entry(
                            vertexSHA256: "error",
                            fragmentSHA256: "error",
                            sourceHash: String(describing: error)
                        )
                        if mode == .dump {
                            dumpEntries.append(DumpEntry(
                                sceneID: id, passOrdinal: ordinal, passID: pass.id,
                                shaderName: shader.name, comboValues: pass.comboValues,
                                textureBindings: pass.textureBindings.mapValues { String(describing: $0) },
                                vertexPath: nil, fragmentPath: nil, preprocessError: String(describing: error)
                            ))
                        }
                    }
                }
                scenes += 1
                loadedScenes.append(id)
            } catch {
                print("[preprocess-golden] [\(id)] load failed: \(String(describing: error).prefix(160))")
                loadFailed.append(id)
            }
        }

        print("[preprocess-golden] scenes=\(scenes) entries=\(entries.count) "
            + "loadFailed=\(loadFailed.count)\(loadFailed.isEmpty ? "" : " [\(loadFailed.joined(separator: ","))]")")
        #expect(!entries.isEmpty, "no non-builtin pass captured — check corpus root / engine assets")

        switch mode {
        case .dump:
            let directory = try #require(Self.dumpDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (path, source) in dumpSources {
                try Data(source.utf8).write(to: directory.appendingPathComponent(path))
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(DumpIndex(
                loadedScenes: loadedScenes, loadFailed: loadFailed, entries: dumpEntries
            )).write(to: directory.appendingPathComponent("index.json"))
            print("[preprocess-golden] dumped \(dumpEntries.count) entries to \(directory.path)")
        case .capture:
            let baselineURL = try URL(fileURLWithPath: #require(Self.baselinePath))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: baselineURL)
            print("[preprocess-golden] wrote \(entries.count) entries to \(baselineURL.path)")
        case .compare:
            let baselineURL = try URL(fileURLWithPath: #require(Self.baselinePath))
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
