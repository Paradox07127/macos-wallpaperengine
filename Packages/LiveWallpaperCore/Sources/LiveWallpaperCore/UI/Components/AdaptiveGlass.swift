import SwiftUI

public enum AdaptiveGlassShape: Equatable, Sendable {
    case circle
    case capsule
    case roundedRectangle(CGFloat)
}

public enum AdaptiveGlassProminence: Sendable {
    case regular
    case prominent
}

/// `circle` is for single-glyph icon buttons, matching the macOS 26 Liquid Glass icon-control look.
public enum AdaptiveGlassButtonShape: Sendable {
    case capsule
    case circle
}

public struct AdaptiveGlassContainer<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

public extension View {
    /// `stroked: false` suppresses the fallback path's own outline — for callers
    /// that already draw an edge on the same shape (e.g. `GalleryTileChrome`),
    /// which would otherwise render two hairlines on macOS 14/15.
    func adaptiveGlassSurface(
        _ shape: AdaptiveGlassShape = .roundedRectangle(12),
        tint: Color? = nil,
        interactive: Bool = false,
        stroked: Bool = true
    ) -> some View {
        modifier(AdaptiveGlassSurfaceModifier(
            shape: shape,
            tint: tint,
            interactive: interactive,
            stroked: stroked
        ))
    }

    /// `size: nil` lets the environment's `controlSize` flow through (e.g. the
    /// `.small` set by `SettingRow`); pass a value only to pin a specific size.
    func adaptiveGlassButton(
        _ prominence: AdaptiveGlassProminence = .regular,
        shape: AdaptiveGlassButtonShape = .capsule,
        size: ControlSize? = nil
    ) -> some View {
        modifier(AdaptiveGlassButtonModifier(prominence: prominence, shape: shape, size: size))
    }

    /// Liquid-glass chrome for a small badge floating over a thumbnail/preview. The
    /// legibility-preserving tint keeps white/coloured glyphs readable over bright previews; Reduce
    /// Transparency forces an opaque fill. Adds zero padding so it never changes a badge's footprint
    /// — only its backing. `in:` takes a rounded rectangle for panels that carry more than one line —
    /// a capsule's end caps waste the corners and read as an oversized pill.
    func thumbnailBadgeGlass(
        tint: Color = .black,
        opacity: Double = 0.6,
        in shape: AdaptiveGlassShape = .capsule
    ) -> some View {
        modifier(ThumbnailBadgeGlassModifier(tint: tint, opacity: opacity, shape: shape))
    }

    /// Liquid Glass behind content that is drawn light-on-dark. `.regular.tint()` shifts the
    /// material's hue but not its luminance — measured on macOS 27, raising a tint from 0.55 to 0.82
    /// alpha moved a card's median luminance only 132 → 138 — so a light-on-dark readout placed
    /// straight onto the material washes out (1.16:1 against the card, where the same readout on a
    /// painted card sits at 2.82:1). The scrim goes *between* the material and the content: the body
    /// stays legible while the edge keeps the glass ring and its refraction. No fallback path: below
    /// macOS 26 there is no Liquid Glass to fall back to, only an imitation. Callers gate on
    /// `AdaptiveGlass.isAvailable` and keep their own painted treatment for everything else.
    func adaptiveGlassScrimmed(cornerRadius: CGFloat, scrim: Color) -> some View {
        modifier(AdaptiveGlassScrimmedModifier(cornerRadius: cornerRadius, scrim: scrim))
    }

    /// Dark-tinted interactive glass circle for a single-glyph control over artwork
    /// (e.g. the hero close button). The dark tint keeps a white glyph legible over
    /// bright previews and firms up on hover.
    func floatingGlyphGlass(hovered: Bool) -> some View {
        modifier(FloatingGlyphGlassModifier(hovered: hovered))
    }
}

