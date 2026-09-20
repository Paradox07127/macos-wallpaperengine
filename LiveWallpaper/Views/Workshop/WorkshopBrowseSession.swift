#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Owned by the management window, so sidebar and settings navigation do not
/// discard the current Workshop query, inspector, or scroll location.
@MainActor
@Observable
final class WorkshopBrowseSession {
    var viewModel: BrowseViewModel?
    var scrollID: UInt64?
    /// An id, not a value copy: the inspector follows the grid when a page
    /// turn or the persona pass replaces `viewModel.items`.
    var selectedID: UInt64?
    /// An item opened from a Required items row, which need not be on the
    /// current page; resolved once through `services.itemDetails`.
    var detachedItem: WorkshopQueryItem?
    /// The off-page open in flight, if any; `onChange(of: items)` must not
    /// clear its id while the fetch runs.
    var pendingOpen: BrowseSelection.PendingOpen?
    /// Tells two opens of the same id apart, so the first fetch landing cannot
    /// settle the second.
    var openGeneration = 0
    var inspectorHidden = false

    func reconcileSelection(in items: [WorkshopQueryItem]) {
        guard !BrowseSelection.keepsSelection(
            id: selectedID, in: items, detached: detachedItem, pending: pendingOpen?.id
        ) else { return }
        selectedID = nil
    }
}
#endif
