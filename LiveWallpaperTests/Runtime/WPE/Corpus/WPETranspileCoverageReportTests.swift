#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE transpile coverage corpus report", .serialized)
struct WPETranspileCoverageCorpusReportTests {
    private static var reportRequested: Bool {
        ProcessInfo.processInfo.environment["LIVEWALLPAPER_EXTERNAL_FIXTURES"] == "1"
            && ProcessInfo.processInfo.environment["WPE_COVERAGE_REPORT"] == "1"
    }

    private static var corpusRoot: URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_COVERAGE_CORPUS_ROOT")
    }

    @MainActor
    private static func engineAssetsRoot(corpusRoot _: URL) -> URL? {
        TestScratch.externalFixtureURL(pathKey: "WPE_COVERAGE_ENGINE_ASSETS_ROOT")
    }

    @MainActor
    @Test(
        "Aggregate transpile coverage over the local workshop corpus",
        .enabled(if: reportRequested, "opt-in: set WPE_COVERAGE_REPORT=1"),
        .enabled(if: !reportRequested || corpusRoot != nil,
                 "set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_COVERAGE_CORPUS_ROOT"),
        .enabled(if: !reportRequested || MTLCreateSystemDefaultDevice() != nil,
                 "no Metal device")
    )
    func corpusCoverageReport() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = try #require(Self.corpusRoot)
        let engineRoot = Self.engineAssetsRoot(corpusRoot: root)
        print("[coverage-report] corpusRoot=\(root.path)")
        print("[coverage-report] engineAssetsRoot=\(engineRoot?.path ?? "<nil>")")

        let folders = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var records: [WPESceneCoverageRecord] = []
        var skippedNonScene = 0
        var loadFailed: [String] = []
        for folder in folders {
            let id = folder.lastPathComponent
            guard let project = try? WallpaperEngineProject.read(from: folder),
                  project.type == .scene else {
                skippedNonScene += 1
                continue
            }

            let stage = FileManager.default.temporaryDirectory
                .appendingPathComponent("wpe-coverage-\(id)-\(UUID().uuidString)")
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
                // project.json lives beside scene.pkg and carries user-property
                // defaults; without it uniforms fall back to baked literals.
                let projectJSON = folder.appendingPathComponent("project.json")
                let stagedProject = stage.appendingPathComponent("project.json")
                if FileManager.default.fileExists(atPath: projectJSON.path),
                   !FileManager.default.fileExists(atPath: stagedProject.path) {
                    try FileManager.default.copyItem(at: projectJSON, to: stagedProject)
                }
            } catch {
                print("[coverage-report] [\(id)] extract failed: \(String(describing: error).prefix(160))")
                loadFailed.append(id)
                continue
            }

            let descriptor = SceneDescriptor(
                workshopID: id,
                cacheRelativePath: "wpe-coverage-cache/\(id)",
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
                // One rendered frame is what drives the executor's per-pass compile attempts.
                _ = try autoreleasepool {
                    try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
                }
                records.append(Self.collectRecord(sceneID: id, renderer: renderer))
            } catch {
                print("[coverage-report] [\(id)] load/render failed: \(String(describing: error).prefix(160))")
                loadFailed.append(id)
            }
        }

        print("=== transpile coverage report ===")
        print(WPETranspileCoverageAggregator.table(records: records))
        print("=== scenes: rendered=\(records.count) nonScene=\(skippedNonScene) "
            + "loadFailed=\(loadFailed.count)\(loadFailed.isEmpty ? "" : " [\(loadFailed.joined(separator: ","))]") ===")

        #expect(!records.isEmpty, "no scene rendered — check corpus root / engine assets")
        let summary = WPETranspileCoverageAggregator.summarize(records)
        #expect(summary.totalUnits > 0, "rendered scenes exposed no classified pass")
    }

    /// `unsupported-metadata-only` never becomes a prepared pass, so it is counted from the implementation inventory.
    /// Compile outcomes must come from the executor's per-pass maps, never `WPEShaderErrorSink` — it dedupes by shader name.
    @MainActor
    private static func collectRecord(
        sceneID: String,
        renderer: WPEMetalSceneRenderer
    ) -> WPESceneCoverageRecord {
        let passes = renderer.renderPipeline?.layers.flatMap(\.passes) ?? []
        var counts: [WPEShaderExecutionClassification: Int] = [:]
        var unclassified = 0
        var compiled = 0
        var failed = 0
        var untried = 0
        let executor = renderer.executor
        for pass in passes {
            guard let shader = pass.shader else {
                unclassified += 1
                continue
            }
            counts[shader.executionClassification, default: 0] += 1
            guard shader.executionClassification == .officialSource else { continue }
            if executor.compiledShaderResultByPassID[WPEMetalRenderExecutor.compiledShaderEntryKey(for: pass)] != nil {
                compiled += 1
            } else if executor.untranslatableShaderReasonByPassID[pass.id] != nil {
                failed += 1
            } else {
                untried += 1
            }
        }
        let metadataOnly = renderer.shaderImplementationInventory
            .filter { $0.classification == .unsupportedMetadataOnly }
            .count
        if metadataOnly > 0 {
            counts[.unsupportedMetadataOnly, default: 0] += metadataOnly
        }
        return WPESceneCoverageRecord(
            sceneID: sceneID,
            passCounts: counts,
            unclassifiedPassCount: unclassified,
            customShaderCompiledCount: compiled,
            customShaderFailedCount: failed,
            customShaderUntriedCount: untried
        )
    }
}
#endif
