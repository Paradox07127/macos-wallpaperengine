#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// The keyless path pays ~0.7 MB of HTML plus a details POST per call, so
/// paging back to a page already fetched has to come off the disk cache.
@Suite("Workshop keyless search cache")
@MainActor
struct WorkshopPublicSearchCacheTests {
    @Test("A repeated keyless request for the same page is served from cache")
    func repeatedRequestIsServedFromCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-public-cache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        WorkshopPublicStub.reset()
        let session = WorkshopPublicStub.makeSession()
        let source = WorkshopPublicSearchSource(
            metadata: SteamWorkshopMetadataService(session: session),
            session: session,
            appID: WorkshopQueryService.wallpaperEngineAppID,
            cache: WorkshopQueryCache(directoryURL: directory)
        )
        let request = WorkshopQueryRequest(sort: .topRated, page: 1, numPerPage: 30)

        let first = try await source.fetch(request)
        #expect(first.items.map(\.id) == [2_489_045_207])
        #expect(WorkshopPublicStub.browsePageRequests == 1)

        let second = try await source.fetch(request)
        #expect(second.items.map(\.id) == [2_489_045_207])
        #expect(WorkshopPublicStub.browsePageRequests == 1, "the second call must not re-fetch the HTML page")
        #expect(WorkshopPublicStub.detailRequests == 1, "nor re-resolve the details")
    }

    @Test("Two concurrent identical keyless requests issue one HTML fetch")
    func concurrentRequestsCoalesce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-public-coalesce-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        WorkshopPublicStub.reset()
        let session = WorkshopPublicStub.makeSession()
        let source = WorkshopPublicSearchSource(
            metadata: SteamWorkshopMetadataService(session: session),
            session: session,
            appID: WorkshopQueryService.wallpaperEngineAppID,
            cache: WorkshopQueryCache(directoryURL: directory)
        )
        let request = WorkshopQueryRequest(sort: .topRated, page: 2, numPerPage: 30)

        async let a = source.fetch(request)
        async let b = source.fetch(request)
        let pages = try await [a, b]

        #expect(pages.allSatisfy { $0.items.map(\.id) == [2_489_045_207] })
        #expect(WorkshopPublicStub.browsePageRequests == 1)
    }
}

/// Counts what actually leaves the process: one browse-page GET and one
/// details POST per uncached page.
private class WorkshopPublicStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var browseCount = 0
    nonisolated(unsafe) static var detailCount = 0

    static var browsePageRequests: Int {
        lock.withLock { browseCount }
    }

    static var detailRequests: Int {
        lock.withLock { detailCount }
    }

    static func reset() {
        lock.withLock {
            browseCount = 0
            detailCount = 0
        }
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkshopPublicStub.self]
        return URLSession(configuration: config)
    }

    private static let browseHTML = Data("""
    <div class="workshopBrowseItems">
    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207&amp;searchtext=" class="item_link"></a>
    <a href="https://steamcommunity.com/sharedfiles/filedetails/?id=2489045207&amp;searchtext=" class="workshopItemTitle">Neon City</a>
    </div>
    """.utf8)

    private static let detailsJSON = Data("""
    {"response":{"result":1,"resultcount":1,"publishedfiledetails":[\
    {"publishedfileid":"2489045207","result":1,"consumer_app_id":431960,\
    "title":"Neon City","short_description":"summary","time_updated":1720000000,\
    "visibility":0,"banned":0,"tags":[{"tag":"Scene"}]}]}}
    """.utf8)

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        let isDetails = url.absoluteString.contains("GetPublishedFileDetails")
        Self.lock.withLock {
            if isDetails {
                Self.detailCount += 1
            } else {
                Self.browseCount += 1
            }
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isDetails ? Self.detailsJSON : Self.browseHTML)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
