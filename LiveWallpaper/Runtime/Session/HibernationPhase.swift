import Foundation

/// Cover must be on screen before release (blank desktop otherwise). Resume mid-restore must not uncover; suspend mid-restore must leave a phase the dwell can arm from.
struct HibernationPhase: Equatable {
    enum Phase: Equatable {
        case live
        /// Released behind the cover, waiting for a resume.
        case hibernated
        /// Rebuilding under the cover; nothing may uncover until it paints.
        case restoring
    }

    enum Step: Equatable {
        /// Get the cover up. Only after it is actually visible may the caller
        /// release anything.
        case presentCover
        /// The cover is up: drop the live document / player now.
        case releaseResources
        /// Rebuild the released thing, still under the cover.
        case rebuild
        /// A restore is already running underneath — do nothing, and above all
        /// do not uncover.
        case keepCover
    }

    private(set) var phase: Phase = .live
    /// Bumped by every resume and every rebuild so a cover reply that lands after
    /// a wake cannot release the thing that wake just rebuilt.
    private(set) var generation: UInt64 = 0
    private(set) var isPresentingCover = false

    /// `releaseResources` is only ever returned by `coverDidPresent`, never here:
    /// releasing before the cover is visible is the blank-desktop bug.
    mutating func begin() -> Step? {
        guard phase == .live, !isPresentingCover else { return nil }
        isPresentingCover = true
        return .presentCover
    }

    mutating func coverDidPresent(_ presented: Bool, generation: UInt64) -> Step? {
        guard isPresentingCover, self.generation == generation else { return nil }
        isPresentingCover = false
        // Cover failed ⇒ stay live. Burning power beats a blank desktop.
        guard presented, phase == .live else { return nil }
        phase = .hibernated
        return .releaseResources
    }

    mutating func requestRestore() -> Step? {
        generation &+= 1
        switch phase {
        case .hibernated:
            isPresentingCover = false
            phase = .restoring
            return .rebuild
        case .restoring:
            return .keepCover
        case .live:
            isPresentingCover = false
            return nil
        }
    }

    /// Suspend mid-restore must go to `.live`, not `.hibernated`: the rebuild is still in flight and `.hibernated` would never re-arm the dwell.
    mutating func noteSuspendedDuringRestore() {
        guard phase == .restoring else { return }
        phase = .live
        isPresentingCover = false
        generation &+= 1
    }

    /// Any rebuild other than the teardown itself puts a real thing back; a
    /// restore in flight keeps its phase until it paints.
    mutating func noteRebuildStarted() {
        isPresentingCover = false
        generation &+= 1
        if phase == .hibernated { phase = .live }
    }

    /// True once, when the rebuilt thing has painted and the cover can go.
    mutating func didRestore() -> Bool {
        guard phase == .restoring else { return false }
        phase = .live
        return true
    }

    mutating func invalidate() {
        phase = .live
        isPresentingCover = false
        generation &+= 1
    }
}
