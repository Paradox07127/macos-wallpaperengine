#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// Required items and detached inspector targets are resolved by id through
/// the key-free `GetPublishedFileDetails` batch, so both browse paths can use it.
@Suite("Workshop item details loader", .serialized)
struct WorkshopItemDetailsLoaderTests {
    @Test("Two OK payloads become items in request order; a result 9 id is reported as failed")
    @MainActor
    func loadsOKItemsAndListsFailures() async {
        let (loader, stub) = Self.makeLoader(body: Self.batch([
            .ok(id: "222", title: "Second", tags: ["Scene", "Preset"]),
            .ok(id: "111", title: "First", tags: ["Video"]),
            .code(id: "333", 9),
        ]))
        defer { stub.reset() }

        let outcome = await loader.load(ids: [111, 222, 333])
        #expect(outcome.items.map(\.id) == [111, 222])
        #expect(outcome.items.map(\.title) == ["First", "Second"])
        #expect(outcome.items.first?.tags == ["Video"])
        // The detail inspector's "Posted" line and creator link read these;
        // the metadata → browse-item mapping used to drop both.
        #expect(outcome.items.first?.creatorID == "76561198000000001")
        #expect(outcome.items.first?.timeCreated == Date(timeIntervalSince1970: 1_710_000_000))
        #expect(outcome.failedIDs == [333])
        #expect(stub.bodies == ["itemcount=3&publishedfileids%5B0%5D=111&publishedfileids%5B1%5D=222&publishedfileids%5B2%5D=333"])
    }

    @Test("Private and foreign-app payloads are dropped by the metadata rules and listed as failed")
    @MainActor
    func metadataDropRulesApply() async {
        let (loader, stub) = Self.makeLoader(body: Self.batch([
            .ok(id: "111", title: "Public", tags: []),
            .code(id: "444", 15),
            .foreignApp(id: "555"),
        ]))
        defer { stub.reset() }

        let outcome = await loader.load(ids: [111, 444, 555])
        #expect(outcome.items.map(\.id) == [111])
        #expect(outcome.failedIDs == [444, 555])
    }

    /// A 5xx or a dropped connection says nothing about the ids; the section
    /// offers a retry instead of a Steam link per item.
    @Test("Three 503s are a transient failure, not a per-item one")
    @MainActor
    func serverErrorsAreTransient() async {
        let (loader, stub) = Self.makeLoader(body: Data(), status: 503)
        defer { stub.reset() }

        let outcome = await loader.load(ids: [111, 222])
        #expect(outcome.transientFailure)
        #expect(outcome.items.isEmpty)
        #expect(outcome.failedIDs.isEmpty)
        #expect(stub.bodies.count == WorkshopRetryPolicy.maxAttempts, "the batch is retried")
    }

    @Test("Control: a 200 with a result 9 is a per-item failure and no retry")
    @MainActor
    func notFoundIsPerItem() async {
        let (loader, stub) = Self.makeLoader(body: Self.batch([.code(id: "333", 9)]))
        defer { stub.reset() }

        let outcome = await loader.load(ids: [333])
        #expect(!outcome.transientFailure)
        #expect(outcome.failedIDs == [333])
        #expect(stub.bodies.count == 1)
    }

    @Test("The transient-failure copy exists in all five languages")
    func transientFailureCopyIsLocalized() throws {
        let strings = try WorkshopTagTaxonomyTests.catalogStrings()
        for locale in ["en", "zh-Hans", "zh-Hant", "ja", "es"] {
            let value = WorkshopTagTaxonomyTests.value(strings, key: "Couldn’t load required items.", locale: locale) ?? ""
            #expect(!value.isEmpty, "\(locale)")
        }
    }

    @Test("An empty id list issues no request")
    @MainActor
    func emptyListSkipsNetwork() async {
        let (loader, stub) = Self.makeLoader(body: Data())
        defer { stub.reset() }

        let outcome = await loader.load(ids: [])
        #expect(outcome.items.isEmpty)
        #expect(outcome.failedIDs.isEmpty)
        #expect(stub.bodies.isEmpty)
    }

    // MARK: - Fixtures

    private enum Payload {
        case ok(id: String, title: String, tags: [String])
        case code(id: String, Int)
        case foreignApp(id: String)
    }