/// Whether this OS has real Liquid Glass, asked once instead of spelled as an
/// `#available` at each call site — which is the same reason every other glass
/// API in the app lives in this file.
public enum AdaptiveGlass {
    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

private struct AdaptiveGlassScrimmedModifier: ViewModifier {
    let cornerRadius: CGFloat
    let scrim: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        // Checked here as well as at the one current call site: the whole
        // material is transparency, and the next caller should not have to know
        // to gate it.
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(scrim)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
        }
    }
}

private struct FloatingGlyphGlassModifier: ViewModifier {
    let hovered: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(.black.opacity(hovered ? 0.32 : 0.18)).interactive(),
                in: .circle
            )
        } else {
            content.background(Circle().fill(.black.opacity(hovered ? 0.6 : 0.4)))
        }
    }
}

/// Whether badges floating over artwork use real Liquid Glass, or the cheap tinted fill. Glass
/// samples the content *behind* it every frame. One badge on a detail hero is exactly what the
/// material is for; forty cards' worth scrolling past is not — Apple's own guidance is to limit how
/// many glass effects are on screen at once and to reserve the material for the most important
/// controls rather than ordinary content metadata. `GalleryTileChrome` therefore switches every card
/// that scrolls in a gallery to `.opaque`, and the detail and inspector surfaces keep the default.
public enum ThumbnailBadgeSurface: Sendable {
    case glass
    case opaque
}

private struct ThumbnailBadgeSurfaceKey: EnvironmentKey {
    static let defaultValue = ThumbnailBadgeSurface.glass
}

public extension EnvironmentValues {
    var thumbnailBadgeSurface: ThumbnailBadgeSurface {
        get { self[ThumbnailBadgeSurfaceKey.self] }
        set { self[ThumbnailBadgeSurfaceKey.self] = newValue }
    }
}

public extension View {
    func thumbnailBadgeSurface(_ surface: ThumbnailBadgeSurface) -> some View {
        environment(\.thumbnailBadgeSurface, surface)
    }
}

private struct ThumbnailBadgeGlassModifier: ViewModifier {
    let tint: Color
    let opacity: Double
    var shape: AdaptiveGlassShape = .capsule

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.thumbnailBadgeSurface) private var surface

    @ViewBuilder
    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            backing(content, Capsule())
        case .circle:
            backing(content, Circle())
        case .roundedRectangle(let radius):
            backing(content, RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    @ViewBuilder
    private func backing<S: InsettableShape>(_ content: Content, _ shape: S) -> some View {
        if reduceTransparency {
            content.background(shape.fill(tint.opacity(1)))
        } else if #available(macOS 26.0, *), surface == .glass {
            // Native glass already blurs + refracts; a lighter tint than the
            // fallback keeps the badge legible without going muddy.
            content.glassEffect(.regular.tint(tint.opacity(opacity * 0.6)), in: shape)
        } else {
            // Also the `.opaque` path on macOS 26: a plain tinted fill with a
            // hairline, which is what every badge already looks like on 14/15.
            content.background {
                shape
                    .fill(tint.opacity(opacity))
                    .overlay(
                        shape.strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                    )
            }
        }
    }
}

private struct AdaptiveGlassSurfaceModifier: ViewModifier {
    let shape: AdaptiveGlassShape
    let tint: Color?
    let interactive: Bool
    var stroked: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var increaseContrast: Bool { colorSchemeContrast == .increased }

    private var tintOpacity: Double { colorScheme == .dark ? 0.20 : 0.11 }

    /// Boost the fallback tint opacity for interactive surfaces so that small
    /// circular / capsule selection targets (40-44pt) read clearly even against
    /// a busy wallpaper backdrop. Non-interactive surfaces keep the calmer value.
    private var fallbackTintOpacity: Double {
        if interactive {
            return colorScheme == .dark ? 0.30 : 0.20
        }
        return colorScheme == .dark ? 0.22 : 0.14
    }

