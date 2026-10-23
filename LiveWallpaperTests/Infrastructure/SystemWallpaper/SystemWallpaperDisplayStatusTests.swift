import Foundation
@testable import LiveWallpaper
import Testing

@Suite("System wallpaper display status")
struct SystemWallpaperDisplayStatusTests {
    private func follow(_ phases: [UInt32: SystemWallpaperFollowState.Phase]) -> SystemWallpaperFollowState {
        var state = SystemWallpaperFollowState()
        for (id, phase) in phases {
            state.displays[id] = .init(displayID: id, title: "Forest \(id)", sourceKey: "key-\(id)", phase: phase)
        }
        return state
    }

    @Test("A ready copy plays only on a display that shows the tile")
    func readyNeedsTheTile() {
        let rows = SystemWallpaperDisplayStatus.evaluate(
            follow: follow([1: .ready(itemID: "a"), 2: .ready(itemID: "b")]),
            showsTile: { $0 == 1 }, playbackFailures: [:], preparationProgress: nil
        )
        #expect(rows.map(\.state) == [.playing, .notUsingTile])
        #expect(rows.map(\.title) == ["Forest 1", "Forest 2"])
    }

    @Test("A playback failure on the resolved copy outranks playing")
    func playbackFailureWins() {
        let rows = SystemWallpaperDisplayStatus.evaluate(
            follow: follow([1: .ready(itemID: "a")]),
            showsTile: { _ in true }, playbackFailures: ["a": "scene.circuit.open", "other": "scene.stalled"],
            preparationProgress: nil
        )
        #expect(rows.map(\.state) == [.playbackFailed(code: "scene.circuit.open")])
    }

    @Test("Queued waits only while the tile is shown; other phases pass through")
    func phasesMap() {
        let rows = SystemWallpaperDisplayStatus.evaluate(
            follow: follow([1: .queued, 2: .queued, 3: .preparing, 4: .needsRecording, 5: .failed(message: "No source"), 6: .cancelled]),
            showsTile: { $0 != 2 }, playbackFailures: [:], preparationProgress: 0.4
        )
        #expect(rows.map(\.state) == [
            .queued, .notUsingTile, .preparing(progress: 0.4), .needsRecording, .preparationFailed(message: "No source"),
            .cancelled,
        ])
    }
}
