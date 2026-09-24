import CoreGraphics
import CoreImage
import LiveWallpaperCore
import SwiftUI

/// The HUD floats inside the hero's bottom edge.
private let detailHeroHUDHeight: CGFloat = 44

/// A web wallpaper's page transform as the hero edits it by dragging, pinching and twisting.
struct DetailWebTransform {
    let screen: Screen
    let config: Binding<HTMLConfig>
    /// The gestures attach only while "Adjust on the Preview" is on.
    let isArmed: Bool
}

/// The detail's preview: a still captured from the running wallpaper, so the HUD's controls reach
/// the desktop session and never this image.
struct DetailHero<HUD: View>: View {
    let status: DetailHeroStatus
    let image: CGImage?
    let size: CGSize
    @ViewBuilder let hud: () -> HUD
    var playback: (StagePlaybackAction) -> Void = { _ in }
    /// nil unless the hero shows a web wallpaper.
    var webTransform: DetailWebTransform?
    @State private var hovered = false
    @FocusState private var transportFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge, style: .continuous)
    }

    var body: some View {
        manipulableStill
            .frame(width: size.width, height: size.height)
            .clipShape(shape)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: DesignTokens.EditDesk.Spacing.s8) {
                    titleChip
                    pauseReasonChip
                }
                .frame(maxWidth: max(1, size.width - 76), alignment: .leading)
                .padding(DesignTokens.EditDesk.Spacing.s12)
            }
            .overlay(alignment: .topTrailing) {
                performanceChip.padding(DesignTokens.EditDesk.Spacing.s12)
            }
            .overlay(alignment: .bottom) { bottomBar }
            .overlay { transport }
            .overlay(shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeShell, lineWidth: 1).allowsHitTesting(false))
            .shadow(
                color: DesignTokens.EditDesk.Shadow.workshopCard.color,
                radius: DesignTokens.EditDesk.Shadow.workshopCard.radius,
                y: DesignTokens.EditDesk.Shadow.workshopCard.y
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: "\(status.title), \(status.kindLine)"))
            .contentShape(shape)
            .onContinuousHover { phase in
                switch phase {
                case .active: hovered = true
                case .ended: hovered = false
                }
            }
            .simultaneousGesture(TapGesture().onEnded { hovered = true })
    }

    // MARK: Still

    @ViewBuilder
    private var manipulableStill: some View {
        if let webTransform {
            // The still is a capture of the running page with its transform already applied; false
            // would draw the transform a second time.
            WebTransformCanvas(
                screen: webTransform.screen, config: webTransform.config,
                isArmed: webTransform.isArmed, baseIncludesTransform: true,
                baseVersion: image.map { AnyHashable(ObjectIdentifier($0)) }
            ) {
                still
            }
        } else {
            still
        }
    }

    /// `scaledToFill` + `clipped` matches the stage tile's `.resizeAspectFill`, so the shared-element
    /// handover does not jump.
    @ViewBuilder
    private var still: some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ZStack {
                DesignTokens.Colors.surfaceRaised
                Image(systemName: "photo")
                    .font(DesignTokens.EditDesk.Typography.modalTitle)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
            }
        }
    }

    // MARK: Chips

    private var titleChip: some View {
        chip {
            Text(verbatim: status.title)
                .font(DesignTokens.EditDesk.Typography.cardTitle)
            Text(verbatim: status.kindLine)
                .font(DesignTokens.EditDesk.Typography.metaMono)
                .foregroundStyle(DesignTokens.Colors.overlayForeground.opacity(DesignTokens.Opacity.dimmedIcon))
        }
    }

    /// `verbatim`: the reason arrives localized, and a second lookup would take the translation as a key.
    @ViewBuilder
    private var pauseReasonChip: some View {
        if let reason = status.pauseReason {
            chip {
                Image(systemName: "pause.fill")
                Text(verbatim: reason)
            }
            .font(DesignTokens.EditDesk.Typography.metaMono)
        }
    }

    @ViewBuilder
    private var performanceChip: some View {
        if let line = status.performanceLine {
            chip {
                Text(verbatim: line)
                    .font(DesignTokens.EditDesk.Typography.metaMono)
            }
        }
    }

    private func chip(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .foregroundStyle(DesignTokens.Colors.overlayForeground)
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip, style: .continuous)
                .fill(DesignTokens.EditDesk.Colors.mediaChipFill)
        )
    }

    // MARK: HUD

    private var transport: some View {
        HStack(spacing: 12) {
            if status.canNavigatePlaylist {
                GlassIconButton("backward.end.fill") { playback(.previous) }
                    .focused($transportFocused)
                    .help(Text("Previous Wallpaper"))
                    .accessibilityLabel(Text("Previous Wallpaper"))
            }
            GlassIconButton(status.intendsToPlay == true ? "pause.fill" : "play.fill") { playback(.toggle) }
                .focused($transportFocused)
                .disabled(status.intendsToPlay == nil)
                .help(Text(status.intendsToPlay == true ? "Pause" : "Play"))
                .accessibilityLabel(Text(status.intendsToPlay == true ? "Pause" : "Play"))
            if status.canNavigatePlaylist {
                GlassIconButton("forward.end.fill") { playback(.next) }
                    .focused($transportFocused)
                    .help(Text("Next Wallpaper"))
                    .accessibilityLabel(Text("Next Wallpaper"))
            }
        }
        // Keep the buttons in keyboard/VoiceOver navigation even while their paint is hidden.
        .opacity(hovered || transportFocused ? 1 : 0.001)
        .allowsHitTesting(hovered || transportFocused)
        .animation(.easeOut(duration: reduceMotion ? 0 : 0.16), value: hovered || transportFocused)
        .accessibilityElement(children: .contain)
    }

    private var bottomBar: some View {
        hud()
            .frame(height: detailHeroHUDHeight)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
            .padding(.bottom, DesignTokens.EditDesk.Spacing.s12)
    }
}

