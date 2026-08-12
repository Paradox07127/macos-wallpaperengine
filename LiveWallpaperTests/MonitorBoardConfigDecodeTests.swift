import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Monitor board config decode (MonitorOverlayConfiguration boundary)")
struct MonitorBoardConfigDecodeTests {

    private func decodeBoard(_ boardJSON: String) throws -> MonitorBoardConfiguration {
        let json = "{\"enabled\":true,\"level\":\"desktop\",\"board\":\(boardJSON)}"
        return try JSONDecoder().decode(MonitorOverlayConfiguration.self, from: Data(json.utf8)).board
    }

    private func encodeString(_ overlay: MonitorOverlayConfiguration) throws -> String {
        String(data: try JSONEncoder().encode(overlay), encoding: .utf8) ?? ""
    }

    @Test("A board payload decodes its widgets, sizes and board-level fields")
    func boardPayloadDecodes() throws {
        let board = try decodeBoard("""
        {"schemaVersion":2,"gridColumns":12,"refreshHz":0.75,"mouseInteractionEnabled":true,"widgets":[{"kind":"gpu","size":"m","x":0.0,"y":0.0},{"kind":"disk","size":"s","x":0.5,"y":0.5}]}
        """)
        #expect(board.widgets.map(\.kind) == [.gpu, .disk])
        #expect(board.widgets.map(\.size) == [.medium, .small])
        #expect(board.refreshHz == 0.75)
        #expect(board.mouseInteractionEnabled == true)
    }

    @Test("A widgets-only config keeps exactly the placements it lists")
    func widgetsOnlyConfigKeepsPlacements() throws {
        let board = try decodeBoard(#"{"widgets":[{"kind":"network","size":"s","x":0.1,"y":0.1}]}"#)
        #expect(board.widgets.map(\.kind) == [.network])
    }

    @Test("A retired kind (clock/health) is dropped on decode, keeping the rest")
    func retiredKindsAreDropped() throws {
        let board = try decodeBoard("""
        {"widgets":[{"kind":"clock","size":"s","x":0.1,"y":0.1},{"kind":"health","size":"s","x":0.3,"y":0.1},{"kind":"cpu","size":"m","x":0.5,"y":0.1}]}
        """)
        #expect(board.widgets.map(\.kind) == [.cpu])
    }

    @Test("An absent board decodes to the default board")
    func absentConfigIsDefaultBoard() throws {
        let overlay = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self,
            from: Data(#"{"enabled":true}"#.utf8)
        )
        #expect(overlay.board == MonitorBoardConfiguration.default)
    }

    @Test("A corrupt display entry is dropped without taking the other displays with it")
    func corruptEntryDropsOnlyItself() throws {
        let json = """
        {
          "monitorOverlays": {
            "broken": {"enabled":true,"board":{"widgets":"corrupt-not-an-array"}},
            "1552:16843:0": {"enabled":true,"level":"front"}
          }
        }
        """
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
        #expect(settings.monitorOverlays["broken"] == nil)
        #expect(settings.monitorOverlays["1552:16843:0"]?.level == .front)
    }

    @Test("Unknown config keys are ignored on decode and never re-persisted")
    func unknownKeysIgnoredAndNotPersisted() throws {
        let board = try decodeBoard(#"{"systemEnabled":true,"agentsEnabled":false,"showTopProcesses":true}"#)
        #expect(board.widgets.map(\.kind) == MonitorBoardConfiguration.default.widgets.map(\.kind))
        #expect(board.gridColumns == 10)
        #expect(board.refreshHz == 1.0)
        #expect(board.mouseInteractionEnabled == false)

        let reEncoded = try encodeString(MonitorOverlayConfiguration(board: board))
        #expect(reEncoded.contains("\"widgets\""))
        #expect(reEncoded.contains("\"schemaVersion\""))
        #expect(!reEncoded.contains("systemEnabled"))
        #expect(!reEncoded.contains("agentsEnabled"))
        #expect(!reEncoded.contains("showTopProcesses"))
    }

    @Test("A board config round-trips unchanged through MonitorOverlayConfiguration")
    func boardRoundTrip() throws {
        var board = MonitorBoardConfiguration()
        board.gridColumns = 12
        board.refreshHz = 1.0
        board.mouseInteractionEnabled = true
        board.widgets = [
            MonitorWidgetPlacement(kind: .cpu, size: .medium, x: 0.0, y: 0.0),
            MonitorWidgetPlacement(kind: .fleet, size: .medium, x: 0.4, y: 0.2),
        ]
        let overlay = MonitorOverlayConfiguration(enabled: true, level: .front, board: board)

        let decoded = try JSONDecoder().decode(
            MonitorOverlayConfiguration.self,
            from: Data(try encodeString(overlay).utf8)
        )
        #expect(decoded == overlay)
    }

    @Test("A board payload decodes through the per-display slot on GlobalSettings")
    func globalSettingsSlotDecodes() throws {
        let json = """
        {
          "monitorOverlays": {
            "1552:16843:0": {"enabled":true,"level":"front","board":{"schemaVersion":2,"widgets":[{"kind":"gpu","size":"m","x":0.0,"y":0.0}]}}
          }
        }
        """
        let settings = try JSONDecoder().decode(GlobalSettings.self, from: Data(json.utf8))
        let overlay = try #require(settings.monitorOverlays["1552:16843:0"])
        #expect(overlay.enabled)
        #expect(overlay.level == .front)
        #expect(overlay.board.widgets.map(\.kind) == [.gpu])
    }
}
