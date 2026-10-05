import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Wallpaper failure self-check")
struct WallpaperFailureSelfCheckTests {
    private func snapshot(
        code: String = "scene.render_failed",
        missingDependencyIDs: [String] = [],
        missingResources: [WallpaperFailureMissingResource] = []
    ) -> WallpaperFailureSnapshot {
        WallpaperFailureSnapshot(
            id: UUID(), title: "Wallpaper", workshopID: nil, displayName: "Display", stage: .loading,
            cause: WallpaperFailureCause(code: code, reason: "reason"), previousWallpaper: nil,
            timestamp: Date(), diagnostics: "",
            missingDependencyIDs: missingDependencyIDs, missingResources: missingResources
        )
    }

    private func missing(engineAssets: Bool, dependency: String? = nil) -> WallpaperFailureMissingResource {
        WallpaperFailureMissingResource(path: "materials/foo.tex", searchedEngineAssets: engineAssets, dependencyID: dependency)
    }

    private func outcome(_ kind: WallpaperFailureCheckKind, in result: WallpaperFailureSelfCheckResult) -> WallpaperFailureCheckOutcome? {
        result.checks.first { $0.kind == kind }?.outcome
    }

    @Test("A resource never searched in engine assets, with none installed, blames the missing assets")
    func engineAssetsMissing() {
        let result = WallpaperFailureSelfCheck.evaluate(
            snapshot(code: "scene.file_missing", missingResources: [missing(engineAssets: false)]),
            environment: .init(engineAssetsInstalled: false)
        )
        #expect(result.likelyCause == .engineAssetsMissing)
        #expect(result.fix == .configureEngineAssets)
        #expect(outcome(.engineAssetsOutdated, in: result) == nil)
    }

    @Test("A resource searched in installed engine assets and still missing means the assets are outdated")
    func engineAssetsOutdated() {
        let result = WallpaperFailureSelfCheck.evaluate(
            snapshot(missingResources: [missing(engineAssets: true)]),
            environment: .init(engineAssetsInstalled: true)
        )
        #expect(outcome(.engineAssetsMissing, in: result) == .passed)
        #expect(result.likelyCause == .engineAssetsOutdated)
        #expect(result.fix == .configureEngineAssets)
    }

    @Test("A resource missing from a dependency blames the dependency and offers its ID")
    func dependencyMissing() {
        let result = WallpaperFailureSelfCheck.evaluate(
            snapshot(missingResources: [missing(engineAssets: true, dependency: "12345")]),
            environment: .init(engineAssetsInstalled: true)
        )
        #expect(result.likelyCause == .dependenciesMissing)
        #expect(result.fix == .copyDependencyIDs(["12345"]))
    }

    @Test("Snapshot dependency IDs are used when the environment did not re-probe")
    func snapshotDependencyIDs() {
        let result = WallpaperFailureSelfCheck.evaluate(snapshot(missingDependencyIDs: ["1", "2"]), environment: .init())
        #expect(result.likelyCause == .dependenciesMissing)
        #expect(result.fix == .copyDependencyIDs(["1", "2"]))

        let reprobed = WallpaperFailureSelfCheck.evaluate(
            snapshot(missingDependencyIDs: ["1", "2"]), environment: .init(currentMissingDependencyIDs: [])
        )
        #expect(outcome(.dependenciesMissing, in: reprobed) == .passed)
        #expect(reprobed.likelyCause == nil)
    }

    @Test("An unreachable source asks to choose the source again")
    func sourceUnreachable() {
        let result = WallpaperFailureSelfCheck.evaluate(snapshot(), environment: .init(sourceReachable: false))
        #expect(result.likelyCause == .sourceUnreachable)
        #expect(result.fix == .chooseSource)
    }

    @Test("A file-missing code without a lookup record leaves the engine-assets check unknown")
    func fileMissingWithoutRecordIsUnknown() {
        let result = WallpaperFailureSelfCheck.evaluate(
            snapshot(code: "scene.file_missing"), environment: .init(engineAssetsInstalled: false)
        )
        #expect(outcome(.engineAssetsMissing, in: result) == .unknown)
        #expect(result.likelyCause == nil)
        #expect(result.fix == nil)
        #expect(result.reportLines == ["Self-check: engineAssetsMissing: unknown"])
    }

    @Test("When every applicable check passes there is no likely cause")
    func allPassed() {
        let result = WallpaperFailureSelfCheck.evaluate(
            snapshot(code: "scene.file_missing"),
            environment: .init(engineAssetsInstalled: true, sourceReachable: true, currentMissingDependencyIDs: [])
        )
        #expect(result.checks.map(\.kind) == [.engineAssetsMissing, .engineAssetsOutdated, .dependenciesMissing, .sourceUnreachable])
        #expect(result.likelyCause == nil)
        #expect(result.fix == nil)
        #expect(result.passedCount == result.checks.count)
    }

    @Test("A Windows-only plugin is reported without a fix")
    func windowsOnly() {
        let result = WallpaperFailureSelfCheck.evaluate(snapshot(code: "scene.windows_plugin"), environment: .init())
        #expect(result.checks == [WallpaperFailureCheck(kind: .windowsOnly, outcome: .failed)])
        #expect(result.likelyCause == .windowsOnly)
        #expect(result.fix == nil)
        #expect(result.reportLines == ["Self-check: windowsOnly: failed"])
    }

