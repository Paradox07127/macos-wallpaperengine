import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Edit Desk stage model")
struct EditDeskStageModelTests {
    private final class RecordingEngine: EditDeskStageEngine {
        var log: [String] = []

        func setProgress(_ progress: Double, animated: Bool) {
            log.append("progress \(progress) animated=\(animated)")
        }

        func flyTile(display: StageDisplay.ID, to rectInWindow: CGRect) async {
            log.append("fly \(display) → \(Int(rectInWindow.minX)),\(Int(rectInWindow.minY))")
        }

        func updateFlightDestination(display: StageDisplay.ID, to rectInWindow: CGRect) {
            log.append("retarget \(display) → \(Int(rectInWindow.minX)),\(Int(rectInWindow.minY))")
        }

        func returnTile(display: StageDisplay.ID) async {
            log.append("return \(display)")
        }

        func setTileConcealed(display: StageDisplay.ID, _ concealed: Bool) {
            log.append("conceal \(display) \(concealed)")
        }

        func crossfadeCover(display: StageDisplay.ID, to image: CGImage, duration: TimeInterval) {
            log.append("crossfade \(display) \(image.width)×\(image.height) \(duration)")
        }

        func shake(card: StageCard.ID) {
            log.append("shake \(card)")
        }

        func shake(display: StageDisplay.ID) {
            log.append("shake display \(display)")
        }

        func escape() -> Bool {
            log.append("escape")
            return false
        }
    }

    private static func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    @Test("Without an engine, setProgress lands directly and integers count as snapped")
    func setProgressWithoutEngine() async {
        let model = EditDeskStageModel()
        model.setProgress(1.3, animated: false)
        #expect(model.progress == 1.3)
        #expect(model.snappedIndex == 0)

        model.setProgress(2, animated: true)
        #expect(model.progress == 2)
        #expect(model.snappedIndex == 2)

        model.setProgress(2.9, animated: false)
        #expect(model.progress == 2, "Out-of-range progress clamps to the last rest state")

        var iterator = model.events.makeAsyncIterator()
        #expect(await iterator.next() == .snapped(2))
    }

