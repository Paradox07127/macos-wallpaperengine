#if !LITE_BUILD
import Foundation
import Observation

/// The Workshop page's long-lived state, owned by `EditDeskRoot` rather than by the page: switching
/// pages unmounts the page, and a session rebuilt there would hand back a fresh browse model — page
/// one, no filters, no reveals — and drop any deep link waiting to be applied.
@MainActor
@Observable
final class WorkshopSession {
    let browse: BrowseViewModel
    let deferredApply: DeferredApplyCoordinator
    let matureReveal = MatureRevealState()

    @ObservationIgnored private let confirmReadiness: @MainActor () async -> Void
    @ObservationIgnored private let ingestDownloads: @MainActor () async -> Void
    @ObservationIgnored private var deepLinkSearch: Task<Void, Never>?

    init(
        browse: BrowseViewModel,
        deferredApply: DeferredApplyCoordinator,
        confirmReadiness: @escaping @MainActor () async -> Void,
        ingestDownloads: @escaping @MainActor () async -> Void
    ) {
        self.browse = browse
        self.deferredApply = deferredApply
        self.confirmReadiness = confirmReadiness
        self.ingestDownloads = ingestDownloads
    }

    isolated deinit {
        deepLinkSearch?.cancel()
    }

    /// Serial, and deliberately without an "already ran" flag: the ingest scan reads the readiness
    /// the first step confirms, and leaving the page cancels the caller's task — coming back has to
    /// be able to run the pass again, or the Download button stays greyed out.
    func prepareDownloads() async {
        await confirmReadiness()
        guard !Task.isCancelled else { return }
        await ingestDownloads()
    }

    /// Takes the one-shot "open Workshop scoped to this search" hand-off and points Browse at it.
    /// Returns the query it consumed, or nil when nothing was waiting.
    @discardableResult
    func consumePendingDeepLink() -> String? {
        guard let query = WorkshopDeepLink.takePendingSearch() else { return nil }
        deepLinkSearch?.cancel()
        deepLinkSearch = Task { [browse] in await browse.searchFromDeepLink(query) }
        return query
    }
}
#endif
