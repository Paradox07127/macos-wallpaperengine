import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Monitor overlay configuration")
struct MonitorOverlayConfigurationTests {

    @Test("Default overlay is off, desktop layer, default board")
    func defaults() {
        let d = MonitorOverlayConfiguration.default
        #expect(d.enabled == false)
        #expect(d.level == .desktop)
        #expect(d.music == .default)
        #expect(d.music.enabled == false)
        #expect(d.music.level == .desktop)
        #expect(d.board == MonitorBoardConfiguration.default)
    }

    @Test("A config written before the music split decodes with music off")
    func legacyConfigHasMusicOff() throws {
        let json = #"{ "enabled": true, "level": "front" }"#
        let decoded = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self, from: Data(json.utf8)
        )
        #expect(decoded.enabled == true)
        #expect(decoded.level == .front)
        #expect(decoded.music == .default)
    }

    @Test("The two module switches are independent")
    func musicSwitchIsIndependent() throws {
        let json = #"{ "enabled": false, "music": { "enabled": true, "level": "front" } }"#
        let decoded = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self, from: Data(json.utf8)
        )
        #expect(decoded.enabled == false)
        #expect(decoded.level == .desktop)
        #expect(decoded.music.enabled == true)
        #expect(decoded.music.level == .front)
    }

    @Test("An unknown music level or size falls back to the defaults")
    func unknownMusicEnumsFallBack() throws {
        let json = #"{ "music": { "enabled": true, "level": "middle", "size": "xl" } }"#
        let decoded = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self, from: Data(json.utf8)
        )
        #expect(decoded.music.enabled == true)
        #expect(decoded.music.level == .desktop)
        #expect(decoded.music.size == .medium)
    }

    /// The display's record is what carries the board, so an unreadable board is
    /// an unreadable record: the overlay decode fails and the caller's lossy
    /// dictionary drops that display instead of keeping it with a board the user
    /// never configured.
    @Test("A malformed board field makes the whole display entry undecodable")
    func malformedBoardFailsTheEntry() throws {
        let json = #"{ "enabled": true, "level": "front", "board": {"refreshHz": "bad"} }"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8))
        }
    }

    @Test("A null board is absent, not corrupt, so the entry survives with the default board")
    func nullBoardKeepsTheEntry() throws {
        let json = #"{ "enabled": true, "level": "front", "board": null }"#
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8))
        #expect(decoded.enabled == true)
        #expect(decoded.level == .front)
        #expect(decoded.board == MonitorBoardConfiguration.default)
    }

    /// The layer's position is its own now; a board that still carries the old
    /// widget must not put it back on the grid.
    @Test("A board written while the layer was a widget drops it at decode")
    func legacyMusicWidgetIsNotABoardWidget() throws {
        let json = """
        {"enabled":true,"board":{"widgets":[
        {"kind":"gpu","size":"m","x":0,"y":0},
        {"kind":"nowPlaying","size":"m","x":0.5,"y":0.5}
        ]}}
        """
        let decoded = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self, from: Data(json.utf8)
        )
        #expect(decoded.board.widgets.map(\.kind) == [.gpu])
        #expect(decoded.music == .default)
    }

    @Test("An empty object decodes to the defaults")
    func emptyObjectDecodesDefault() throws {
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data("{}".utf8))
        #expect(decoded == .default)
    }

    @Test("Round-trip preserves both module switches, both levels and the board")
    func roundTrip() throws {
        var overlay = MonitorOverlayConfiguration(
            enabled: true,
            level: .front,
            music: MusicOverlayConfiguration(
                enabled: true, level: .desktop, size: .large, x: 0.25, y: 0.5,
                options: ["style": .string("vinyl")]
            )
        )
        overlay.board.widgets = [MonitorWidgetPlacement(kind: .gpu, size: .medium, x: 0.1, y: 0.2)]
        overlay.board.mouseInteractionEnabled = true

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: data)
        #expect(decoded == overlay)
        #expect(decoded.level == .front)
        #expect(decoded.music == overlay.music)
        #expect(decoded.music.size == .large)
        #expect(decoded.music.options["style"]?.stringValue == "vinyl")
        #expect(decoded.board.widgets.map(\.kind) == [.gpu])
    }

    @Test("An unknown level string falls back to the desktop default")
    func unknownLevelFallsBack() throws {
        let json = #"{ "enabled": true, "level": "middle" }"#
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8))
        #expect(decoded.enabled == true)
        #expect(decoded.level == .desktop)
    }

    // MARK: - decodeIfPresent boundary

    private struct Probe: Decodable {
        let decoded: MonitorOverlayConfiguration?
        enum Key: String, CodingKey { case overlay }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            decoded = (try? c.decodeIfPresent(MonitorOverlayConfiguration.self, forKey: .overlay)) ?? nil
        }
    }

    private func decodeOverlay(_ json: String) throws -> MonitorOverlayConfiguration? {
        try JSONDecoder().decode(Probe.self, from: Data("{ \"overlay\": \(json) }".utf8)).decoded
    }

    @Test("Absent overlay slot decodes to nil")
    func absentSlotIsNil() throws {
        let decoded = try JSONDecoder().decode(Probe.self, from: Data("{}".utf8)).decoded
        #expect(decoded == nil)
    }

    @Test("A present overlay slot decodes its value")
    func presentSlotDecodes() throws {
        let decoded = try decodeOverlay(#"{ "enabled": true, "level": "front" }"#)
        #expect(decoded?.enabled == true)
        #expect(decoded?.level == .front)
    }

    @Test("A corrupt overlay slot decodes to nil, never a half-value")
    func corruptSlotIsNil() throws {
        // A malformed `board` now fails the whole slot too (see
        // `malformedBoardFailsTheEntry`), so `enabled` is no longer the only field
        // that gets here — it stays as the case that never had a tolerant path at
        // all, demonstrating a corrupt slot decoding to nil rather than a half value.
        let decoded = try decodeOverlay(#"{ "enabled": "not-a-bool" }"#)
        #expect(decoded == nil)
    }

    // MARK: - GlobalSettings carries the overlays

    @Test("GlobalSettings round-trips its per-display overlays")
    func globalSettingsRoundTripsOverlays() throws {
        var settings = GlobalSettings()
        settings.monitorOverlays = ["1552:16843:0": MonitorOverlayConfiguration(enabled: true, level: .front)]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)
        #expect(decoded.monitorOverlays["1552:16843:0"]?.enabled == true)
        #expect(decoded.monitorOverlays["1552:16843:0"]?.level == .front)
    }

    @Test("GlobalSettings with no overlays key decodes to empty")
    func globalSettingsWithoutOverlaysIsEmpty() throws {
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        #expect(decoded.monitorOverlays.isEmpty)
    }
}
