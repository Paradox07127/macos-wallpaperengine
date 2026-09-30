import CoreGraphics
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
                    factsChip
                }
                .frame(maxWidth: max(1, size.width - 76), alignment: .leading)
                .padding(DesignTokens.EditDesk.Spacing.s12)
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
    private var factsChip: some View {
        if !status.facts.isEmpty {
            chip {
                Self.factsLine(status.facts)
                    .font(DesignTokens.EditDesk.Typography.metaMono)
            }
            .accessibilityElement(children: .combine)
            // Always a dark surface over media: a light app's warning tint would be unreadable on it.
            .environment(\.colorScheme, .dark)
        }
    }

    private static func factsLine(_ facts: [DetailFact]) -> Text {
        var line = Text(verbatim: "")
        for (index, fact) in facts.enumerated() {
            var item = Text(verbatim: fact.text)
            if fact.isWarning {
                let mark = Text(Image(systemName: "exclamationmark.triangle.fill"))
                    .foregroundStyle(DesignTokens.EditDesk.Colors.warning)
                item = mark + Text(verbatim: " ") + item
            }
            line = index > 0 ? line + Text(verbatim: " · ") + item : item
        }
        return line
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