    private var baseStrokeOpacity: Double {
        let base = colorScheme == .dark ? 0.32 : 0.22
        return increaseContrast ? min(base + 0.20, 0.6) : base
    }
    private var neutralStrokeOpacity: Double {
        let base = colorScheme == .dark ? 0.18 : 0.13
        return increaseContrast ? min(base + 0.20, 0.5) : base
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            // Honor Reduce Transparency on every OS — fallbackMaterial renders an
            // opaque window-background fill rather than native Liquid Glass.
            fallbackMaterial(content)
        } else if #available(macOS 26.0, *) {
            nativeGlass(content)
        } else {
            fallbackMaterial(content)
        }
    }

    @available(macOS 26.0, *)
    @ViewBuilder
    private func nativeGlass(_ content: Content) -> some View {
        let baseGlass: Glass = tint.map { .regular.tint($0.opacity(tintOpacity)) } ?? .regular
        let glass: Glass = interactive ? baseGlass.interactive() : baseGlass

        switch shape {
        case .circle:
            content
                .glassEffect(glass, in: .circle)
                .overlay { interactiveOutline(Circle()) }
        case .capsule:
            content
                .glassEffect(glass, in: .capsule)
                .overlay { interactiveOutline(Capsule()) }
        case .roundedRectangle(let radius):
            content
                .glassEffect(glass, in: .rect(cornerRadius: radius))
                .overlay { interactiveOutline(RoundedRectangle(cornerRadius: radius, style: .continuous)) }
        }
    }

    /// Native Liquid Glass's intrinsic edge highlight is subtle; interactive surfaces
    /// get a faint 0.5pt outline so low-vision users can locate hit areas. Non-interactive
    /// surfaces stay unmodified to preserve the native refraction feel.
    @available(macOS 26.0, *)
    @ViewBuilder
    private func interactiveOutline<S: InsettableShape>(_ shape: S) -> some View {
        if interactive {
            shape
                .strokeBorder(
                    Color.primary.opacity(increaseContrast ? 0.20 : 0.10),
                    lineWidth: increaseContrast ? 0.75 : 0.5
                )
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func fallbackMaterial(_ content: Content) -> some View {
        switch shape {
        case .circle:
            decorate(content, shape: Circle())
        case .capsule:
            decorate(content, shape: Capsule())
        case .roundedRectangle(let radius):
            decorate(content, shape: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }

    private func decorate<S: InsettableShape>(_ content: Content, shape: S) -> some View {
        let strokeColor: Color = tint?.opacity(baseStrokeOpacity)
            ?? Color.primary.opacity(neutralStrokeOpacity)
        let strokeWidth: CGFloat = increaseContrast ? 1.0 : 0.6

        return content
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(Color(nsColor: .windowBackgroundColor))
                        if let tint {
                            shape.fill(tint.opacity(fallbackTintOpacity))
                        }
                    } else {
                        if let tint {
                            shape.fill(tint.opacity(fallbackTintOpacity))
                        }
                        shape.fill(.regularMaterial)
                    }
                }
            }
            .overlay {
                if stroked {
                    shape.strokeBorder(strokeColor, lineWidth: strokeWidth)
                }
            }
            .contentShape(shape)
    }
}

private struct AdaptiveGlassButtonModifier: ViewModifier {
    let prominence: AdaptiveGlassProminence
    let shape: AdaptiveGlassButtonShape
    let size: ControlSize?

    private var borderShape: ButtonBorderShape {
        switch shape {
        case .capsule: return .capsule
        case .circle:  return .circle
        }
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            switch prominence {
            case .regular:
                sized(content).buttonStyle(.glass).buttonBorderShape(borderShape)
            case .prominent:
                sized(content).buttonStyle(.glassProminent).buttonBorderShape(borderShape)
            }
        } else {
            switch prominence {
            case .regular:
                sized(content)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(borderShape)
            case .prominent:
                sized(content)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(borderShape)
            }
        }
    }

    @ViewBuilder
    private func sized(_ content: Content) -> some View {
        if let size {
            content.controlSize(size)
        } else {
            content
        }
    }
}
