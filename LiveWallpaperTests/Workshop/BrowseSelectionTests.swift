#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The pane keeps an id, not a value copy: the inspector has to follow the
/// grid when a page turn or the persona pass replaces `items`.
@Suite("Workshop browse selection")
struct BrowseSelectionTests {
    @Test("An id resolves against whatever the grid currently holds")
    func selectionFollowsItems() {
        let page1 = [Self.item(id: 1, author: nil), Self.item(id: 2, author: nil)]
        let page1Named = [Self.item(id: 1, author: "abi toads"), Self.item(id: 2, author: nil)]
        let page2 = [Self.item(id: 3, author: nil)]

        #expect(BrowseSelection.resolve(id: 1, in: page1, detached: nil)?.creatorPersonaName == nil)
        #expect(BrowseSelection.resolve(id: 1, in: page1Named, detached: nil)?.creatorPersonaName == "abi toads")
        // Turned the page: the id is gone, so the inspector closes.
        #expect(BrowseSelection.resolve(id: 1, in: page2, detached: nil) == nil)
        #expect(BrowseSelection.resolve(id: nil, in: page1, detached: nil) == nil)
    }

    @Test("A detached item stands in only for its own id")
    func detachedItemMatchesItsID() {
        let page = [Self.item(id: 3, author: nil)]
        let detached = Self.item(id: 42, author: "someone")
        #expect(BrowseSelection.resolve(id: 42, in: page, detached: detached)?.id == 42)
        #expect(BrowseSelection.resolve(id: 7, in: page, detached: detached) == nil)
        // The grid wins over a detached copy of the same id.
        let onPage = [Self.item(id: 42, author: "grid")]
        #expect(BrowseSelection.resolve(id: 42, in: onPage, detached: detached)?.creatorPersonaName == "grid")
    }

    /// `openItem` clears `detachedItem` before the fetch; a page turn or the
    /// persona pass replacing `items` in that window must not drop the id, or
    /// the fetch result is discarded on arrival.
    @Test("A grid change during an off-page open keeps the pending id selected")
    func pendingOpenSurvivesGridChange() {
        let page2 = [Self.item(id: 3, author: nil)]
        #expect(BrowseSelection.keepsSelection(id: 42, in: page2, detached: nil, pending: 42))
        // Controls: nothing pending (or another id pending) — the id left with the page.
        #expect(!BrowseSelection.keepsSelection(id: 42, in: page2, detached: nil, pending: nil))
        #expect(!BrowseSelection.keepsSelection(id: 42, in: page2, detached: nil, pending: 7))
        #expect(BrowseSelection.keepsSelection(id: 3, in: page2, detached: nil, pending: nil))
        #expect(BrowseSelection.keepsSelection(id: nil, in: page2, detached: nil, pending: nil))
    }

    @Test("A failed off-page open restores what the inspector was showing")
    func failedOpenRestoresPreviousSelection() {
        let page = [Self.item(id: 3, author: nil)]
        let open = BrowseSelection.PendingOpen(id: 42, generation: 1, previousSelectedID: 3, previousDetached: nil)
        let restored = open.settle(with: nil, in: page)
        #expect(restored.selectedID == 3)
        #expect(restored.detached == nil)

        // The previous selection was itself detached: it comes back with its copy.
        let detached = Self.item(id: 9, author: nil)
        let fromDetached = BrowseSelection.PendingOpen(id: 42, generation: 2, previousSelectedID: 9, previousDetached: detached)
        #expect(fromDetached.settle(with: nil, in: page).selectedID == 9)
        #expect(fromDetached.settle(with: nil, in: page).detached == detached)

        // Success lands on the opened item.
        let fetched = Self.item(id: 42, author: nil)
        let landed = open.settle(with: fetched, in: page)
        #expect(landed.selectedID == 42)
        #expect(landed.detached == fetched)

        // Control: the previous id left the grid meanwhile — nothing to restore.
        #expect(open.settle(with: nil, in: []).selectedID == nil)
    }

    /// Opening the same id twice from the same state builds two equal
    /// records; the first fetch landing would then settle the second open.
    @Test("Two opens of the same id are told apart by generation")
    func repeatedOpenIsDistinct() {
        let first = BrowseSelection.PendingOpen(id: 42, generation: 1, previousSelectedID: 3, previousDetached: nil)
        let second = BrowseSelection.PendingOpen(id: 42, generation: 2, previousSelectedID: 3, previousDetached: nil)
        #expect(first != second)
        #expect(first == BrowseSelection.PendingOpen(id: 42, generation: 1, previousSelectedID: 3, previousDetached: nil))
    }

