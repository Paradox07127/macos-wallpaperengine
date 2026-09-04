import Foundation
@testable import LiveWallpaperCore
import Testing

// MARK: - Fixtures

/// A configuration whose every capturable field is off its default, so a
/// round-trip that silently drops one shows up as an inequality rather than
/// passing on coincidental defaults.
private func richConfiguration(
    screenID: UInt32 = 777,
    fingerprint: String? = "source-panel-fingerprint"
) -> ScreenConfiguration {
    var config = ScreenConfiguration(
        screenID: screenID,
        wallpaper: .video(bookmarkData: Data([0x11, 0x22, 0x33])),
        playbackSpeed: 1.75,
        fitMode: .aspectFit,
        videoDisplayMode: .spanAllDisplays,
        frameRateLimit: .half,
        particleEffect: .snow,
        playlistBookmarks: [Data([0xAA]), Data([0xBB])],
        shufflePlaylist: true,
        playlistRotationMinutes: 17,
        playlistCursorIndex: 1,
        setAsLockScreen: true
    )
    config.displayFingerprint = fingerprint
    config.playlistPrimaryIndex = 2
    config.wallpaperMode = .schedule
    config.muted = false
    config.videoVolume = 0.42
    config.videoColorSpace = .displayP3
    config.sceneMouseInteractionEnabled = false
    config.sceneClickCaptureEnabled = true
    config.savedVideoPackageEntryName = "scene.pkg/main.mp4"
    return config
}

private func richOverlay() -> MonitorOverlayConfiguration {
    MonitorOverlayConfiguration(
        enabled: true,
        level: .front,
        music: MusicOverlayConfiguration(
            enabled: true,
            level: .front,
            size: .large,
            x: 0.1,
            y: 0.2
        ),
        board: MonitorBoardConfiguration(
            widgets: [
                MonitorWidgetPlacement(kind: .cpu, size: .large, x: 0.8, y: 0.9),
            ],
            refreshHz: 2.0,
            mouseInteractionEnabled: true
        )
    )
}

// MARK: - Schema

@Suite("ScreenScheme capture / apply")
struct ScreenSchemeTests {
    @Test("Applying a captured scheme reproduces every field but the display identity")
    func captureApplyRoundTripPreservesEveryOtherField() {
        let source = richConfiguration()
        // Held in a local: each `richOverlay()` call mints fresh widget UUIDs.
        let overlay = richOverlay()
        let scheme = ScreenScheme(
            name: "Desk setup",
            configuration: source,
            overlay: overlay,
            sourceDisplayName: "Studio Display"
        )

        let applied = scheme.rebound(to: 4242, fingerprint: "target-panel-fingerprint")

        // Whole-struct comparison on purpose: a field added to
        // ScreenConfiguration later is covered without editing this test.
        var expected = source
        expected.screenID = 4242
        expected.displayFingerprint = "target-panel-fingerprint"
        #expect(applied == expected)

        // Spot checks so a failure reads as something other than "structs differ".
        #expect(applied.screenID == 4242)
        #expect(applied.displayFingerprint == "target-panel-fingerprint")
        #expect(applied.playbackSpeed == source.playbackSpeed)
        #expect(applied.videoVolume == source.videoVolume)
        #expect(applied.effectConfig == source.effectConfig)
        #expect(applied.playlistBookmarks == source.playlistBookmarks)
        #expect(applied.videoDisplayMode == source.videoDisplayMode)
        #expect(scheme.overlay == overlay)
    }

    @Test("An archived scheme carries no live display identity")
    func archiveHoldsNoDisplayIdentity() throws {
        // MUTATION CHECK: delete the `Self.stripped(configuration)` line in
        // ScreenScheme.init (assign `configuration` directly) and this test must
        // go red — screenID comes back as 777 and displayFingerprint reappears.
        // Verified 2026-08-31; if it ever passes under that mutation the guard
        // has lost its teeth.
        let scheme = ScreenScheme(
            name: "Desk setup",
            configuration: richConfiguration(screenID: 777, fingerprint: "source-panel-fingerprint"),
            overlay: .default
        )

        #expect(scheme.configuration.screenID == ScreenScheme.unboundScreenID)
        #expect(scheme.configuration.screenID == 0)
        #expect(scheme.configuration.displayFingerprint == nil)

        // Through the encoder as well: `displayFingerprint` uses
        // `encodeIfPresent`, so a leaked value would appear as a JSON key.
        let data = try JSONEncoder().encode(scheme)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encodedConfiguration = try #require(object["configuration"] as? [String: Any])
        #expect(encodedConfiguration["screenID"] as? UInt32 == 0)
        #expect(encodedConfiguration["displayFingerprint"] == nil)
    }

    @Test("Overlay positions stay normalized across capture, archive and apply")
    func normalizedOverlayPositionsSurviveUnchanged() throws {
        // Cross-display adaptation is normalization + render-time conversion,
        // not a coordinate transform — so these numbers must come out bit-equal.
        let scheme = ScreenScheme(
            name: "Desk setup",
            configuration: richConfiguration(),
            overlay: richOverlay()
        )

        let data = try JSONEncoder().encode(scheme)
        let decoded = try JSONDecoder().decode(ScreenScheme.self, from: data)

        #expect(decoded.overlay.music.x == 0.1)
        #expect(decoded.overlay.music.y == 0.2)
        let widget = try #require(decoded.overlay.board.widgets.first)
        #expect(widget.x == 0.8)
        #expect(widget.y == 0.9)
        #expect(decoded.overlay == scheme.overlay)
    }

