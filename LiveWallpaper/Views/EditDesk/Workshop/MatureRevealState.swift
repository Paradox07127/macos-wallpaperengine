#if !LITE_BUILD
import Foundation
import Observation

/// Which mature-rated Workshop items the user has chosen to uncover, keyed by item ID so a reveal
/// survives paging and re-sorting. The host clears it when the browsing session ends.
@MainActor
@Observable
final class MatureRevealState {
    private var revealed: Set<UInt64> = []

    func isRevealed(_ itemID: UInt64) -> Bool {
        revealed.contains(itemID)
    }

    func reveal(_ itemID: UInt64) {
        revealed.insert(itemID)
    }

    func clear() {
        revealed.removeAll()
    }
}
#endif
