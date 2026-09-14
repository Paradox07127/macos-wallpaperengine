import AppKit
import LiveWallpaperCore

/// Covers are captured from the app's own rendering, never the screen, so saving never asks for screen recording.
@MainActor
enum WallpaperCoverCapture {
    /// Long edge of a stored cover. The largest library tile step is 408 pt, so
    /// this stays sharp at 2× without keeping a display-sized PNG per entry.
    static let coverWidth: CGFloat = 1024

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

    /// Canvas uses the display aspect and fit mode; filling would crop a Fit wallpaper the desktop is letterboxing.
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

    /// .center scales by canvas/display ratio; pinning to source pixels would overflow a 1024pt cover.
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
