#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE transpile coverage aggregator")
struct WPETranspileCoverageAggregatorTests {
    private static let sceneA = WPESceneCoverageRecord(
        sceneID: "111",
        passCounts: [.officialSource: 2, .nativeApproximation: 1],
        unclassifiedPassCount: 1,
        customShaderCompiledCount: 2,
        customShaderFailedCount: 0,
        customShaderUntriedCount: 0
    )
    private static let sceneB = WPESceneCoverageRecord(
        sceneID: "222",
        passCounts: [.officialSource: 1, .copyFallback: 1, .unsupportedMetadataOnly: 1],
        unclassifiedPassCount: 0,
        customShaderCompiledCount: 1,
        customShaderFailedCount: 1,
        customShaderUntriedCount: 2
    )

    @Test("Summarize sums per-classification counts across scenes")
    func summarizeSumsCounts() {
        let summary = WPETranspileCoverageAggregator.summarize([Self.sceneA, Self.sceneB])
        #expect(summary.sceneCount == 2)
        #expect(summary.passCounts[.officialSource] == 3)
        #expect(summary.passCounts[.nativeApproximation] == 1)
        #expect(summary.passCounts[.copyFallback] == 1)
        #expect(summary.passCounts[.unsupportedMetadataOnly] == 1)
        #expect(summary.unclassifiedPassCount == 1)
        #expect(summary.customShaderCompiledCount == 3)
        #expect(summary.customShaderFailedCount == 1)
        #expect(summary.customShaderUntriedCount == 2)
        #expect(summary.totalUnits == 7)
    }

    /// Mutation-sensitive: the share denominator is ALL counting units including
    /// unclassified passes (7 here). Dropping unclassified from the denominator
    /// (6) would yield 0.5 and fail both assertions.
    @Test("Share uses all counting units as the denominator")
    func shareDenominatorIncludesUnclassified() {
        let summary = WPETranspileCoverageAggregator.summarize([Self.sceneA, Self.sceneB])
        #expect(abs(summary.share(of: .officialSource) - 3.0 / 7.0) < 1e-12)
        #expect(abs(summary.unclassifiedShare - 1.0 / 7.0) < 1e-12)
    }

    /// Mutation-sensitive: untried compiles must stay out of the success-rate
    /// denominator. Including them (3+1+2=6) would yield 0.5, not 0.75.
    @Test("Compile success rate excludes untried passes")
    func compileSuccessRateExcludesUntried() throws {
        let summary = WPETranspileCoverageAggregator.summarize([Self.sceneA, Self.sceneB])
        let rate = try #require(summary.customShaderCompileSuccessRate)
        #expect(abs(rate - 0.75) < 1e-12)
    }

    @Test("Compile success rate is nil when nothing was attempted")
    func compileSuccessRateNilWithoutAttempts() {
        let record = WPESceneCoverageRecord(
            sceneID: "333",
            passCounts: [.nativeApproximation: 2],
            unclassifiedPassCount: 0,
            customShaderCompiledCount: 0,
            customShaderFailedCount: 0,
            customShaderUntriedCount: 1
        )
        let summary = WPETranspileCoverageAggregator.summarize([record])
        #expect(summary.customShaderCompileSuccessRate == nil)
        let table = WPETranspileCoverageAggregator.table(records: [record])
        #expect(table.contains("n/a (no custom shader compile attempted)"))
    }

    @Test("Empty corpus summarizes to zeros without dividing by zero")
    func emptyCorpus() {
        let summary = WPETranspileCoverageAggregator.summarize([])
        #expect(summary.sceneCount == 0)
        #expect(summary.totalUnits == 0)
        #expect(summary.share(of: .officialSource) == 0)
        #expect(summary.unclassifiedShare == 0)
        #expect(summary.customShaderCompileSuccessRate == nil)
    }

    @Test("Table renders one row per scene, a totals row, and exact percentages")
    func tableRendersRowsAndShares() {
        let table = WPETranspileCoverageAggregator.table(records: [Self.sceneA, Self.sceneB])
        let lines = table.components(separatedBy: "\n")
        // header + 2 scene rows + totals + shares + success line
        #expect(lines.count == 6)
        #expect(lines[0].hasPrefix("scene"))
        #expect(lines[1].hasPrefix("111"))
        #expect(lines[2].hasPrefix("222"))
        #expect(lines[3].hasPrefix("TOTAL(2)"))
        // 3/7 = 42.9%, 1/7 = 14.3% — a wrong denominator changes these strings.
        #expect(lines[4].contains("official-source 42.9%"))
        #expect(lines[4].contains("unclassified 14.3%"))
        #expect(lines[5].contains("75.0% (3/4, untried 2)"))
    }
}

/// Opt-in Metal-bound corpus runner: renders every local workshop scene once and
/// prints the first transpile-coverage report (per-scene pass classifications +
/// custom shader compile outcomes). Never added to the fast-app-contract shard.
@Suite("WPE transpile coverage corpus report", .serialized)
struct WPETranspileCoverageCorpusReportTests {
    private static var reportRequested: Bool {
        ProcessInfo.processInfo.environment["WPE_COVERAGE_REPORT"] == "1"
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

    /// Explicit env override first, then this Mac's steamcmd content roots
    /// (host-level Steam, then the app containers' Steam).
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

    /// The engine-assets root next to the corpus (`steamapps/common/wallpaper_engine`),
    /// or an explicit override; without it every builtin-model scene fails to load.
    @MainActor
    private static func engineAssetsRoot(corpusRoot: URL) -> URL? {
        if let explicit = ProcessInfo.processInfo.environment["WPE_COVERAGE_ENGINE_ASSETS_ROOT"],
           !explicit.isEmpty {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        let derived = corpusRoot // .../steamapps/workshop/content/431960
            .deletingLastPathComponent() // content
            .deletingLastPathComponent() // workshop
            .deletingLastPathComponent() // steamapps
            .appendingPathComponent("common/wallpaper_engine", isDirectory: true)
        // `fileExists` is not enough: the host Steam `wallpaper_engine` dir can
        // carry a com.apple.macl gate that lets the sandboxed test host stat it
        // but not read it (measured: 28/52 scenes died on fileMissing for files
        // that exist). Only accept a root we can actually open.
        let probe = derived.appendingPathComponent(
            "assets/models/util/projectlayer.json", isDirectory: false
        )
        if let handle = try? FileHandle(forReadingFrom: probe) {
            try? handle.close()
            return derived
        }
        return WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot()
    }

    @MainActor
    @Test(
        "Aggregate transpile coverage over the local workshop corpus",
        .enabled(if: reportRequested, "opt-in: set WPE_COVERAGE_REPORT=1"),
        .enabled(if: !reportRequested || corpusRoot != nil,
                 "no workshop corpus found (steamcmd content root missing)"),
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
                // One rendered frame drives the executor's per-pass compile
                // attempts; drain autoreleased Metal objects per frame.
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

    /// Classification comes from each prepared pass's shader program; a pass with
    /// no program is intentionally unclassified (text and other separately
    /// dispatched paths). `unsupported-metadata-only` never becomes a prepared
    /// pass, so it is counted from the renderer's implementation inventory.
    /// Compile outcomes are read per pass from the executor's own maps — NOT
    /// `WPEShaderErrorSink`, which dedupes by shader name and so cannot count
    /// passes even though it is scoped to one executor's current scene.
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
            if executor.compiledShaderResultByPassID[pass.id] != nil {
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
