#if !LITE_BUILD
import Foundation

extension WPEResolutionDiagnosticsSnapshot {
    var failureMissingResources: [WallpaperFailureMissingResource] {
        var seen = Set<String>()
        return missedRefs.filter { seen.insert($0.ref).inserted }.prefix(20).map { event in
            WallpaperFailureMissingResource(
                path: event.ref,
                searchedEngineAssets: event.attempts.contains { $0.origin == .engineAssets },
                dependencyID: event.attempts.lazy.compactMap { attempt -> String? in
                    if case let .dependency(id) = attempt.origin {
                        return id
                    }
                    return nil
                }.first
            )
        }
    }
}
#endif
