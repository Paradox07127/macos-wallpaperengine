import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// What a drag's drop asked for.
@MainActor
private final class DropCalls {
    var displays: [CGDirectDisplayID] = []
    var allDisplays = 0
}

/// The strip as `DisplayFloatLayer` reports it: two thumbnails in a run wide enough for both, then All Displays.
@MainActor
private func strippedController() -> LibraryDragController {
    let drag = LibraryDragController()
    drag.thumbnailFrames = [
        1: CGRect(x: 300, y: 24, width: 149, height: 84),
        2: CGRect(x: 461, y: 24, width: 149, height: 84),
    ]
    drag.runFrame = CGRect(x: 290, y: 24, width: 340, height: 84)
    drag.applyAllFrame = CGRect(x: 660, y: 51, width: 120, height: 30)
    return drag
}

@MainActor
private func payload(recording calls: DropCalls) -> LibraryDragController.Payload {
    let bookmark = WallpaperBookmark(label: "Dragged", content: .video(bookmarkData: Data([1])))
    let item = LiveWallpaper.LibraryItem(
        id: "bookmark:\(bookmark.id)", title: "Dragged", kind: .video, source: .bookmark(bookmark),
        isSteam: false, createdAt: bookmark.createdAt, lastUsedAt: nil, onDisplays: [],
        thumbnail: .bookmark(bookmark), metadata: nil, isVariant: false, parentID: nil, isSupported: true
    )
    return LibraryDragController.Payload(
        item: item, image: nil,
        actions: WallpaperModalActions(applyTo: { calls.displays.append($0) }, applyToAllDisplays: { calls.allDisplays += 1 })
    )
}

/// The drop half of every library drag toward the displays, the modal's and the grid's.
@Suite("Library drag controller")
@MainActor
struct LibraryDragControllerTests {
    private static let start = CGPoint(x: 400, y: 420)
    private static let overSecond = CGPoint(x: 530, y: 66)
    private static let overAll = CGPoint(x: 700, y: 66)
    private static let nowhere = CGPoint(x: 900, y: 300)

    @Test("A release over a thumbnail applies to that display, and one over All Displays to every display")
    func releaseAppliesWhereItLands() {
        let calls = DropCalls()
        let drag = strippedController()
        drag.begin(payload(recording: calls), at: Self.start)
        #expect(drag.point == Self.start && drag.target == nil)
        drag.move(to: Self.overSecond)
        #expect(drag.target == .display(2))
        drag.end(at: Self.overSecond)
        #expect(calls.displays == [2] && calls.allDisplays == 0)
        #expect(drag.point == nil && drag.payload == nil, "a drop that applied left the strip up")

        drag.begin(payload(recording: calls), at: Self.start)
        drag.end(at: Self.overAll)
        #expect(calls.displays == [2] && calls.allDisplays == 1)
    }

    @Test("A miss applies nothing, shakes the ghost once and takes the strip down after the shake")
    func missShakesThenClears() async {
        let calls = DropCalls()
        let drag = strippedController()
        drag.begin(payload(recording: calls), at: Self.start)
        drag.end(at: Self.nowhere)
        #expect(calls.displays.isEmpty && calls.allDisplays == 0)
        #expect(drag.shakeTrigger == 1)
        #expect(drag.point != nil, "the ghost left before it could shake")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(drag.point == nil, "the strip stayed up after the shake")
    }

    @Test("A drag started while the last miss still shakes is not taken down with it")
    func newDragOutlivesTheOldShake() async {
        let drag = strippedController()
        drag.begin(payload(recording: DropCalls()), at: Self.start)
        drag.end(at: Self.nowhere)
        drag.begin(payload(recording: DropCalls()), at: Self.start)
        try? await Task.sleep(for: .milliseconds(500))
        #expect(drag.point == Self.start, "the old miss's clean-up ended the new drag")
    }

    @Test("After a cancel the rest of that gesture neither moves the ghost nor applies; the next drag starts clean")
    func cancelIgnoresTheRestOfTheGesture() {
        let calls = DropCalls()
        let drag = strippedController()
        drag.begin(payload(recording: calls), at: Self.start)
        drag.cancel()
        #expect(drag.point == nil)
        drag.move(to: Self.overSecond)
        #expect(drag.point == nil, "a move after the cancel brought the ghost back")
        drag.end(at: Self.overSecond)
        #expect(calls.displays.isEmpty, "the cancelled gesture still applied on release")

        drag.begin(payload(recording: calls), at: Self.start)
        drag.end(at: Self.overSecond)
        #expect(calls.displays == [2], "the drag after a cancelled one stayed cancelled")
    }
}
