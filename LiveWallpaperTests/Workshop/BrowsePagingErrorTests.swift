#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

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

        await model.reload()
        #expect(!model.showsPagingError)
        #expect(model.failedPageTarget == nil)
    }

    /// The page's only entry is dropped client-side (`Application`), so
    /// `items` is empty although the pager is live.
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

    /// Page 2 came back empty with no `total` — a keyed query Steam sent no
    /// `total` for.
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