    @Test("Metal capability codes are reported without a fix")
    func metalUnsupported() {
        for code in ["scene.metal_unsupported", "texture.metal_format", "texture.metal_compression", "texture.metal_unavailable"] {
            let result = WallpaperFailureSelfCheck.evaluate(snapshot(code: code), environment: .init())
            #expect(result.likelyCause == .metalUnsupported, "\(code)")
            #expect(result.fix == nil, "\(code)")
        }
    }

    @Test("A proven fatal cause outranks a failed environment check and offers no fix")
    func fatalCauseOutranksEnvironment() {
        for (code, cause) in [("scene.windows_plugin", WallpaperFailureCheckKind.windowsOnly), ("texture.metal_format", .metalUnsupported)] {
            let result = WallpaperFailureSelfCheck.evaluate(snapshot(code: code), environment: .init(sourceReachable: false))
            #expect(result.likelyCause == cause, "\(code)")
            #expect(result.fix == nil, "\(code)")
            #expect(outcome(.sourceUnreachable, in: result) == .failed, "\(code)")
            #expect(result.reportLines.contains("Self-check: sourceUnreachable: failed"), "\(code)")
        }
    }

    @Test("A fatal code without its own check names no environment failure as the cause")
    func fatalWithoutCheckHasNoEnvironmentCause() {
        let result = WallpaperFailureSelfCheck.evaluate(snapshot(code: "scene.unsafe_path"), environment: .init(sourceReachable: false))
        #expect(result.likelyCause == nil)
        #expect(result.fix == nil)
        #expect(outcome(.sourceUnreachable, in: result) == .failed)
    }

    #if !LITE_BUILD
    @Test("Missed refs carry whether engine assets were searched and the first dependency searched")
    func resolutionSnapshotMissingResources() {
        let missedPlain = WPEResolutionEvent(
            ref: "a.tex",
            attempts: [.init(origin: .scene, outcome: .fileMissing), .init(origin: .builtin, outcome: .fileMissing)],
            finalOutcome: .fileMissing
        )
        let missedEverywhere = WPEResolutionEvent(
            ref: "b.tex",
            attempts: [
                .init(origin: .scene, outcome: .fileMissing), .init(origin: .dependency("111"), outcome: .fileMissing),
                .init(origin: .dependency("222"), outcome: .fileMissing), .init(origin: .engineAssets, outcome: .fileMissing),
            ],
            finalOutcome: .fileMissing
        )
        let resolved = WPEResolutionEvent(ref: "c.tex", attempts: [.init(origin: .scene, outcome: .resolved)], finalOutcome: .resolved)
        let resources = WPEResolutionDiagnosticsSnapshot(events: [missedPlain, missedEverywhere, resolved]).failureMissingResources
        #expect(resources == [
            WallpaperFailureMissingResource(path: "a.tex", searchedEngineAssets: false, dependencyID: nil),
            WallpaperFailureMissingResource(path: "b.tex", searchedEngineAssets: true, dependencyID: "111"),
        ])

        let many = (0 ..< 30).map {
            WPEResolutionEvent(ref: "m\($0).tex", attempts: [.init(origin: .scene, outcome: .fileMissing)], finalOutcome: .fileMissing)
        }
        #expect(WPEResolutionDiagnosticsSnapshot(events: many).failureMissingResources.count == 20)

        let repeated = WPEResolutionDiagnosticsSnapshot(events: [missedPlain, missedPlain] + many).failureMissingResources
        #expect(repeated.count == 20)
        #expect(repeated.filter { $0.path == "a.tex" }.count == 1)
    }

    @Test("A decode or format error is not recorded as a missing resource")
    func otherErrorIsNotMissing() {
        let missed = WPEResolutionEvent(ref: "a.tex", attempts: [.init(origin: .scene, outcome: .fileMissing)], finalOutcome: .fileMissing)
        let undecodable = WPEResolutionEvent(
            ref: "b.tex", attempts: [.init(origin: .scene, outcome: .otherError("decode"))], finalOutcome: .otherError("decode")
        )
        let resources = WPEResolutionDiagnosticsSnapshot(events: [missed, undecodable]).failureMissingResources
        #expect(resources == [WallpaperFailureMissingResource(path: "a.tex", searchedEngineAssets: false, dependencyID: nil)])
    }

    @Test("A stale but resolvable source bookmark is reachable; a deleted folder is not")
    func sourceReachabilityToleratesStaleBookmark() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "selfcheck-\(UUID().uuidString)", directoryHint: .isDirectory)
        let original = root.appending(path: "original", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bookmark = try DirectoryBookmarks.createReadOnlyBookmark(for: original)
        #expect(WallpaperFailureSelfCheck.sourceReachability(bookmark: bookmark) == true)

        let renamed = root.appending(path: "renamed", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: original, to: renamed)
        #expect(try DirectoryBookmarks.resolveDirectoryBookmark(bookmark).isStale)
        #expect(WallpaperFailureSelfCheck.sourceReachability(bookmark: bookmark) == true)

        try FileManager.default.removeItem(at: renamed)
        #expect(WallpaperFailureSelfCheck.sourceReachability(bookmark: bookmark) == false)
    }
    #endif
}
