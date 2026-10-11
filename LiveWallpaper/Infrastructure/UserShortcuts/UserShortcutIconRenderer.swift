#if !LITE_BUILD
import AppKit
import LiveWallpaperCore

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

    /// Aspect-fit and centered on a transparent sRGB canvas, then un-premultiplied for the WPE straight-image contract.
    static func rasterize(_ image: CGImage, coverage: CGFloat = 1, tint: CGColor? = nil) -> WPEUserShortcutIconImage? {
        guard image.width > 0, image.height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
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
        var bytes = [UInt8](repeating: 0, count: edge * edge * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: edge,
                height: edge,
                bitsPerComponent: 8,
                bytesPerRow: edge * 4,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: rect)
            if let tint {
                // Template symbols draw black; sourceIn keeps their coverage and swaps the color.
                context.setBlendMode(.sourceIn)
                context.setFillColor(tint)
                context.fill(rect)
            }
            return true
        }
        guard drawn else { return nil }
        WPERasterImageAlpha.unpremultiplyRGBA8(&bytes)
        return WPEUserShortcutIconImage(rgba: bytes, width: edge, height: edge)
    }
}
#endif
