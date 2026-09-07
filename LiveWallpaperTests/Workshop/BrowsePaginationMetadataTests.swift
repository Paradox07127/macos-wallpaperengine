#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// The pager is driven by what Steam reported for the page — its raw item
/// count and page count — not by what survived the client-side filters.
@Suite("Workshop browse pagination metadata", .serialized)
@MainActor
struct BrowsePaginationMetadataTests {
    @Test("A full keyed page with one shell still offers the next page")
    func keyedShellPageKeepsNext() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.pagination.keyedShell")
        defer { suite.discard() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-browse-pagination-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = WorkshopKeychainStore(
            directory: directory,
            slot: WorkshopKeychainSlotSpy(stored: String(repeating: "a1b2c3d4", count: 4)).slot()
        )
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KeyedShellPageStub.self]
        let service = WorkshopQueryService(
            keychain: keychain, cache: cache, session: URLSession(configuration: config), countIssuedRequest: {}
        )
        let services = WorkshopServices(keychain: keychain, cache: cache, queryService: service)
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)

        await model.reload()

        #expect(model.lastError == nil)
        #expect(model.items.count == 49, "the shell never reaches the grid")
        #expect(model.lastFetchedRawItemCount == 50, "Steam sent a full page")
        #expect(model.totalPages == nil, "no total in the response")
        #expect(model.canGoNextPage)
    }

    @Test("Keyless: the SSR page count drives the pager")
    func keylessTotalPagesDrivesPager() async throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.pagination.keylessPages")
        defer { suite.discard() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-browse-pagination-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychain = WorkshopKeychainStore(directory: directory, slot: WorkshopKeychainSlotSpy().slot())
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let services = WorkshopServices(
            keychain: keychain, cache: cache,
            queryService: WorkshopQueryService(keychain: keychain, cache: cache, countIssuedRequest: {})
        )
        try KeylessPageStub.configure(
            html: WorkshopPublicSearchSSRTests.derived {
                try WorkshopBrowseFixture.excludingMaturity(in: WorkshopBrowseFixture.pages3())
            },
            details: .transportError
        )
        let session = KeylessPageStub.makeSession()
        let publicSource = WorkshopPublicSearchSource(
            metadata: SteamWorkshopMetadataService(session: session),
            session: session,
            appID: WorkshopQueryService.wallpaperEngineAppID,
            cache: WorkshopQueryCache(directoryURL: directory.appendingPathComponent("public-cache"))
        )
        let model = BrowseViewModel(services: services, defaults: suite.defaults, publicSource: publicSource)
        try #require(model.usesKeylessSearch)
        // The fixture answers exactly this request; anything else would be an
        // identity mismatch and the (failing) details stub would surface it.
        try #require(
            model.makeRequest(page: 1).excludedTags
                == ["Application", "Asset", "Mature", "Preset", "Questionable"]
        )

        await model.reload()

        #expect(model.lastError == nil)
        #expect(model.items.count == 30)
        #expect(model.pageIndex == 1)
        #expect(model.totalPages == 3)
        #expect(model.canGoNextPage)
        #expect(!model.currentPageIsFilteredOut)
    }

    /// Synchronous state check (like `nextPageUsesRawPageCount`): a page whose
    /// 30 source items were all dropped, versus a query with nothing at all.
    @Test("An empty grid keeps the pager when Steam's page was not empty")
    func filteredOutPageKeepsPager() throws {
        let suite = try TestScratch.defaultsSuite("workshop.browse.pagination.filteredOut")
        defer { suite.discard() }
        let services = WorkshopServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)

        #expect(!model.currentPageIsFilteredOut, "nothing loaded yet")

        model.applyPageForTesting(sourceItemCount: 30, totalPages: nil)
        #expect(model.items.isEmpty)
        #expect(model.currentPageIsFilteredOut)

        model.applyPageForTesting(sourceItemCount: 0, totalPages: 4)
        #expect(model.currentPageIsFilteredOut, "other pages exist")
        #expect(model.totalPages == 4)

        // Control: the query itself is empty.
        model.applyPageForTesting(sourceItemCount: 0, totalPages: 0)
        #expect(!model.currentPageIsFilteredOut)
        #expect(model.totalPages == nil)
    }
}

/// QueryFiles answered with 50 entries — 49 public items and one private shell
/// — and no `total`; anything else (persona lookup) gets an empty players list.
private final class KeyedShellPageStub: URLProtocol, @unchecked Sendable {
    private static func queryFilesJSON() -> Data {
        var entries = (1 ... 49).map { index -> String in
            #"{"publishedfileid":"\#(1000 + index)","result":1,"title":"Item \#(index)","visibility":0,"banned":false,"tags":[{"tag":"Scene","display_name":"Scene"}]}"#
        }
        entries.insert(#"{"publishedfileid":"2000","result":15}"#, at: 7)
        return Data(#"{"response":{"publishedfiledetails":[\#(entries.joined(separator: ","))]}}"#.utf8)
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        let body = url.path.contains("QueryFiles")
            ? Self.queryFilesJSON()
            : Data(#"{"response":{"players":[]}}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
