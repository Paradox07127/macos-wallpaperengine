#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// Creator personas are a second Steam round trip (`GetPlayerSummaries`).
/// They must not sit in front of the page the grid paints from.
@Suite("WorkshopQueryService creator names")
struct WorkshopQueryServiceCreatorNameTests {
    private static let validKey = String(repeating: "a1b2c3d4", count: 4)
    private static let creatorID = "76561190000000001"

    @Test("The page is handed over before GetPlayerSummaries answers")
    func pageArrivesBeforePersonaNames() async throws {
        let service = Self.makeService()
        let started = Date()
        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular))
        let elapsed = Date().timeIntervalSince(started)

        #expect(page.items.count == 1)
        #expect(
            elapsed < WorkshopPersonaDelayStub.personaDelay / 2,
            "fetch waited \(elapsed) s, i.e. on the persona round trip"
        )
    }

    /// The second phase still has to deliver, and the cached page has to end
    /// up holding what it delivered — otherwise every cache hit would pay
    /// for the persona lookup again.
    @Test("Personas arrive after the page and are written into the cached copy")
    func personasArriveAfterThePageAndReachTheCache() async throws {
        let service = Self.makeService()
        let request = WorkshopQueryRequest(sort: .mostPopular)

        let page = try await service.fetch(request)
        #expect(page.items.first?.creatorID == Self.creatorID)
        #expect(page.items.first?.creatorPersonaName == nil, "names are not on the first-paint path")

        let names = await service.resolveCreatorNames(for: page, request: request)
        #expect(names[Self.creatorID] == "Aurora")

        // Same request again: served from the cache the second phase rewrote.
        let cached = try await service.fetch(request)
        #expect(cached.items.first?.creatorPersonaName == "Aurora")
    }

    /// Both round trips are real requests; the ribbon's tally counts each.
    @Test("Each issued HTTP request bumps the request counter exactly once")
    func everyHTTPRequestIsCounted() async throws {
        let spy = RequestCountSpy()
        let service = Self.makeService(countIssuedRequest: { spy.bump() })
        let request = WorkshopQueryRequest(sort: .mostPopular)

        let page = try await service.fetch(request)
        #expect(spy.count == 1, "the QueryFiles GET")

        _ = await service.resolveCreatorNames(for: page, request: request)
        #expect(spy.count == 2, "plus the GetPlayerSummaries GET the pane-side flag never saw")

        // Control: a cache hit issues nothing, so it must not be counted.
        _ = try await service.fetch(request)
        #expect(spy.count == 2)
    }

    private static func makeService(
        countIssuedRequest: @escaping @Sendable () -> Void = {}
    ) -> WorkshopQueryService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-query-personas-\(UUID().uuidString)", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkshopPersonaDelayStub.self]
        return WorkshopQueryService(
            keychain: WorkshopKeychainStore(
                directory: directory,
                slot: WorkshopKeychainSlotSpy(stored: Self.validKey).slot()
            ),
            cache: WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache")),
            session: URLSession(configuration: config),
            countIssuedRequest: countIssuedRequest
        )
    }
}

/// Counts the actor's issued requests without touching the real preferences
/// domain the shipping counter writes. One `Int`, guarded by `lock`.
private final class RequestCountSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func bump() {
        lock.withLock { value += 1 }
    }
}

/// Answers `QueryFiles` immediately and `GetPlayerSummaries` only after a
/// delay, so "did the page wait for the names" is a wall-clock question.
private class WorkshopPersonaDelayStub: URLProtocol, @unchecked Sendable {
    static let personaDelay: TimeInterval = 2.0

    private static let queryBody = Data("""
    {"response":{"total":1,"publishedfiledetails":[\
    {"publishedfileid":"777","result":1,"title":"Named","short_description":"summary",\
    "visibility":0,"banned":0,"creator":"76561190000000001"}]}}
    """.utf8)

    private static let personaBody = Data("""
    {"response":{"players":[{"steamid":"76561190000000001","personaname":"Aurora"}]}}
    """.utf8)

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let url = request.url!
        let isPersona = url.absoluteString.contains("GetPlayerSummaries")
        let body = isPersona ? Self.personaBody : Self.queryBody
        let delay = isPersona ? Self.personaDelay : 0
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let client else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
            )!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
#endif
