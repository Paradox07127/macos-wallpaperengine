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

    @Test("The transport glyph offers the opposite of what the display is doing")
    func playbackGlyphFollowsTheState() {
        var display = StageDisplay(
            id: 1, fingerprint: "fp", frame: .zero, isBuiltin: false, name: "MPG",
            badgeText: "", statusText: "", cover: nil, state: .ok
        )
        #expect(display.playbackGlyph == "pause.fill")
        display.state = .paused(reasonText: "Paused")
        #expect(display.playbackGlyph == "play.fill")
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
}
