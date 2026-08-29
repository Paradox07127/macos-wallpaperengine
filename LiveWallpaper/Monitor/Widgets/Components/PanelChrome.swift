import AppKit
import SwiftUI

struct PanelChrome: ViewModifier {
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius

    // Board-wide appearance, read here because this is the single place every
    // widget paints its card.
    @AppStorage(MonitorPanelAppearance.tintKey, store: .appScoped())
    private var tintHex = MonitorPanelAppearance.defaultTintHex
    @AppStorage(MonitorPanelAppearance.opacityKey, store: .appScoped())
    private var panelOpacity = MonitorPanelAppearance.defaultOpacity
    @AppStorage(MonitorPanelAppearance.glassKey, store: .appScoped())
    private var liquidGlass = MonitorPanelAppearance.defaultGlass

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if MonitorPanelAppearance.usesGlass(liquidGlass, reduceTransparency: reduceTransparency) {
            glassCard(content)
        } else {
            paintedCard(content)
        }
    }

    /// Liquid Glass draws its own material, edge highlight and refraction, so
    /// this drops the painted gradient, the grain and the top highlight rather
    /// than stacking them on top — layering the designed lighting over a
    /// material that already has its own is what makes glass look like a grey
    /// rectangle. The drop shadow stays: Apple's own widgets cast one, and it
    /// is what separates the card from the wallpaper it is refracting.
    ///
    /// Verified 2026-08-29 that `.glassEffect` really does refract through a
    /// desktop-level `OverlayWindow` onto the wallpaper behind it, rather than
    /// only sampling its own window — a two-colour backdrop showed through the
    /// glass with the seam bending at the edge.
    private func glassCard(_ content: Content) -> some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .adaptiveGlassScrimmed(
                cornerRadius: cornerRadius,
                scrim: MonitorPanelAppearance.glassScrim(tintHex: tintHex, opacity: panelOpacity)
            )
            .shadow(color: .black.opacity(0.34), radius: 18, x: 0, y: 10)
            // Glass picks its light or dark variant from the colour scheme, and
            // these tiles are dark-themed whatever the system is set to.
            .environment(\.colorScheme, .dark)
    }

    private func paintedCard(_ content: Content) -> some View {
        let fill = MonitorPanelAppearance.fill(tintHex: tintHex, opacity: panelOpacity)
        return content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [fill.top, fill.bottom],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(MonitorGrain(cornerRadius: cornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Design.panelTopHighlight, .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: .black.opacity(0.42), radius: 22, x: 0, y: 14)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Design.panelStroke, lineWidth: Design.hairlineWidth)
            )
    }
}

extension View {
    func monitorPanelChrome(cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius) -> some View {
        modifier(PanelChrome(cornerRadius: cornerRadius))
    }
}

/// Procedural film-grain: a seeded speckle field drawn once into a bitmap and tiled at whisper opacity via `overlay` blend.
struct MonitorGrain: View {
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius
    var opacity: Double = 0.022

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if let image = Self.grainImage(width: size.width, height: size.height) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: size.width, height: size.height)
                    .opacity(opacity)
                    .blendMode(.overlay)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
    }

    /// Deterministic monochrome speckle, cached by rounded pixel dimensions so a
    /// steady panel size hits the cache instead of re-rasterising.
    private static var cache: [String: NSImage] = [:]

    static func grainImage(width: CGFloat, height: CGFloat) -> NSImage? {
        let w = max(1, Int(width.rounded()))
        let h = max(1, Int(height.rounded()))
        let key = "\(w)x\(h)"
        if let hit = cache[key] { return hit }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        var state: UInt64 = 0x9E3779B97F4A7C15  // fixed seed → stable grain

        for i in stride(from: 0, to: pixels.count, by: 4) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let v = UInt8(truncatingIfNeeded: state)
            pixels[i] = v
            pixels[i + 1] = v
            pixels[i + 2] = v
            pixels[i + 3] = 255
        }

        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else { return nil }

        let image = NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
        cache[key] = image
        return image
    }
}

#Preview("Panel chrome") {
    VStack(spacing: 24) {
        Text(verbatim: "SMALL")
            .font(Design.labelFont(size: 11))
            .foregroundStyle(Design.inkFaint)
            .frame(width: 150, height: 150)
            .monitorPanelChrome()

        Text("Wide Panel", bundle: .main)
            .font(Design.labelFont(size: 11))
            .foregroundStyle(Design.inkFaint)
            .frame(width: 320, height: 150)
            .monitorPanelChrome()
    }
    .padding(40)
    .background(Design.boardWash)
}