/// SCREENS.md S6's "封面 blur 80 saturate 1.2 opacity .25 scale 1.2" behind the whole page.
/// Core Image renders it once into a small bitmap; at this radius the cover carries no detail
/// worth a full-size blur every frame.
struct DetailBackdrop: View {
    let cover: CGImage?

    static let bitmapSize = CGSize(width: 160, height: 100)
    private nonisolated static let designWindowWidth: CGFloat = 1280
    private nonisolated static let designBlurRadius: CGFloat = 80

    /// The design's 80 is against a 1280pt window, so the radius is a fraction of the width, not a
    /// constant: on the 160px bitmap the same wash needs 10.
    nonisolated static func blurRadius(forWidth width: CGFloat) -> CGFloat {
        width * designBlurRadius / designWindowWidth
    }

    @State private var bitmap: CGImage?

    var body: some View {
        Color.clear
            .overlay {
                if let bitmap {
                    Image(decorative: bitmap, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.2)
                }
            }
            .clipped()
            .opacity(0.25)
            .allowsHitTesting(false)
            .task(id: cover.map(ObjectIdentifier.init)) {
                bitmap = Self.blurredBitmap(cover)
            }
    }

    static func blurredBitmap(_ source: CGImage?) -> CGImage? {
        guard let source, source.width > 0, source.height > 0 else { return nil }
        let extent = CGRect(origin: .zero, size: bitmapSize)
        let output = CIImage(cgImage: source)
            .transformed(by: CGAffineTransform(
                scaleX: bitmapSize.width / CGFloat(source.width),
                y: bitmapSize.height / CGFloat(source.height)
            ))
            // Without this the blur samples transparent black past the edges and the wash fades
            // out at the window's border instead of filling it.
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: blurRadius(forWidth: bitmapSize.width)]
            )
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2])
        return CIContext().createCGImage(output, from: extent)
    }
}