    @Test("Commands forward to the attached engine and leave the outputs alone")
    func commandsForwardToEngine() async throws {
        let model = EditDeskStageModel()
        let engine = RecordingEngine()
        model.engine = engine

        model.setProgress(0.5, animated: true)
        #expect(model.progress == 0, "The engine owns the animated value; the model waits for its report")
        await model.flyTile(display: 7, to: CGRect(x: 230, y: 76, width: 820, height: 461))
        model.setTileConcealed(display: 7, true)
        model.setTileConcealed(display: 7, false)
        await model.returnTile(display: 7)
        try model.crossfadeCover(display: 7, to: Self.makeImage(), duration: 0.45)
        model.shake(card: "card-a")

        #expect(engine.log == [
            "progress 0.5 animated=true",
            "fly 7 → 230,76",
            "conceal 7 true",
            "conceal 7 false",
            "return 7",
            "crossfade 7 2×1 0.45",
            "shake card-a",
        ])
    }

    @Test("Engine reports flow into the outputs and the event stream in order")
    func reportsAndEvents() async {
        let model = EditDeskStageModel()
        model.report(progress: 0.4)
        model.report(snappedIndex: 1)
        model.report(hoveredCard: "card-b")
        model.report(hoveredDisplay: 3)
        model.report(dropTarget: 3)
        #expect(model.progress == 0.4)
        #expect(model.snappedIndex == 1)
        #expect(model.hoveredCard == "card-b")
        #expect(model.hoveredDisplay == 3)
        #expect(model.dropTarget == 3)

        model.emit(.cardTapped("card-b"))
        model.emit(.dropped(card: "card-b", onto: 3))
        model.emit(.playbackTapped(3, .toggle))
        model.emit(.emptyActionTapped(3, .chooseFile))
        model.emit(.emptyActionTapped(3, .pasteURL))
        var iterator = model.events.makeAsyncIterator()
        #expect(await iterator.next() == .cardTapped("card-b"))
        #expect(await iterator.next() == .dropped(card: "card-b", onto: 3))
        #expect(await iterator.next() == .playbackTapped(3, .toggle))
        #expect(await iterator.next() == .emptyActionTapped(3, .chooseFile))
        #expect(await iterator.next() == .emptyActionTapped(3, .pasteURL))
    }

    @Test("Display and card equality ignore image identity only when the image is the same object")
    func equalityTracksImageIdentity() throws {
        let image = try Self.makeImage()
        let base = StageDisplay(
            id: 1, fingerprint: "fp", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false,
            name: "MPG", badgeText: "EXTERNAL · 32″ · 240 Hz", statusText: "主屏", cover: image, state: .ok
        )
        var same = base
        same.cover = image
        #expect(same == base)
        var other = base
        other.cover = try Self.makeImage()
        #expect(other != base)

        // Everything the stage draws has to reach it: a field left out of `==` is a silent freeze.
        for mutate in [
            { (display: inout StageDisplay) in display.wallpaperTitle = "Aurora" },
            { display in display.wallpaperKind = "Video" },
            { display in display.showsPlaylistControls = true },
            { display in display.canChangePlaylistEntry = true },
            { display in display.canTogglePlayback = true },
            { display in display.intendsToPlay = true },
        ] {
            var changed = base
            mutate(&changed)
            #expect(changed != base)
        }

        let chip = StageFailureChip(symbol: "xmark.octagon.fill", text: "Can't run on this Mac", tint: CGColor(gray: 0.5, alpha: 1))
        var failed = base
        failed.state = .failed(chip)
        var failedAgain = base
        failedAgain.state = .failed(StageFailureChip(symbol: chip.symbol, text: chip.text, tint: CGColor(gray: 0.5, alpha: 1)))
        #expect(failed == failedAgain, "Equal chips compare by value, not by CGColor identity")
    }

    @Test("The transport glyph offers the opposite of what the user asked for, a policy pause included")
    func playbackGlyphFollowsTheIntent() {
        var display = StageDisplay(
            id: 1, fingerprint: "fp", frame: .zero, isBuiltin: false, name: "MPG",
            badgeText: "", statusText: "", cover: nil, state: .ok
        )
        display.intendsToPlay = true
        #expect(display.playbackGlyph == "pause.fill")
        // A policy pause stops the picture but keeps the intent to play, so the button still pauses.
        display.state = .paused(reasonText: "On battery")
        #expect(display.playbackGlyph == "pause.fill")
        display.intendsToPlay = false
        #expect(display.playbackGlyph == "play.fill")
    }

    @Test("The now-playing badge names the leftmost display it is set on, counts the rest, and is live only while one draws it")
    func nowPlayingNamesTheLeftmostDisplay() throws {
        func display(_ id: StageDisplay.ID, _ name: String, x: CGFloat, _ state: StageDisplay.State = .ok) -> StageDisplay {
            StageDisplay(
                id: id, fingerprint: name, frame: CGRect(x: x, y: 0, width: 1920, height: 1080), isBuiltin: false,
                name: name, badgeText: "", statusText: "", cover: nil, state: state
            )
        }
        let displays = [display(1, "Studio", x: 1920), display(2, "MPG", x: 0), display(3, "Built-in", x: -1728)]
        #expect(NowPlayingBadge(on: [], among: displays) == nil)
        #expect(NowPlayingBadge(on: [9], among: displays) == nil, "a display that is gone names nothing")
        let one = try #require(NowPlayingBadge(on: [1], among: displays))
        let two = try #require(NowPlayingBadge(on: [1, 2], among: displays))
        let three = try #require(NowPlayingBadge(on: [2, 1, 3], among: displays))
        #expect(one.text == "Studio" && two.text == "MPG +1" && three.text == "Built-in +2", "\(one.text) · \(two.text) · \(three.text)")
        #expect(three.displayNames == ["Built-in", "MPG", "Studio"])
        #expect(one.isLive)
        // Set but not drawing: the capsule still names the display and its bars stand still.
        let chip = StageFailureChip(symbol: "exclamationmark.triangle", text: "Failed", tint: CGColor(gray: 0, alpha: 1))
        let idle: [StageDisplay.State] = [.paused(reasonText: "Paused"), .off(text: "Off"), .preparing(text: "Preparing"), .failed(chip)]
        for state in idle {
            let badge = try #require(NowPlayingBadge(on: [1], among: [display(1, "Studio", x: 0, state)]))
            #expect(!badge.isLive, Comment(rawValue: "\(state) reads as live"))
        }
        let mixed = [display(1, "Studio", x: 0, .paused(reasonText: "Paused")), display(2, "MPG", x: 1920)]
        #expect(try #require(NowPlayingBadge(on: [1, 2], among: mixed)).isLive, "one display drawing it is enough")
    }

    /// The name drawn on the screen itself. Each step only fires when the one before it is blank,
    /// and the last one is the kind word, so a display with a wallpaper always says something.
    @Test("The on-screen wallpaper name walks library → source → file → host → kind")
    func wallpaperNameFallsBackStepByStep() {
        let file = URL(fileURLWithPath: "/private/tmp/loomscreen-stage/Aurora")
        #expect(StageWallpaperName.resolve(
            libraryTitle: "Saved aurora", originTitle: "Aurora Borealis", fileURL: file, host: "example.com", kind: "Video"
        ) == "Saved aurora")
        // Blank is not a hit: a bookmark saved with an empty label must not blank the row.
        #expect(StageWallpaperName.resolve(
            libraryTitle: "   ", originTitle: "Aurora Borealis", fileURL: file, host: "example.com", kind: "Video"
        ) == "Aurora Borealis")
        #expect(StageWallpaperName.resolve(
            libraryTitle: nil, originTitle: nil, fileURL: file, host: "example.com", kind: "Video"
        ) == "Aurora")
        #expect(StageWallpaperName.resolve(
            libraryTitle: nil, originTitle: nil, fileURL: nil, host: "example.com", kind: "Web"
        ) == "example.com")
        #expect(StageWallpaperName.resolve(
            libraryTitle: nil, originTitle: "", fileURL: nil, host: nil, kind: "Scene"
        ) == "Scene")
    }

    private static func shelf(_ count: Int) -> [StageCard] {
        (0 ..< count).map {
            StageCard(id: "card-\($0)", title: "Card \($0)", metaLine: "", thumbnail: nil, nowPlaying: nil, isDraggable: true)
        }
    }

    private static func cardsWithThumbnail(_ model: EditDeskStageModel) -> [Int] {
        model.shelfItems.indices.filter { model.shelfItems[$0].thumbnail != nil }
    }

    @Test("A card scrolled out and back in gets its cached thumbnail back")
    func shelfThumbnailReturnsAfterScrollingBack() throws {
        let model = EditDeskStageModel()
        model.shelfItems = Self.shelf(30)
        var cache: [Int: CGImage] = [:]
        for index in 0 ..< 30 {
            cache[index] = try Self.makeImage()
        }

        model.report(visibleShelfRange: 0 ..< 10)
        _ = model.refreshShelfThumbnails { cache[$0] }
        #expect(Self.cardsWithThumbnail(model) == Array(0 ..< 14))

        model.report(visibleShelfRange: 20 ..< 30)
        _ = model.refreshShelfThumbnails { cache[$0] }
        #expect(Self.cardsWithThumbnail(model) == Array(16 ..< 30))

        model.report(visibleShelfRange: 0 ..< 10)
        _ = model.refreshShelfThumbnails { cache[$0] }
        #expect(Self.cardsWithThumbnail(model) == Array(0 ..< 14), "Cards scrolled back into view stay blank although the cache still has their images")
        #expect((0 ..< 14).allSatisfy { model.shelfItems[$0].thumbnail === cache[$0] })
    }

    @Test("Cards within the lead keep their thumbnails when the row moves a little")
    func shelfThumbnailsSurviveInsideTheLead() throws {
        let model = EditDeskStageModel()
        model.shelfItems = Self.shelf(30)
        var cache: [Int: CGImage] = [:]
        for index in 0 ..< 30 {
            cache[index] = try Self.makeImage()
        }
        model.report(visibleShelfRange: 0 ..< 10)
        _ = model.refreshShelfThumbnails { cache[$0] }

        model.report(visibleShelfRange: 2 ..< 12)
        _ = model.refreshShelfThumbnails { cache[$0] }
        #expect(model.shelfItems[0].thumbnail != nil && model.shelfItems[1].thumbnail != nil)
        #expect(model.shelfItems[14].thumbnail === cache[14] && model.shelfItems[15].thumbnail === cache[15])
        #expect(model.shelfItems[16].thumbnail == nil)
    }

    @Test("A card still holding a thumbnail the cache has evicted is neither cleared nor decoded again")
    func heldThumbnailIsNotDecodedAgain() throws {
        let model = EditDeskStageModel()
        model.shelfItems = Self.shelf(10)
        let held = try Self.makeImage()
        model.shelfItems[3].thumbnail = held
        model.report(visibleShelfRange: 0 ..< 10)

        let missing = model.refreshShelfThumbnails { _ in nil }
        #expect(!missing.contains(3))
        #expect(model.shelfItems[3].thumbnail === held)
    }

    @Test("Refresh returns, in order, the kept cards with no thumbnail and none in the cache")
    func refreshReturnsTheKeptCardsTheCacheCannotFill() throws {
        let model = EditDeskStageModel()
        model.shelfItems = Self.shelf(60)
        model.shelfItems[33].thumbnail = try Self.makeImage()
        let uncached: Set = [2, 5, 10, 25, 26, 33, 36, 43, 44, 50]
        var cache: [Int: CGImage] = [:]
        for index in 0 ..< 60 where !uncached.contains(index) {
            cache[index] = try Self.makeImage()
        }
        // Kept: the grid's 0..<6 and the row's 30..<40 widened to 26..<44.
        model.report(visibleShelfRange: 30 ..< 40)
        model.report(visibleGridRange: 0 ..< 6)

        let missing = model.refreshShelfThumbnails { cache[$0] }
        #expect(missing == [2, 5, 26, 36, 43])
    }

    @Test("A decode that finishes after its card left the kept band does not pin the image to it")
    func lateDecodeOutsideTheBandIsDropped() throws {
        let model = EditDeskStageModel()
        model.shelfItems = Self.shelf(40)
        model.report(visibleShelfRange: 0 ..< 10)
        let image = try Self.makeImage()

        model.landThumbnail(image, for: "card-5")
        model.landThumbnail(image, for: "card-30")
        #expect(model.shelfItems[5].thumbnail === image)
        #expect(model.shelfItems[30].thumbnail == nil, "A late decode keeps its image alive on a card nobody is looking at")
    }
}
