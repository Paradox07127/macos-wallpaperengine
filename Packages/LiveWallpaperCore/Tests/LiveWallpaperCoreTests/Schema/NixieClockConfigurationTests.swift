import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Nixie clock configuration")
struct NixieClockConfigurationTests {
    @Test func catalogSizes() throws {
        let kind = try #require(MonitorWidgetKind(rawValue: "nixieClock"))
        #expect(kind.allowedSizes == [.medium, .large])
    }

    @Test func savedClockSurvivesDecoding() throws {
        let json = #"{"widgets":[{"kind":"nixieClock","size":"m","x":0.25,"y":0.5}]}"#
        let board = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: Data(json.utf8))
        #expect(board.widgets.count == 1)
        #expect(board.widgets.first?.kind.rawValue == "nixieClock")
        #expect(try JSONDecoder().decode(MonitorBoardConfiguration.self, from: JSONEncoder().encode(board)) == board)
    }
}
