#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

/// `child_publishedfileid` answers "everything referencing this item"; the
/// Presets section is only meant to list the ones tagged `Preset`.
@Suite("Workshop detail presets query", .serialized)
struct DetailPresetsFilterTests {
    private static let wallpaperID: UInt64 = 1_081_733_658
    private static let storedKey = String(repeating: "a1b2c3d4", count: 4)

    @Test("Keyed: only Preset-tagged references survive, and the wallpaper itself is dropped")
    @MainActor
    func keyedKeepsPresetsOnly() async throws {
        PresetsQueryStub.reset()
        let services = Self.makeServices()
        services.hasWebAPIKey = true

        let outcome = try await DetailPresetsQuery.load(wallpaperID: Self.wallpaperID, services: services)
        guard case let .loaded(result) = outcome else {
            Issue.record("expected a loaded page, got \(outcome)")
            return
        }
        #expect(result.presets.map(\.id) == [10])
        #expect(result.presets.first?.tags.contains("Preset") == true)
        #expect(PresetsQueryStub.childQueryCount == 1)
        // The tag filter runs server-side (`child_publishedfileid` +
        // `requiredtags[0]=Preset`, measured 2026-09-07: total 16701 → 16697),
        // so a 51st preset is no longer lost behind 50 non-preset references
        // and Steam's `total` is the preset count as it stands.
        #expect(PresetsQueryStub.lastQuery["requiredtags[0]"] == "Preset")
        #expect(result.totalAvailable == 3)
    }

    /// `.task(id:)` re-runs when the key goes away, but the model's loaded
    /// list survives the re-run; reusing it would keep listing presets the
    /// keyed path can no longer fetch.
    @Test("Losing the key after a load re-runs the query instead of reusing the list")
    @MainActor
    func keyLossReloads() async {
        PresetsQueryStub.reset()
        let services = Self.makeServices()
        services.hasWebAPIKey = true
        let model = DetailPresetsModel()

        await model.load(.init(wallpaperID: Self.wallpaperID, keyless: services.isKeyless), services: services)
        guard case .loaded = model.state else {
            Issue.record("expected a loaded list, got \(model.state)")
            return
        }
        // Control: the same key reuses the list.
        await model.load(.init(wallpaperID: Self.wallpaperID, keyless: false), services: services)
        #expect(PresetsQueryStub.childQueryCount == 1)

        await services.noteAuthVerdict(accepted: false, keyFingerprint: WorkshopQueryService.keyFingerprint(Self.storedKey))
        #expect(services.isKeyless)
        await model.load(.init(wallpaperID: Self.wallpaperID, keyless: services.isKeyless), services: services)
        #expect(model.state == .keyless)
    }

    @Test("Keyless (key rejected): no request is issued and the section falls back to Steam")
    @MainActor
    func keylessIssuesNoRequest() async throws {
        PresetsQueryStub.reset()
        let services = Self.makeServices()
        // A stored key that Valve refused: the keyed path would still run if
        // the section only looked at `hasWebAPIKey`.
        services.hasWebAPIKey = true
        await services.noteAuthVerdict(accepted: false, keyFingerprint: WorkshopQueryService.keyFingerprint(Self.storedKey))
        #expect(services.isKeyless)

        let outcome = try await DetailPresetsQuery.load(wallpaperID: Self.wallpaperID, services: services)
        #expect(outcome == .keyless)
        #expect(PresetsQueryStub.childQueryCount == 0)
    }

    @Test("The Preset filter is a pure tag check")
    func presetFilter() {
        let items = [
            Self.item(id: 10, tags: ["Scene", "Preset"]),
            Self.item(id: 11, tags: ["Scene"]),
            Self.item(id: Self.wallpaperID, tags: ["Scene", "Preset"]),
        ]
        #expect(DetailPresetsQuery.presets(in: items, of: Self.wallpaperID).map(\.id) == [10])
    }

    /// The preset rows show the same thumbnails the grid blurs; the row used
    /// to hand `WorkshopPreviewImage` a bare URL, which cannot know the preset
    /// is tagged Mature.
    @Test("A Mature preset's thumbnail is blurred under the grid's setting")
    func matureRowsBlurUnderTheSetting() {
        #expect(DetailPresetsSection.blursThumbnail(for: Self.item(id: 10, tags: ["Preset", "Mature"]), blursMature: true))
        // Controls: the setting is off, or the preset is not Mature.
        #expect(!DetailPresetsSection.blursThumbnail(for: Self.item(id: 10, tags: ["Preset", "Mature"]), blursMature: false))
        #expect(!DetailPresetsSection.blursThumbnail(for: Self.item(id: 10, tags: ["Preset", "Everyone"]), blursMature: true))
    }

    private static func item(id: UInt64, tags: [String]) -> WorkshopQueryItem {
        WorkshopQueryItem(
            id: id, rawTitle: "t", shortDescription: "", creatorID: nil, creatorPersonaName: nil,
            previewImageURL: nil, fileSizeBytes: nil, timeUpdated: nil, subscriptionCount: nil,
            rating: nil, tags: tags, visibility: .public, isBanned: false,
            steamCommunityURL: URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")!
        )
    }

    @MainActor
    private static func makeServices() -> WorkshopServices {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("workshop-detail-presets-\(UUID().uuidString)", isDirectory: true)
        let keychain = WorkshopKeychainStore(
            directory: directory,
            slot: WorkshopKeychainSlotSpy(stored: storedKey).slot()
        )
        let cache = WorkshopQueryCache(directoryURL: directory.appendingPathComponent("cache"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PresetsQueryStub.self]
        let service = WorkshopQueryService(
            keychain: keychain,
            cache: cache,
            session: URLSession(configuration: config),
            countIssuedRequest: {}
        )
        return WorkshopServices(keychain: keychain, cache: cache, queryService: service)
    }
}

/// Three references to the wallpaper: one Preset, one plain Scene, one Web.
private final class PresetsQueryStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var childQueries = 0 // guarded by `lock`
    private nonisolated(unsafe) static var lastQueryItems: [String: String] = [:] // guarded by `lock`

    static var childQueryCount: Int {
        lock.withLock { childQueries }
    }

    /// Query items of the most recent request, by name.
    static var lastQuery: [String: String] {
        lock.withLock { lastQueryItems }
    }

    static func reset() {
        lock.withLock {
            childQueries = 0
            lastQueryItems = [:]
        }
    }

    private static let body = Data("""
    {"response":{"total":3,"publishedfiledetails":[\
    {"result":1,"publishedfileid":"10","title":"Preset A","visibility":0,"banned":false,\
    "tags":[{"tag":"Scene","display_name":"Scene"},{"tag":"Preset","display_name":"Preset"}]},\
    {"result":1,"publishedfileid":"11","title":"Plain scene","visibility":0,"banned":false,\
    "tags":[{"tag":"Scene","display_name":"Scene"}]},\
    {"result":1,"publishedfileid":"12","title":"Web thing","visibility":0,"banned":false,\
    "tags":[{"tag":"Web","display_name":"Web"}]}]}}
    """.utf8)

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        Self.lock.withLock {
            Self.lastQueryItems = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            if query.contains(where: { $0.name == "child_publishedfileid" }) {
                Self.childQueries += 1
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
