#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

/// Per-screen WPE import error + generation (fresh import wins over in-flight).
/// `@Observable` for error UI; generation is `@ObservationIgnored` concurrency bookkeeping.
@MainActor
@Observable
final class WPEImportTracker {
    private var lastErrors: [CGDirectDisplayID: AppError] = [:]

    @ObservationIgnored private var generations: [CGDirectDisplayID: Int] = [:]
    /// Process-lifetime latch: every generation (incl. unknown screen IDs) becomes stale.
    @ObservationIgnored private(set) var isTerminated = false

    func error(for screenID: CGDirectDisplayID) -> AppError? {
        lastErrors[screenID]
    }

    func recordError(_ error: AppError, for screenID: CGDirectDisplayID) {
        guard !isTerminated else { return }
        lastErrors[screenID] = error
    }

    func clearError(for screenID: CGDirectDisplayID) {
        guard !isTerminated else { return }
        lastErrors.removeValue(forKey: screenID)
    }

    func bumpGeneration(for screenID: CGDirectDisplayID) -> Int {
        let next = (generations[screenID] ?? 0) &+ 1
        generations[screenID] = next
        return next
    }

    func isCurrentGeneration(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool {
        !isTerminated && generations[screenID] == generation
    }

    /// Invalidates admitted imports and rejects later applies (lifecycle bit is authority).
    func invalidateForTermination() {
        guard !isTerminated else { return }
        isTerminated = true
        generations.removeAll()
    }
}
#endif