    private static func batch(_ payloads: [Payload]) -> Data {
        let details = payloads.map { payload -> String in
            switch payload {
            case let .ok(id, title, tags):
                let tagJSON = tags.map { "{\"tag\":\"\($0)\"}" }.joined(separator: ",")
                return """
                {"publishedfileid":"\(id)","result":1,"consumer_app_id":431960,"title":"\(title)",\
                "creator":"76561198000000001","short_description":"d","time_created":1710000000,\
                "time_updated":1720000000,"visibility":0,"banned":0,"tags":[\(tagJSON)]}
                """
            case let .code(id, code):
                return "{\"publishedfileid\":\"\(id)\",\"result\":\(code)}"
            case let .foreignApp(id):
                return "{\"publishedfileid\":\"\(id)\",\"result\":1,\"consumer_app_id\":1,\"title\":\"x\",\"visibility\":0,\"banned\":0}"
            }
        }.joined(separator: ",")
        return Data("{\"response\":{\"result\":1,\"resultcount\":\(payloads.count),\"publishedfiledetails\":[\(details)]}}".utf8)
    }

    @MainActor
    private static func makeLoader(body: Data, status: Int = 200) -> (WorkshopItemDetailsLoader, ItemDetailsStub.Type) {
        ItemDetailsStub.reset()
        ItemDetailsStub.configure(body: body, status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ItemDetailsStub.self]
        let metadata = SteamWorkshopMetadataService(session: URLSession(configuration: configuration))
        let loader = WorkshopItemDetailsLoader(metadata: metadata, retryPolicy: WorkshopRetryPolicy(sleep: { _ in }))
        return (loader, ItemDetailsStub.self)
    }
}

/// `GetPublishedFileDetails` describes a public Asset or Application like any
/// item; the inspector would then offer to download it as a wallpaper.
@Suite("Workshop required items rows")
struct DetailRequiredItemsTests {
    @Test("An Asset or Application dependency gets a Steam link, not an inspector page")
    func assetsOpenOnSteamOnly() {
        #expect(!DetailRequiredItemsSection.opensInApp(Self.item(tags: ["Asset"])))
        #expect(!DetailRequiredItemsSection.opensInApp(Self.item(tags: ["Scene", "Application"])))
        // Controls: wallpapers, tagged or not, open in the inspector.
        #expect(DetailRequiredItemsSection.opensInApp(Self.item(tags: ["Scene"])))
        #expect(DetailRequiredItemsSection.opensInApp(Self.item(tags: [])))
    }

    /// The rows show the same thumbnails the grid blurs; the section used to
    /// hand the row a bare URL, which cannot know the item is tagged Mature.
    @Test("A Mature dependency's thumbnail is blurred under the grid's setting")
    func matureRowsBlurUnderTheSetting() {
        #expect(DetailRequiredItemsSection.blursThumbnail(tags: ["Scene", "Mature"], blursMature: true))
        #expect(DetailRequiredItemsSection.blursThumbnail(tags: ["mature"], blursMature: true))
        // Controls: the setting is off, or the item is not Mature.
        #expect(!DetailRequiredItemsSection.blursThumbnail(tags: ["Mature"], blursMature: false))
        #expect(!DetailRequiredItemsSection.blursThumbnail(tags: ["Scene", "Everyone"], blursMature: true))
    }

    private static func item(tags: [String]) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: 1, rawTitle: "t", shortDescription: "", creatorID: nil, creatorPersonaName: nil,
            previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil,
            rating: nil, tags: tags, visibility: .public, isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=1")!
        )
    }
}

private final class ItemDetailsStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [String] = [] // guarded by `lock`
    private nonisolated(unsafe) static var body = Data() // guarded by `lock`
    private nonisolated(unsafe) static var status = 200 // guarded by `lock`

    static var bodies: [String] {
        lock.withLock { recorded }
    }

    static func configure(body: Data, status: Int) {
        lock.withLock {
            Self.body = body
            Self.status = status
        }
    }

    static func reset() {
        lock.withLock { recorded = [] }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
            ?? Self.readStream(request.httpBodyStream) ?? ""
        let (payload, status): (Data, Int) = Self.lock.withLock {
            Self.recorded.append(body)
            return (Self.body, Self.status)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> String? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }
}
#endif
