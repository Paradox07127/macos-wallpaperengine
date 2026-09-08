import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Nixie clock configuration")
struct NixieClockConfigurationTests {
    @Test func clockIsOutsideWidgetCatalog() {
        #expect(!MonitorWidgetKind.allCases.contains(.nixieClock))
    }

    @Test func legacyClockMovesIntoIndependentConfiguration() throws {
        let json = #"{"enabled":true,"board":{"widgets":[{"kind":"nixieClock","x":0.25,"y":0.5},{"kind":"cpu"}]}}"#
        let overlay = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8))
        #expect(overlay.board.widgets.map(\.kind) == [.cpu])
        let encoded = try JSONEncoder().encode(overlay)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let clock = try #require(object["clock"] as? [String: Any])
        #expect(clock["enabled"] as? Bool == true)
        #expect(clock["x"] as? Double == 0.25)
    }

    @Test func savedClockSurvivesDecoding() throws {
        let json = #"{"widgets":[{"kind":"nixieClock","size":"m","x":0.25,"y":0.5}]}"#
        let board = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: Data(json.utf8))
        #expect(board.widgets.count == 1)
        #expect(board.widgets.first?.kind.rawValue == "nixieClock")
        #expect(try JSONDecoder().decode(MonitorBoardConfiguration.self, from: JSONEncoder().encode(board)) == board)
    }

    @Test func independentOptionsRoundTripAndKeepWidgetsOff() throws {
        let clock = ClockOverlayConfiguration(enabled: true, level: .front, x: 0.2, y: 0.7, width: 731.5,
                                              uses24HourTime: false, padsHour: false, blinksSeparators: true, opacity: 0.6)
        let overlay = MonitorOverlayConfiguration(clock: clock)
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: JSONEncoder().encode(overlay))
        #expect(decoded == overlay)
        #expect(!decoded.enabled && !decoded.music.enabled && decoded.clock.enabled)
    }

    @Test func explicitClockWinsOverLegacyPlacement() throws {
        let json = #"{"enabled":true,"clock":{"enabled":false,"width":620},"board":{"widgets":[{"kind":"nixieClock"}]}}"#
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8))
        #expect(decoded.board.widgets.isEmpty)
        #expect(!decoded.clock.enabled)
        #expect(decoded.clock.width == 620)
    }

    @Test func malformedGeometryIsBounded() throws {
        let json = #"{"clock":{"width":-1,"x":9,"y":-2,"opacity":20,"level":"future"}}"#
        let decoded = try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8))
        #expect(decoded.clock.width == 180 && decoded.clock.x == 1 && decoded.clock.y == 0)
        #expect(decoded.clock.opacity == 1 && decoded.clock.level == .desktop)
        let invalid = ClockOverlayConfiguration(width: .nan, opacity: .infinity)
        #expect(invalid.width == 480 && invalid.opacity == 1)
    }
}