    private static func item(id: UInt64, author: String?) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: id, rawTitle: "t\(id)", shortDescription: "", creatorID: "c", creatorPersonaName: author,
            previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil,
            rating: nil, tags: [], visibility: .public, isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        )
    }
}

/// A failed page turn keeps the old grid on screen; the failure has to be
/// visible somewhere other than the empty-grid error state.
@Suite("Workshop browse paging failure", .serialized)
struct BrowsePagingErrorTests {
    @Test("A failed page turn keeps the grid, records the target page and shows the error bar")
    @MainActor
    func failedPageTurnIsSurfaced() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.paging.error")
        defer { suite.discard() }
        let services = Self.makeServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)

        await model.reload()
        #expect(model.items.map(\.id) == [1])
        #expect(model.totalPages == 2)
        #expect(!model.showsPagingError)

        await model.goToNextPage()
        #expect(model.pageIndex == 1)
        #expect(model.items.map(\.id) == [1], "the previous page stays on screen")
        #expect(model.lastError != nil)
        #expect(model.showsPagingError)
        #expect(model.failedPageTarget == 2)

        // Control: a fresh reload clears the paging failure.
        await model.reload()
        #expect(!model.showsPagingError)
        #expect(model.failedPageTarget == nil)
    }

    /// The current page's only entry was dropped client-side (`Application`),
    /// so `items` is empty although the pager is live; a failed Next still has
    /// to say so.
    @Test("A failed page turn off a fully filtered page still shows the error bar")
    @MainActor
    func failedPageTurnOffFilteredPageIsSurfaced() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.paging.filtered")
        defer { suite.discard() }
        let services = Self.makeServices(stub: FilteredPageStub.self)
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)

        await model.reload()
        #expect(model.items.isEmpty)
        #expect(model.currentPageIsFilteredOut)
        #expect(model.totalPages == 2)

        await model.goToNextPage()
        #expect(model.lastError != nil)
        #expect(model.failedPageTarget == 2)
        #expect(model.showsPagingError)
    }

    /// Page 2 came back empty with no total (a keyed query Steam sent no
    /// `total` for): nothing to show, but the reader got here by paging and
    /// has to be able to page back.
    @Test("An empty later page keeps the pager reachable")
    @MainActor
    func emptyLaterPageKeepsPager() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.paging.emptyLater")
        defer { suite.discard() }
        let services = Self.makeServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)

        model.applyPageForTesting(sourceItemCount: 0, totalPages: nil, pageIndex: 2)
        #expect(model.items.isEmpty)
        #expect(model.currentPageIsFilteredOut)
        #expect(model.canGoPrevPage)

        // Control: page 1 with nothing at all is a query with no results.
        model.applyPageForTesting(sourceItemCount: 0, totalPages: nil, pageIndex: 1)
        #expect(!model.currentPageIsFilteredOut)
    }

    @MainActor
    private static func makeServices(stub: URLProtocol.Type = PagingStub.self) -> WorkshopServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-browse-paging-\(UUID().uuidString)", isDirectory: true)
        let keychain = WorkshopKeychainStore(
            directory: directory,
            slot: WorkshopKeychainSlotSpy(stored: String(repeating: "a1b2c3d4", count: 4)).slot()
        )
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [stub]
        let service = WorkshopQueryService(
            keychain: keychain,
            cache: cache,
            session: URLSession(configuration: config),
            countIssuedRequest: {}
        )
        return WorkshopServices(keychain: keychain, cache: cache, queryService: service)
    }
}

/// Page 1 answers with one item and a two-page total; page 2 answers with a
/// Valve-level failure (`result` 2), which the service maps without retrying.
private final class PagingStub: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let page = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "page" }?.value ?? "1"
        let body = page == "1"
            ? #"{"response":{"total":100,"publishedfiledetails":[{"result":1,"publishedfileid":"1","title":"One","visibility":0,"banned":false}]}}"#
            : #"{"response":{"result":2,"resultmsg":"Fail"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Page 1 answers with one `Application`-tagged item (dropped client-side) and
/// a two-page total; page 2 fails like `PagingStub`'s.
private final class FilteredPageStub: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let page = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "page" }?.value ?? "1"
        let body = page == "1"
            ? #"{"response":{"total":100,"publishedfiledetails":[{"result":1,"publishedfileid":"1","title":"App","visibility":0,"banned":false,"tags":[{"tag":"Application","display_name":"Application"}]}]}}"#
            : #"{"response":{"result":2,"resultmsg":"Fail"}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
