import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("System overview configuration")
struct SystemOverviewConfigurationTests {
    @Test("System overview is a catalog widget with medium and large layouts")
    func catalogSizes() throws {
        let kind = try #require(MonitorWidgetKind(rawValue: "systemOverview"))
        #expect(kind.allowedSizes == [.medium, .large])
    }

    @Test("Saved overview options and placement survive board decoding")
    func roundTrip() throws {
        let json = #"{"widgets":[{"kind":"systemOverview","size":"l","x":0.25,"y":0.5,"options":{"showSensors":false,"gpuSampleSeconds":10}}]}"#
        let board = try JSONDecoder().decode(MonitorBoardConfiguration.self, from: Data(json.utf8))
        #expect(board.widgets.count == 1)
        let widget = try #require(board.widgets.first)
        #expect(widget.kind.rawValue == "systemOverview")
        #expect(widget.size == .large)
        #expect(widget.x == 0.25)
        #expect(widget.options["showSensors"]?.boolValue == false)
        #expect(widget.options["gpuSampleSeconds"]?.numberValue == 10)
        #expect(try JSONDecoder().decode(MonitorBoardConfiguration.self, from: JSONEncoder().encode(board)) == board)
    }
}
