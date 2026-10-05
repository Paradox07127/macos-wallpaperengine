import Foundation

struct WallpaperFailureSelfCheckEnvironment: Equatable, Sendable {
    /// nil = not applicable (Lite, or the wpeImport feature is off).
    var engineAssetsInstalled: Bool?
    /// nil = no source bookmark, or not probed.
    var sourceReachable: Bool?
    /// nil = not re-probed; the snapshot's list is used instead.
    var currentMissingDependencyIDs: [String]?
}

enum WallpaperFailureCheckKind: CaseIterable {
    case engineAssetsMissing, engineAssetsOutdated, dependenciesMissing, sourceUnreachable, windowsOnly, metalUnsupported
}

enum WallpaperFailureCheckOutcome {
    case passed, failed, unknown
}

struct WallpaperFailureCheck: Equatable {
    let kind: WallpaperFailureCheckKind
    let outcome: WallpaperFailureCheckOutcome
}

struct WallpaperFailureSelfCheckResult: Equatable {
    /// Applicable checks only, in `WallpaperFailureCheckKind.allCases` order.
    let checks: [WallpaperFailureCheck]
    var likelyCause: WallpaperFailureCheckKind?
    var passedCount: Int
    /// nil = no self-check-specific fix; the caller keeps the cause's own recovery.
    var fix: WallpaperFailureRecovery?
    var reportLines: [String]
}

enum WallpaperFailureSelfCheck {
    private static let fileMissingCodes: Set<String> = ["graph.file_missing", "scene.file_missing"]
    private static let metalCodes: Set<String> = [
        "scene.metal_unsupported", "texture.metal_format", "texture.metal_compression", "texture.metal_unavailable",
    ]

    static func evaluate(_ snapshot: WallpaperFailureSnapshot, environment: WallpaperFailureSelfCheckEnvironment) -> WallpaperFailureSelfCheckResult {
        let code = snapshot.cause.code
        let resources = snapshot.missingResources
        let unscopedMisses = resources.filter { $0.dependencyID == nil }
        var checks: [WallpaperFailureCheck] = []

        if let installed = environment.engineAssetsInstalled, !resources.isEmpty || fileMissingCodes.contains(code) {
            let missingOutcome: WallpaperFailureCheckOutcome = if !installed, unscopedMisses.contains(where: { !$0.searchedEngineAssets }) {
                .failed
            } else if !installed, resources.isEmpty {
                // Import-stage failures carry only the code, never a lookup record.
                .unknown
            } else {
                .passed
            }
            checks.append(WallpaperFailureCheck(kind: .engineAssetsMissing, outcome: missingOutcome))
            if installed {
                let outdated = unscopedMisses.contains { $0.searchedEngineAssets }
                checks.append(WallpaperFailureCheck(kind: .engineAssetsOutdated, outcome: outdated ? .failed : .passed))
            }
        }

        var dependencyIDs: [String] = []
        for id in (environment.currentMissingDependencyIDs ?? snapshot.missingDependencyIDs) + resources.compactMap(\.dependencyID)
            where !dependencyIDs.contains(id) {
            dependencyIDs.append(id)
        }
        if !snapshot.missingDependencyIDs.isEmpty || resources.contains(where: { $0.dependencyID != nil })
            || environment.currentMissingDependencyIDs != nil {
            checks.append(WallpaperFailureCheck(kind: .dependenciesMissing, outcome: dependencyIDs.isEmpty ? .passed : .failed))
        }

        if let reachable = environment.sourceReachable {
            checks.append(WallpaperFailureCheck(kind: .sourceUnreachable, outcome: reachable ? .passed : .failed))
        }
        if code == "scene.windows_plugin" {
            checks.append(WallpaperFailureCheck(kind: .windowsOnly, outcome: .failed))
        }
        if metalCodes.contains(code) {
            checks.append(WallpaperFailureCheck(kind: .metalUnsupported, outcome: .failed))
        }

        let likelyCause = checks.first { $0.outcome == .failed }?.kind
        let fix: WallpaperFailureRecovery? = switch likelyCause {
        case .engineAssetsMissing, .engineAssetsOutdated: .configureEngineAssets
        case .dependenciesMissing: .copyDependencyIDs(dependencyIDs)
        case .sourceUnreachable: .chooseSource
        case .windowsOnly, .metalUnsupported, nil: nil
        }
        return WallpaperFailureSelfCheckResult(
            checks: checks,
            likelyCause: likelyCause,
            passedCount: checks.filter { $0.outcome == .passed }.count,
            fix: fix,
            reportLines: checks.map { "Self-check: \($0.kind): \($0.outcome)" }
        )
    }
}

extension WallpaperFailureSelfCheck {
    /// Whether the wpeImport feature is on is the caller's call; this does not read the feature catalog.
    @MainActor
    static func probeEnvironment(for snapshot: WallpaperFailureSnapshot) async -> WallpaperFailureSelfCheckEnvironment {
        #if !LITE_BUILD
        let library = WPEEngineAssetsLibrary.shared
        library.refresh()
        let bookmark = snapshot.sourceBookmark
        let reachable = await Task.detached(priority: .userInitiated) {
            sourceReachability(bookmark: bookmark)
        }.value
        return WallpaperFailureSelfCheckEnvironment(
            engineAssetsInstalled: library.isAuthorized, sourceReachable: reachable, currentMissingDependencyIDs: nil
        )
        #else
        return WallpaperFailureSelfCheckEnvironment()
        #endif
    }

    #if !LITE_BUILD
    /// Without a bookmark the answer is unknown: a sandboxed read of a bare path fails even for a folder the user can open.
    private static func sourceReachability(bookmark: Data?) -> Bool? {
        guard let bookmark else { return nil }
        guard let resolution = try? DirectoryBookmarks.resolveDirectoryBookmark(bookmark), !resolution.isStale else { return false }
        let url = resolution.url
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }
    #endif
}
