import Foundation

/// The cover-then-release lifecycle shared by the wallpaper runtimes that tear
/// themselves down after an absence and rebuild on the way back.
///
/// Ordering is the whole point: the cover (a snapshot overlay for HTML, a
/// captured still frame for video) has to be on screen *before* the live thing is
/// released, or the desktop flashes blank — the same failure that keeps
/// `aggressiveSuspend` opt-in. Two rules fall out of that and are why this is a
/// type rather than a pair of booleans per runtime:
///
/// - A resume arriving while a restore is still in flight must NOT uncover; the
///   thing on screen is a blank or half-built document.
/// - A suspend arriving mid-restore must leave a phase the dwell can arm from,
///   or that screen never hibernates again for the rest of the session.
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

    /// A suspend landing mid-restore: the rebuild is still in flight behind the
    /// cover, so go back to a phase the dwell can arm from.
    mutating func noteSuspendedDuringRestore() {
        guard phase == .restoring else { return }
        phase = .hibernated
        isPresentingCover = true
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
