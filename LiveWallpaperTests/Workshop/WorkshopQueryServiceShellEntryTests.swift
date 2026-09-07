#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// What Steam actually returns for a browse page: private/hidden entries come
/// back as three-key shells (`result` 15, no title) in the middle of the list.
@Suite("WorkshopQueryService shell entries")
struct WorkshopQueryServiceShellEntryTests {
    private static let validKey = String(repeating: "a1b2c3d4", count: 4)

    @Test("Access-denied shells are dropped and an untitled item falls back to its id")
    func shellsDroppedAndUntitledFallsBackToID() async throws {
        let service = Self.makeService()
        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular, searchText: "shells"))

        #expect(page.items.map(\.id) == [111, 222])
        #expect(page.items.first?.title == "Titled")
        let untitled = try #require(page.items.last)
        #expect(untitled.title.contains("222"))
        #expect(untitled.title != "Untitled Workshop Item")
    }

    @Test("Control: banned or non-public entries are dropped, public ones kept")
    func bannedAndNonPublicDropped() async throws {
        let service = Self.makeService()
        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular, searchText: "hidden"))

        #expect(page.items.map(\.id) == [555])
    }

    fileprivate static func makeService() -> WorkshopQueryService {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-query-shell-\(UUID().uuidString)", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkshopQueryShellStub.self]
        return WorkshopQueryService(
            keychain: WorkshopKeychainStore(directory: directory, slot: WorkshopKeychainSlotSpy(stored: Self.validKey).slot()),
            cache: WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache")),
            session: URLSession(configuration: config)
        )
    }
}

/// Steam answers a failed query with HTTP 200, a response-level `result`
/// other than 1 (k_EResultOK) and no page body. Read as an empty page that
/// would show "no results", be cached, and count the key as accepted.
@Suite("WorkshopQueryService response-level result")
struct WorkshopQueryServiceResultFieldTests {
    @Test("A 200 with result 2 is an error, not an empty page; it is neither cached nor an auth success")
    func failedResultThrows() async throws {
        let service = WorkshopQueryServiceShellEntryTests.makeService()
        let verdicts = VerdictLog()
        await service.setAuthVerdictHandler { accepted, _ in verdicts.append(accepted) }
        let request = WorkshopQueryRequest(sort: .mostPopular, searchText: "failed")

        await #expect(throws: WorkshopQueryError.schemaMismatch) { try await service.fetch(request) }
        // A cached page would be served here without going back to the stub.
        await #expect(throws: WorkshopQueryError.schemaMismatch) { try await service.fetch(request) }
        #expect(verdicts.values.isEmpty)
    }

    @Test("Control: result 1, or no result at all, with total 0 is an empty page", arguments: ["resultOK", "noResult"])
    func emptyPagesStayEmpty(searchText: String) async throws {
        let service = WorkshopQueryServiceShellEntryTests.makeService()

        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular, searchText: searchText))

        #expect(page.items.isEmpty)
        #expect(page.totalAvailable == 0)
    }

    /// A missing `publishedfiledetails` is only an empty page when the total
    /// says there is nothing on this page; a total of 100 on page 1 with no
    /// list is a broken response, and reading it as empty would cache it.
    @Test("A 200 with total 100 and no list is an error, not an empty page; neither cached nor an auth success")
    func missingListWithItemsToShowThrows() async throws {
        let service = WorkshopQueryServiceShellEntryTests.makeService()
        let verdicts = VerdictLog()
        await service.setAuthVerdictHandler { accepted, _ in verdicts.append(accepted) }
        let request = WorkshopQueryRequest(sort: .mostPopular, searchText: "noList100")

        await #expect(throws: WorkshopQueryError.schemaMismatch) { try await service.fetch(request) }
        await #expect(throws: WorkshopQueryError.schemaMismatch) { try await service.fetch(request) }
        #expect(verdicts.values.isEmpty)
    }

    @Test("Control: past the last page, a missing list is a legitimate empty page")
    func missingListPastTheLastPageIsEmpty() async throws {
        let service = WorkshopQueryServiceShellEntryTests.makeService()

        let page = try await service.fetch(
            WorkshopQueryRequest(sort: .mostPopular, searchText: "noList100", page: 3, numPerPage: 50)
        )

        #expect(page.items.isEmpty)
        #expect(page.totalAvailable == 100)
        #expect(page.totalPages == 2)
    }

    @Test("A total of Int.max neither traps nor yields a page count")
    func hugeTotalDoesNotTrap() async throws {
        let service = WorkshopQueryServiceShellEntryTests.makeService()

        let page = try await service.fetch(WorkshopQueryRequest(sort: .mostPopular, searchText: "hugeTotal"))

        #expect(page.items.map(\.id) == [1])
        #expect(page.totalAvailable == Int.max)
        #expect(page.totalPages == nil)
    }

    /// @unchecked Sendable: every access to `entries` goes through `lock`.
    private final class VerdictLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [Bool] = []

        func append(_ accepted: Bool) {
            lock.lock()
            entries.append(accepted)
            lock.unlock()
        }

        var values: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }
}

/// Picks its fixed body by the request's `search_text`, so the tests share no
/// mutable state.
private final class WorkshopQueryShellStub: URLProtocol, @unchecked Sendable {
    private static let shells = Data("""
    {"response":{"total":3,"publishedfiledetails":[\
    {"result":15,"publishedfileid":"3780358476","language":0},\
    {"publishedfileid":"111","result":1,"title":"Titled","visibility":0,"banned":false},\
    {"publishedfileid":"222","result":1,"visibility":0,"banned":false}]}}
    """.utf8)

    private static let hidden = Data("""
    {"response":{"total":3,"publishedfiledetails":[\
    {"publishedfileid":"333","result":1,"title":"Banned","visibility":0,"banned":true},\
    {"publishedfileid":"444","result":1,"title":"Friends","visibility":1,"banned":false},\
    {"publishedfileid":"555","result":1,"title":"Public","visibility":0,"banned":false}]}}
    """.utf8)

    private static let failed = Data(#"{"response":{"result":2,"resultmsg":"Failed"}}"#.utf8)
    private static let resultOK = Data(#"{"response":{"result":1,"total":0}}"#.utf8)
    private static let noResult = Data(#"{"response":{"total":0}}"#.utf8)
    private static let noList100 = Data(#"{"response":{"total":100}}"#.utf8)
    private static let hugeTotal = Data("""
    {"response":{"total":9223372036854775807,"publishedfiledetails":[\
    {"publishedfileid":"1","result":1,"title":"Only","visibility":0,"banned":false}]}}
    """.utf8)

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let searchText = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "search_text" }?.value
        let body: Data = switch searchText {
        case "hidden": Self.hidden
        case "failed": Self.failed
        case "resultOK": Self.resultOK
        case "noResult": Self.noResult
        case "noList100": Self.noList100
        case "hugeTotal": Self.hugeTotal
        default: Self.shells
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
