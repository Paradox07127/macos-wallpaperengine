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
        #expect(d.musicEnabled == false)
        #expect(d.musicLevel == .desktop)
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
        #expect(decoded.musicEnabled == false)
        #expect(decoded.musicLevel == .desktop)
    }

    @Test("The two module switches are independent")
    func musicSwitchIsIndependent() throws {
        let json = #"{ "enabled": false, "musicEnabled": true, "musicLevel": "front" }"#
        let decoded = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self, from: Data(json.utf8)
        )
        #expect(decoded.enabled == false)
        #expect(decoded.level == .desktop)
        #expect(decoded.musicEnabled == true)
        #expect(decoded.musicLevel == .front)
    }

    @Test("An unknown music level string falls back to the desktop default")
    func unknownMusicLevelFallsBack() throws {
        let json = #"{ "musicEnabled": true, "musicLevel": "middle" }"#
        let decoded = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self, from: Data(json.utf8)
        )
        #expect(decoded.musicEnabled == true)
        #expect(decoded.musicLevel == .desktop)
    }

    @Test("An empty object decodes to the defaults")
    func emptyObjectDecodesDefault() throws {
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data("{}".utf8))
        #expect(decoded == .default)
    }

    @Test("Round-trip preserves both module switches, both levels and the board")
    func roundTrip() throws {
        var overlay = MonitorOverlayConfiguration(
            enabled: true, level: .front, musicEnabled: true, musicLevel: .desktop
        )
        overlay.board.widgets = [MonitorWidgetPlacement(kind: .gpu, size: .medium, x: 0.1, y: 0.2)]
        overlay.board.mouseInteractionEnabled = true

        let data = try JSONEncoder().encode(overlay)
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: data)
        #expect(decoded == overlay)
        #expect(decoded.level == .front)
        #expect(decoded.musicEnabled == true)
        #expect(decoded.musicLevel == .desktop)
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
        let decoded = try decodeOverlay(#"{ "board": "not-an-object" }"#)
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
