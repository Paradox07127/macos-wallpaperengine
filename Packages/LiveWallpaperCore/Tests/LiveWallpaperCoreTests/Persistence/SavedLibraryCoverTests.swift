import Foundation
@testable import LiveWallpaperCore
import Testing

// MARK: - Doubles

@MainActor
private final class MemoryBookmarkPersistence: BookmarkPersisting {
    var stored: [WallpaperBookmark] = []
    private(set) var saveCount = 0

    func load() -> [WallpaperBookmark] {
        stored
    }

    func save(_ bookmarks: [WallpaperBookmark]) {
        stored = bookmarks
        saveCount += 1
    }
}

@MainActor
private final class MemorySchemePersistence: SchemePersisting {
    var stored: [ScreenScheme] = []
    private(set) var saveCount = 0

    func load() -> [ScreenScheme] {
        stored
    }

    func save(_ schemes: [ScreenScheme]) {
        stored = schemes
        saveCount += 1
    }
}

private func configuration(screenID: UInt32 = 777) -> ScreenConfiguration {
    var config = ScreenConfiguration(
        screenID: screenID,
        wallpaper: .video(bookmarkData: Data([0x01, 0x02]))
    )
    config.displayFingerprint = "source-panel"
    config.playbackSpeed = 1.5
    return config
}

// MARK: - Schema

@Suite("Saved library covers")
struct SavedLibraryCoverTests {
    @Test("A scheme's cover file name survives the archive round trip")
    func schemeCoverRoundTrips() throws {
        // MUTATION CHECK: drop `coverFileName` from ScreenScheme.CodingKeys and
        // this goes red — the encoder stops writing the key, so the decode
        // returns nil.
        let scheme = ScreenScheme(
            name: "Desk",
            configuration: configuration(),
            overlay: .default,
            coverFileName: "8D1F.png"
        )
        let data = try JSONEncoder().encode(scheme)
        let decoded = try JSONDecoder().decode(ScreenScheme.self, from: data)
        #expect(decoded.coverFileName == "8D1F.png")
    }

    @Test("A scheme archived before covers existed still decodes")
    func schemeWithoutCoverDecodes() throws {
        // The hand-written `init(from:)` is the only decode path, so a missing
        // key has to be tolerated there rather than by a synthesized decoder.
        let json = try """
        {
          "id": "\(UUID().uuidString)",
          "name": "Legacy",
          "createdAt": 0,
          "updatedAt": 0,
          "configuration": \(String(data: JSONEncoder().encode(configuration()), encoding: .utf8)!),
          "overlay": \(String(data: JSONEncoder().encode(MonitorOverlayConfiguration.default), encoding: .utf8)!)
        }
        """
        let decoded = try JSONDecoder().decode(ScreenScheme.self, from: Data(json.utf8))
        #expect(decoded.coverFileName == nil)
        #expect(decoded.name == "Legacy")
    }

    @Test("A bookmark's cover file name survives the archive round trip")
    func bookmarkCoverRoundTrips() throws {
        let bookmark = WallpaperBookmark(
            label: "Rain",
            content: .video(bookmarkData: Data([0x09])),
            coverFileName: "AB12.png"
        )
        let data = try JSONEncoder().encode(bookmark)
        let decoded = try JSONDecoder().decode(WallpaperBookmark.self, from: data)
        #expect(decoded.coverFileName == "AB12.png")
    }

    @Test("A bookmark archived before covers existed still decodes")
    func bookmarkWithoutCoverDecodes() {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "label": "Legacy",
          "createdAt": 0,
          "content": {"video": {"bookmarkData": "CQ=="}}
        }
        """
        let decoded = try? JSONDecoder().decode(WallpaperBookmark.self, from: Data(json.utf8))
        #expect(decoded?.coverFileName == nil)
    }

    // MARK: - Stores

    @MainActor
    @Test("Setting a cover persists and is idempotent")
    func setCoverPersistsOnce() {
        let persistence = MemoryBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let bookmark = store.add(label: "Rain", content: .video(bookmarkData: Data([0x09])))
        let savesAfterAdd = persistence.saveCount

        store.setCover("cover.png", for: bookmark.id)
        #expect(store.bookmarks.first?.coverFileName == "cover.png")
        #expect(persistence.saveCount == savesAfterAdd + 1)

        // Re-setting the same name must not rewrite the archive: the capture
        // path can land twice for one entry.
        store.setCover("cover.png", for: bookmark.id)
        #expect(persistence.saveCount == savesAfterAdd + 1)
    }

    @MainActor
    @Test("A cover set for an entry that is gone changes nothing")
    func setCoverIgnoresMissingEntry() {
        let persistence = MemoryBookmarkPersistence()
        let store = BookmarkStore(persistence: persistence)
        let savesAtStart = persistence.saveCount
        store.setCover("cover.png", for: UUID())
        #expect(persistence.saveCount == savesAtStart)
    }

    @MainActor
    @Test("Replacing a scheme keeps its identity, re-strips the display, and drops the stale cover")
    func replaceKeepsIdentityAndClearsCover() throws {
        // MUTATION CHECK: build the replacement by mutating the existing scheme's
        // `configuration` directly instead of going through `ScreenScheme.init`
        // and the screenID assertion goes red — the live 999 is archived.
        let persistence = MemorySchemePersistence()
        let store = SchemeStore(persistence: persistence)
        let original = store.add(
            name: "Desk",
            configuration: configuration(),
            overlay: .default,
            sourceDisplayName: "Studio"
        )
        store.setCover("old.png", for: original.id)

        let replaced = try #require(
            store.replace(
                original.id,
                configuration: configuration(screenID: 999),
                overlay: .default,
                sourceDisplayName: "Desk Panel"
            )
        )

        #expect(replaced.id == original.id)
        #expect(replaced.name == original.name)
        #expect(replaced.createdAt == original.createdAt)
        #expect(replaced.updatedAt >= original.updatedAt)
        #expect(replaced.sourceDisplayName == "Desk Panel")
        // The archive must never hold a live display's identity, whichever way
        // the scheme was written.
        #expect(replaced.configuration.screenID == ScreenScheme.unboundScreenID)
        #expect(replaced.configuration.displayFingerprint == nil)
        #expect(replaced.configuration.playbackSpeed == 1.5)
        // A cover is a still of the *old* contents; keeping it would caption the
        // new capture with the setup it just overwrote.
        #expect(replaced.coverFileName == nil)
        #expect(store.schemes.count == 1)
    }

    @MainActor
    @Test("Replacing an id that is not in the archive writes nothing")
    func replaceMissingSchemeIsANoOp() {
        let persistence = MemorySchemePersistence()
        let store = SchemeStore(persistence: persistence)
        let savesAtStart = persistence.saveCount
        #expect(store.replace(UUID(), configuration: configuration(), overlay: .default) == nil)
        #expect(persistence.saveCount == savesAtStart)
    }
}
