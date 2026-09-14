import AppKit
import LiveWallpaperCore

/// Stills of what a display is actually showing, used as the cover a bookmark
/// or scheme is saved with.
///
/// Every source here is the app's own rendering — the scene renderer's presented
/// texture, the player's composited frame, the live web view, the overlay hosts'
/// own layers. Nothing reads the screen, so saving a cover never asks for screen
/// recording.
@MainActor
enum WallpaperCoverCapture {
    /// Long edge of a stored cover. The largest library tile step is 408 pt, so
    /// this stays sharp at 2× without keeping a display-sized PNG per entry.
    static let coverWidth: CGFloat = 1024

    /// A still of the wallpaper alone.
    static func captureWallpaper(
        screen: Screen,
        configuration: ScreenConfiguration
    ) async -> NSImage? {
        guard let frame = await wallpaperFrame(screen: screen, configuration: configuration) else {
            return nil
        }
        return compose(
            wallpaper: frame,
            overlays: [],
            aspect: displayAspect(of: screen),
            fitMode: configuration.fitMode,
            displayWidth: screen.frame.width
        )
    }

    /// A still of the wallpaper with the display's overlay layers on top — what
    /// a scheme actually restores, which is more than its wallpaper.
    static func captureWithOverlay(
        screen: Screen,
        configuration: ScreenConfiguration
    ) async -> NSImage? {
        guard let frame = await wallpaperFrame(screen: screen, configuration: configuration) else {
            return nil
        }
        let overlays = await OverlayController.shared.captureOverlayLayers(screenID: screen.id)
        return compose(
            wallpaper: frame,
            overlays: overlays,
            aspect: displayAspect(of: screen),
            fitMode: configuration.fitMode,
            displayWidth: screen.frame.width
        )
    }

    // MARK: - Sources

    private static func wallpaperFrame(
        screen: Screen,
        configuration: ScreenConfiguration
    ) async -> NSImage? {
        if let video = screen.runtimeSession as? VideoWallpaperSession {
            return await video.videoPlayer?.currentFrameImage()
        }
        if let ambient = screen.runtimeSession as? AmbientWallpaperSession,
           case let .html(source, config) = configuration.activeWallpaper {
            return await ambient.captureLiveHTMLSnapshot(matching: source, config: config)
        }
        #if !LITE_BUILD
        if let scene = screen.runtimeSession as? SceneWallpaperSession {
            return await scene.captureLivePosterFromNextFrame()
        }
        #endif
        return nil
    }

    // MARK: - Composition

    private static func displayAspect(of screen: Screen) -> CGFloat {
        let frame = screen.frame
        guard frame.width > 0, frame.height > 0 else { return 16.0 / 9.0 }
        return frame.width / frame.height
    }

    /// Draws onto a canvas with the *display's* aspect ratio, placing the
    /// wallpaper with the display's own fit mode. Filling unconditionally would
    /// crop a Fit wallpaper that the desktop is letterboxing — the cover is
    /// supposed to be what is on screen, framing included. The overlay layers
    /// were captured at the display's own size, so they line up over the canvas
    /// whatever the backdrop does inside it.
    private static func compose(
        wallpaper: NSImage,
        overlays: [NSImage],
        aspect: CGFloat,
        fitMode: VideoFitMode,
        displayWidth: CGFloat
    ) -> NSImage? {
        let size = NSSize(width: coverWidth, height: (coverWidth / max(aspect, 0.01)).rounded())
        guard size.height >= 1,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: Int(size.width),
                  pixelsHigh: Int(size.height),
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              ) else { return nil }

        let canvas = NSRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high

        NSColor.black.setFill()
        canvas.fill()
        wallpaper.draw(
            in: placementRect(
                for: wallpaper.size,
                in: canvas,
                fitMode: fitMode,
                displayWidth: displayWidth
            ),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        for overlay in overlays {
            overlay.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)
        }
        context.flushGraphics()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The rect the display's fit mode puts the source in, centred — the same
    /// four placements `VideoFitMode` names, computed by hand because the cover
    /// is drawn into a bitmap rather than a layer with a `videoGravity`.
    ///
    /// The cover canvas is smaller than the display, so `.center` scales by the
    /// canvas/display ratio rather than pinning to source pixels; pinning would
    /// make a 4K source overflow a 1024pt cover that the desktop shows inset.
    static func placementRect(
        for source: NSSize,
        in canvas: NSRect,
        fitMode: VideoFitMode,
        displayWidth: CGFloat? = nil
    ) -> NSRect {
        guard source.width > 0, source.height > 0 else { return canvas }
        let scale: CGFloat
        switch fitMode {
        case .aspectFill:
            scale = max(canvas.width / source.width, canvas.height / source.height)
        case .aspectFit:
            scale = min(canvas.width / source.width, canvas.height / source.height)
        case .stretch:
            return canvas
        case .center:
            scale = (displayWidth.map { canvas.width / max($0, 1) } ?? 1)
        }
        let size = NSSize(width: source.width * scale, height: source.height * scale)
        return NSRect(
            x: canvas.midX - size.width / 2,
            y: canvas.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
