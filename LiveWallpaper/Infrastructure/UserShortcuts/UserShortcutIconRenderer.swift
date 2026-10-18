#if !LITE_BUILD
import AppKit
import AVFoundation
import ImageIO
import LiveWallpaperCore

/// Video files a scene texture slot accepts in place of an image, as Wallpaper Engine does.
enum SceneTextureVideo {
    static let extensions: Set<String> = ["mp4", "webm", "mov", "m4v", "avi", "wmv", "mkv"]
    /// Accepted containers AVFoundation can't open; their slot keeps the author's image.
    static let unplayableExtensions: Set<String> = ["webm", "avi", "wmv", "mkv"]

    enum Problem: Equatable, Sendable {
        case unsupportedFormat, unreadable
    }

    static func isVideo(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    static func isPlayable(_ url: URL) -> Bool {
        isVideo(url) && !unplayableExtensions.contains(url.pathExtension.lowercased())
    }

    /// nil for anything that is not a video file, and for a video the slot can play.
    static func problem(at url: URL) async -> Problem? {
        guard isVideo(url) else { return nil }
        guard isPlayable(url) else { return .unsupportedFormat }
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return .unreadable }
        return nil
    }

    static func problem(for binding: UserShortcutBinding) async -> Problem? {
        guard binding.kind == .file, case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            binding.bookmark, target: .transient
        ) else { return nil }
        let scoped = resolved.url.startAccessingSecurityScopedResource()
        defer {
            if scoped {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
        return await problem(at: resolved.url)
    }
}

/// The icon a scene's `usershortcut` texture slot shows for a binding.
@MainActor
enum UserShortcutIconRenderer {
    static let canvasEdge = 256
    private static let symbolCoverage: CGFloat = 0.7

    /// nil = no icon (unresolvable file/directory bookmark); the slot keeps the author's fallback texture.
    static func icon(for binding: UserShortcutBinding) -> WPEUserShortcutIconImage? {
        switch binding.kind {
        case .web:
            return symbol("globe")
        case .cmd:
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else {
                return symbol("square.2.layers.3d")
            }
            return rasterize(NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false)), coverage: 1, tint: nil)
        case .file, .directory:
            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
                binding.bookmark, target: .transient
            ) else { return nil }
            return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                rasterize(NSWorkspace.shared.icon(forFile: resolved.url.path(percentEncoded: false)), coverage: 1, tint: nil)
            }
        }
    }

    /// The bound video file the slot plays; nil for anything else, including the videos AVFoundation can't open.
    static func sceneVideo(for binding: UserShortcutBinding) -> URL? {
        guard binding.kind == .file, case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            binding.bookmark, target: .transient
        ), SceneTextureVideo.isPlayable(resolved.url) else { return nil }
        return resolved.url
    }

    /// The bound image file at its own size, capped at `maxSceneTextureEdge`; nil (author's texture) for anything
    /// that is not a decodable image file.
    static func sceneTexture(for binding: UserShortcutBinding) -> WPEUserShortcutIconImage? {
        guard binding.kind == .file, case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(
            binding.bookmark, target: .transient
        ), !SceneTextureVideo.isVideo(resolved.url) else { return nil }
        return SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
            guard let source = CGImageSourceCreateWithURL(resolved.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxSceneTextureEdge),
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return straightRGBA(width: image.width, height: image.height) { context in
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
        }
    }

    private static let maxSceneTextureEdge = 4096

    private static func symbol(_ name: String) -> WPEUserShortcutIconImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        return rasterize(image, coverage: symbolCoverage, tint: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    }

    private static func rasterize(_ image: NSImage, coverage: CGFloat, tint: CGColor?) -> WPEUserShortcutIconImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        let box = CGFloat(canvasEdge) * coverage
        let scale = min(box / image.size.width, box / image.size.height)
        var proposed = CGRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
        guard let cgImage = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        return rasterize(cgImage, coverage: coverage, tint: tint)
    }

    /// Aspect-fit and centered on the icon canvas.
    static func rasterize(_ image: CGImage, coverage: CGFloat = 1, tint: CGColor? = nil) -> WPEUserShortcutIconImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let edge = canvasEdge
        let box = CGFloat(edge) * coverage
        let scale = min(box / CGFloat(image.width), box / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = CGRect(
            x: (CGFloat(edge) - size.width) / 2,
            y: (CGFloat(edge) - size.height) / 2,
            width: size.width,
            height: size.height
        )
        return straightRGBA(width: edge, height: edge) { context in
            context.draw(image, in: rect)
            if let tint {
                // Template symbols draw black; sourceIn keeps their coverage and swaps the color.
                context.setBlendMode(.sourceIn)
                context.setFillColor(tint)
                context.fill(rect)
            }
        }
    }

    /// Draws into a transparent sRGB canvas, then un-premultiplies for the WPE straight-image contract.
    private static func straightRGBA(width: Int, height: Int, draw: (CGContext) -> Void) -> WPEUserShortcutIconImage? {
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            draw(context)
            return true
        }
        guard drawn else { return nil }
        WPERasterImageAlpha.unpremultiplyRGBA8(&bytes)
        return WPEUserShortcutIconImage(rgba: bytes, width: width, height: height)
    }
}
#endif