    @Test("Scheme round-trips through Codable with its identity and timestamps")
    func schemeRoundTripsThroughCodable() throws {
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        let scheme = ScreenScheme(
            name: "Desk setup",
            configuration: richConfiguration(),
            overlay: richOverlay(),
            createdAt: created,
            updatedAt: created,
            sourceDisplayName: "Studio Display"
        )

        let data = try JSONEncoder().encode(scheme)
        let decoded = try JSONDecoder().decode(ScreenScheme.self, from: data)

        #expect(decoded == scheme)
        #expect(decoded.id == scheme.id)
        #expect(decoded.sourceDisplayName == "Studio Display")
    }

    @Test("reboundToDisplay moves both identity fields together")
    func reboundMovesBothIdentityFields() {
        let rebound = richConfiguration().reboundToDisplay(9, fingerprint: nil)
        #expect(rebound.screenID == 9)
        #expect(rebound.displayFingerprint == nil)
    }
}

// MARK: - Store

@MainActor
private final class InMemorySchemePersistence: SchemePersisting {
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

@Suite("SchemeStore behavior")
@MainActor
struct SchemeStoreTests {
    private func makeStore(
        seed: [ScreenScheme] = []
    ) -> (SchemeStore, InMemorySchemePersistence) {
        let persistence = InMemorySchemePersistence()
        persistence.stored = seed
        return (SchemeStore(persistence: persistence), persistence)
    }

    @discardableResult
    private func addSample(
        to store: SchemeStore,
        name: String = "Desk setup"
    ) -> ScreenScheme {
        store.add(
            name: name,
            configuration: richConfiguration(),
            overlay: richOverlay(),
            sourceDisplayName: "Studio Display"
        )
    }

    @Test("add appends, strips identity and persists")
    func addAppendsAndPersists() {
        let (store, persistence) = makeStore()
        let scheme = addSample(to: store)

        #expect(store.schemes.map(\.id) == [scheme.id])
        #expect(scheme.configuration.screenID == ScreenScheme.unboundScreenID)
        #expect(scheme.configuration.displayFingerprint == nil)
        #expect(persistence.stored.count == 1)
        #expect(persistence.saveCount == 1)
    }

    @Test("add falls back to the captured display name when given a blank name")
    func blankNameFallsBackToSourceDisplayName() {
        let (store, _) = makeStore()
        let scheme = addSample(to: store, name: "   ")
        #expect(scheme.name == "Studio Display")
    }

    @Test("remove drops the matching id and persists once")
    func removeDropsMatchingID() {
        let (store, persistence) = makeStore()
        let first = addSample(to: store, name: "First")
        addSample(to: store, name: "Second")
        let saveCountBefore = persistence.saveCount

        store.remove(first.id)

        #expect(store.schemes.map(\.name) == ["Second"])
        #expect(persistence.stored.map(\.name) == ["Second"])
        #expect(persistence.saveCount == saveCountBefore + 1)
    }

    @Test("remove with an unknown id writes nothing")
    func removeUnknownIDDoesNotPersist() {
        let (store, persistence) = makeStore()
        addSample(to: store)
        let saveCountBefore = persistence.saveCount

        store.remove(UUID())

        #expect(store.schemes.count == 1)
        #expect(persistence.saveCount == saveCountBefore)
    }

    @Test("rename trims, applies and rejects a blank name")
    func renameTrimsAndRejectsBlank() {
        let (store, _) = makeStore()
        let scheme = addSample(to: store, name: "Old")

        store.rename(scheme.id, to: "  New name  ")
        #expect(store.schemes.first?.name == "New name")

        store.rename(scheme.id, to: "   ")
        #expect(store.schemes.first?.name == "New name")
    }

    @Test("Persistence load+save round-trips through a fresh store")
    func persistenceRoundTrip() {
        let (store, persistence) = makeStore()
        addSample(to: store, name: "Saved")

        let reloaded = SchemeStore(persistence: persistence)
        #expect(reloaded.schemes.map(\.name) == ["Saved"])
    }

    @Test("resetAfterSettingsCleared empties the in-memory list")
    func resetAfterSettingsClearedEmptiesStore() {
        let (store, _) = makeStore()
        addSample(to: store)
        #expect(!store.schemes.isEmpty)

        store.resetAfterSettingsCleared()

        #expect(store.schemes.isEmpty)
    }
}

@Suite("ScreenScheme decode resilience")
struct ScreenSchemeDecodeResilienceTests {
    /// Schemes are persisted as one array, so a scheme whose overlay cannot be
    /// read must not take the archive with it: `AtomicFileStore.read()` would
    /// return nil, `loadScreenSchemes()` would hand back `[]`, and the next
    /// capture would rewrite the file with only the new entry.
    @Test("A corrupt overlay costs that scheme its overlay, not the whole archive")
    func corruptOverlayKeepsTheArchive() throws {
        let good = ScreenScheme(
            name: "Good",
            configuration: ScreenConfiguration(screenID: 1, videoBookmarkData: Data([0x01])),
            overlay: MonitorOverlayConfiguration(enabled: true, level: .front)
        )
        let encoded = try JSONEncoder().encode([good, good])
        var json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        json[1]["name"] = "Broken"
        json[1]["overlay"] = [
            "enabled": true,
            "board": ["widgets": "corrupt-not-an-array"],
        ] as [String: Any]

        let payload = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode([ScreenScheme].self, from: payload)

        #expect(decoded.count == 2)
        #expect(decoded[0].overlay.level == .front)
        #expect(decoded[1].name == "Broken")
        #expect(decoded[1].overlay == MonitorOverlayConfiguration.default)
    }
}
