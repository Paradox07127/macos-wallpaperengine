import AppKit
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing
import UniformTypeIdentifiers

/// Hover to play on the shelf: only a card whose picture is its scene's own GIF, once the pointer rests on it.
extension EditDeskStageViewTests {
    enum PreviewControl: String, CaseIterable, Sendable {
        case settingOff, reduceMotion, stillPreview, savedCover
    }

    @MainActor
    private final class PreviewLoads {
        var sizes: [Int] = []
    }

    private static func solid(_ white: CGFloat, width: Int = 64, height: Int = 36) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: white, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func sceneOrigin(preview file: String) -> WPEOrigin {
        WPEOrigin(
            workshopID: "123", title: "Scene", originalType: .scene,
            sourceFolderBookmark: Data([2]), cacheRelativePath: nil, previewFileName: file
        )
    }

    private static func shelfCards(poster: CGImage, previews: [WPEOrigin?]) -> [StageCard] {
        (0 ..< 6).map { index in
            StageCard(
                id: "card-\(index)", title: "Card \(index)", metaLine: "", thumbnail: poster, nowPlaying: nil,
                isDraggable: true, previewOrigin: index < previews.count ? previews[index] : nil
            )
        }
    }

    /// The shelf up in an off-screen window with the setting on; every load is answered with `frames`.
    private static func mountShelf(
        _ cards: [StageCard], frames: ShelfPreviewFrames, reduceMotion: Bool = false
    ) -> (EditDeskStageView, NSWindow, PreviewLoads) {
        let model = EditDeskStageModel()
        model.reduceMotion = reduceMotion
        model.displays = [
            StageDisplay(
                id: 1, fingerprint: "one", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isBuiltin: false,
                name: "One", badgeText: "1", statusText: "", cover: nil, state: .ok
            ),
        ]
        model.shelfItems = cards
        let view = EditDeskStageView(model: model)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow), styleMask: .borderless,
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        model.setProgress(1, animated: false)
        let loads = PreviewLoads()
        view.previewAutoplayEnabled = { true }
        view.previewPlayer.load = { _, maxPixelSize in
            loads.sizes.append(maxPixelSize)
            return frames
        }
        return (view, window, loads)
    }

    /// A point that only card `index` covers.
    private static func point(on index: Int, of view: EditDeskStageView) throws -> CGPoint {
        let model = view.model
        let placement = StageGeometry.cardPlacement(
            style: model.shelfStyle, index: index, count: model.shelfItems.count, progress: 1, focus: 0,
            windowSize: view.bounds.size
        )
        let hit = StageGeometry.hitRect(placement, style: model.shelfStyle)
        let point = CGPoint(x: hit.minX + 8, y: hit.midY)
        try #require(view.cardIndex(at: point) == index)
        return point
    }

    private static func preview(on tile: ShelfCardLayer) -> CAKeyframeAnimation? {
        tile.thumbnail.animation(forKey: ShelfPreviewPlayer.animationKey) as? CAKeyframeAnimation
    }

    private static func waitForPreview(on tile: ShelfCardLayer) async -> CAKeyframeAnimation? {
        for _ in 0 ..< 200 {
            if let animation = preview(on: tile) {
                return animation
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private static func frames() throws -> ShelfPreviewFrames {
        try ShelfPreviewFrames(images: [0.2, 0.4, 0.6].map { try #require(solid($0)) }, delays: [0.05, 0.05, 0.1])
    }

    @Test("A card plays its preview only when it shows its scene's GIF, the pointer has settled, the setting is on, motion is allowed and nothing covers the shelf")
    func previewPlaybackRule() throws {
        let rule = ShelfPreviewPlayback.plays
        #expect(rule(true, true, true, false, false))
        #expect(!rule(false, true, true, false, false), "not a GIF")
        #expect(!rule(true, false, true, false, false), "pointer not settled")
        #expect(!rule(true, true, false, false, false), "setting off")
        #expect(!rule(true, true, true, true, false), "Reduce Motion")
        #expect(!rule(true, true, true, false, true), "shelf covered")

        let poster = try #require(Self.solid(0.5))
        func card(_ file: String?, thumbnail: CGImage?) -> StageCard {
            StageCard(
                id: "a", title: "A", metaLine: "", thumbnail: thumbnail, nowPlaying: nil, isDraggable: true,
                previewOrigin: file.map { Self.sceneOrigin(preview: $0) }
            )
        }
        #expect(ShelfPreviewPlayback.displaysGIF(card("preview.gif", thumbnail: poster)))
        #expect(ShelfPreviewPlayback.displaysGIF(card("Preview.GIF", thumbnail: poster)))
        #expect(!ShelfPreviewPlayback.displaysGIF(card("preview.jpg", thumbnail: poster)), "a still preview")
        #expect(!ShelfPreviewPlayback.displaysGIF(card(nil, thumbnail: poster)), "a saved cover")
        #expect(!ShelfPreviewPlayback.displaysGIF(card("preview.gif", thumbnail: nil)), "nothing drawn yet")
    }

    @Test("A settled hover plays the card's GIF; the next card takes over, and leaving puts the card back on its first frame", .timeLimit(.minutes(1)))
    func settledHoverPlaysTheGIFPreview() async throws {
        let poster = try #require(Self.solid(0.5))
        let gif = Self.sceneOrigin(preview: "preview.gif")
        let (view, window, loads) = try Self.mountShelf(Self.shelfCards(poster: poster, previews: [gif, gif]), frames: Self.frames())
        defer {
            view.detach()
            window.contentView = nil
        }
        let first = try #require(view.cardLayers["card-0"])
        let second = try #require(view.cardLayers["card-1"])

        try view.setPointerForTesting(Self.point(on: 0, of: view))
        #expect(Self.preview(on: first) == nil, "the preview started before the pointer settled")
        let animation = try #require(await Self.waitForPreview(on: first), "a settled hover never played the GIF")
        #expect(animation.keyPath == "contents" && animation.calculationMode == .discrete && animation.repeatCount == .infinity)
        #expect(animation.values?.count == 3)
        let keyTimes = animation.keyTimes?.map(\.doubleValue) ?? []
        #expect(keyTimes.count == 4 && zip(keyTimes, [0, 0.25, 0.5, 1]).allSatisfy { abs($0 - $1) < 1e-9 }, Comment(rawValue: "\(keyTimes)"))
        #expect(abs(animation.duration - 0.2) < 1e-9)
        let pixelSize = Int((max(StageGeometry.cardSize.width, StageGeometry.cardSize.height) * window.backingScaleFactor).rounded())
        #expect(loads.sizes == [pixelSize], Comment(rawValue: "frames asked for at \(loads.sizes), the card is \(pixelSize) px"))

        try view.setPointerForTesting(Self.point(on: 1, of: view))
        #expect(Self.preview(on: first) == nil, "two cards played at once")
        #expect(try #require(await Self.waitForPreview(on: second), "the next card never played").values?.count == 3)

        view.setPointerForTesting(CGPoint(x: 2, y: 2))
        try #require(view.model.hoveredCard == nil)
        #expect(Self.preview(on: second) == nil, "leaving the card left its preview playing")
        #expect((second.thumbnail.contents as AnyObject?) === (poster as AnyObject), "the card is not back on its first frame")
    }

    @Test("No preview plays with the setting off, under Reduce Motion, on a still preview or on a saved cover", .timeLimit(.minutes(1)), arguments: PreviewControl.allCases)
    func previewStaysStill(_ control: PreviewControl) async throws {
        let poster = try #require(Self.solid(0.5))
        let origin: WPEOrigin? = switch control {
        case .stillPreview: Self.sceneOrigin(preview: "preview.jpg")
        case .savedCover: nil
        case .settingOff, .reduceMotion: Self.sceneOrigin(preview: "preview.gif")
        }
        let (view, window, loads) = try Self.mountShelf(
            Self.shelfCards(poster: poster, previews: [origin]), frames: Self.frames(), reduceMotion: control == .reduceMotion
        )
        defer {
            view.detach()
            window.contentView = nil
        }
        if control == .settingOff {
            view.previewAutoplayEnabled = { false }
        }
        let tile = try #require(view.cardLayers["card-0"])
        try view.setPointerForTesting(Self.point(on: 0, of: view))
        try #require(view.model.hoveredCard == "card-0")
        // Past the settle delay with room for a load: the playing case above attaches well inside this.
        try await Task.sleep(for: ShelfPreviewPlayer.settleDelay + .milliseconds(450))
        #expect(Self.preview(on: tile) == nil, Comment(rawValue: "\(control) played the preview"))
        #expect(loads.sizes.isEmpty, Comment(rawValue: "\(control) still decoded the preview"))
    }

    @Test("A card the pointer rests on before its GIF is drawn plays it once the picture lands, however often the stage redraws", .timeLimit(.minutes(1)))
    func previewStartsWhenThePictureLands() async throws {
        let poster = try #require(Self.solid(0.5))
        let drawn = Self.shelfCards(poster: poster, previews: [Self.sceneOrigin(preview: "preview.gif")])
        let cold = drawn.map { card in
            var card = card
            card.thumbnail = nil
            return card
        }
        let (view, window, loads) = try Self.mountShelf(cold, frames: Self.frames())
        defer {
            view.detach()
            window.contentView = nil
        }
        let tile = try #require(view.cardLayers["card-0"])
        try view.setPointerForTesting(Self.point(on: 0, of: view))
        try #require(view.model.hoveredCard == "card-0")
        try await Task.sleep(for: ShelfPreviewPlayer.settleDelay + .milliseconds(100))
        #expect(Self.preview(on: tile) == nil && loads.sizes.isEmpty, "a card with no picture yet played")

        view.model.shelfItems = drawn
        // A redraw every 10 ms, well inside the settle delay: none of them may start the wait again.
        var animation: CAKeyframeAnimation?
        let deadline = Date().addingTimeInterval(2)
        while animation == nil, Date() < deadline {
            view.layout()
            try await Task.sleep(for: .milliseconds(10))
            animation = Self.preview(on: tile)
        }
        #expect(animation != nil, "the picture landed under the resting pointer and its GIF never played")
    }

    #if !LITE_BUILD
    private static func encoded(_ type: UTType, delays: [Double], width: Int = 256, height: Int = 144) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, delays.count, nil))
        for (index, delay) in delays.enumerated() {
            let image = try #require(solid(CGFloat(index + 1) / CGFloat(delays.count + 1), width: width, height: height))
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            CGImageDestinationAddImage(destination, image, type == .gif ? properties : nil)
        }
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("A GIF preview decodes every frame at the card's pixel size with its own frame times; a still does not animate")
    func previewFramesDecodeAtCardSize() throws {
        let frames = try #require(ShelfPreviewFrames.decode(Self.encoded(.gif, delays: [0.05, 0.1, 0.2]), maxPixelSize: 100))
        #expect(frames.images.count == 3)
        #expect(frames.images.allSatisfy { max($0.width, $0.height) <= 100 }, Comment(rawValue: "\(frames.images.map { "\($0.width)×\($0.height)" })"))
        #expect(frames.delays.count == 3 && zip(frames.delays, [0.05, 0.1, 0.2]).allSatisfy { abs($0 - $1) < 0.001 }, Comment(rawValue: "\(frames.delays)"))
        #expect(try ShelfPreviewFrames.decode(Self.encoded(.gif, delays: [0.1]), maxPixelSize: 100) == nil, "a one-frame GIF")
        #expect(try ShelfPreviewFrames.decode(Self.encoded(.png, delays: [0]), maxPixelSize: 100) == nil, "a still")
    }

    @Test("Only a shelf request whose picture is the scene's own preview carries the scene")
    func scenePreviewOriginFollowsTheShelfPicture() {
        let origin = Self.sceneOrigin(preview: "preview.gif")
        let scene = SceneDescriptor(workshopID: "123", cacheRelativePath: "123", entryFile: "scene.json", capabilityTier: .imageOnly)
        let plain = WallpaperBookmark(label: "", content: .scene(scene), wpeOrigin: origin)
        #expect(ShelfThumbnailCache.Request.bookmark(plain).scenePreviewOrigin == origin)
        var covered = plain
        covered.coverFileName = "cover.png"
        #expect(ShelfThumbnailCache.Request.bookmark(covered).scenePreviewOrigin == nil, "a saved cover is drawn instead")
        let video = WallpaperBookmark(label: "", content: .video(bookmarkData: Data([1])), wpeOrigin: origin)
        #expect(ShelfThumbnailCache.Request.bookmark(video).scenePreviewOrigin == nil, "the video's poster is drawn instead")
        let entry = WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 0))
        #expect(ShelfThumbnailCache.Request.workshop(entry).scenePreviewOrigin == origin)
    }

    @Test("A Workshop card showing its saved cover or its video's frame plays no GIF; one showing the author's GIF still does")
    func workshopCardPlaysOnlyTheAuthorsGIF() {
        let entry = WPEHistoryEntry(origin: Self.sceneOrigin(preview: "preview.gif"), importedAt: Date(timeIntervalSince1970: 0))
        let video = WPEHistoryEntry(origin: WPEOrigin(
            workshopID: "456", title: "Video", originalType: .video, sourceFolderBookmark: Data([2]),
            cacheRelativePath: nil, previewFileName: "preview.gif", entryFile: "clip.mp4"
        ), importedAt: Date(timeIntervalSince1970: 0))
        func playsGIF(_ request: ShelfThumbnailCache.Request) -> Bool {
            ShelfPreviewPlayback.displaysGIF(showsPicture: true, previewOrigin: request.scenePreviewOrigin)
        }
        #expect(playsGIF(.workshop(entry)), "control: the author's GIF no longer plays")
        #expect(!playsGIF(.workshop(entry, coverRevision: 1)), "a card showing its saved cover played the author's GIF")
        #expect(!playsGIF(.workshop(video)), "a card showing its video's frame played the author's GIF")
    }
    #endif
}
