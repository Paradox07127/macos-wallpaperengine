import LiveWallpaperCore
import SwiftUI

/// Card grid for a display with no saved configuration.
struct EmptyStateGuideView: View {
    let onChooseVideo: () -> Void
    let onChooseHTML: () -> Void
    let onChooseScene: () -> Void

    @Environment(\.featureCatalog) private var featureCatalog

    var body: some View {
        // Centred in the pane, but still scrollable: `minHeight` = the viewport
        // makes the content sit dead centre while it fits, and lets it grow and
        // scroll normally once it doesn't. Plain centring would clip the top on
        // a short window; a plain ScrollView pins it to the top.
        GeometryReader { geo in
            ScrollView {
                guideColumn
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var guideColumn: some View {
        VStack(spacing: 16) {
            header

            // One column per card, not `.adaptive` — the types are peers and
            // read as a single row of choices. Adaptive sizing wrapped Scene
            // onto its own line and made the three look unrelated.
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 14),
                    count: max(cards.count, 1)
                ),
                spacing: 12
            ) {
                ForEach(cards) { card in
                    GuideCard(
                        icon: card.icon,
                        iconTint: card.iconTint,
                        title: card.title,
                        subtitle: card.subtitle,
                        accessibilityLabel: card.accessibilityLabel,
                        action: card.action
                    )
                }
            }
            .padding(.horizontal, 4)

            // Balances the header so the *cards* land on the pane's midline,
            // not the header-plus-cards block. Centring the column put the row
            // half a header below centre.
            header
                .hidden()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: 880)
    }

    private var cards: [GuideCardModel] {
        var models: [GuideCardModel] = [
            GuideCardModel(
                id: "video",
                icon: "film",
                iconTint: .blue,
                title: "Video",
                subtitle: videoSubtitle,
                accessibilityLabel: "Video wallpaper type",
                action: onChooseVideo
            ),
            GuideCardModel(
                id: "web",
                icon: "globe",
                iconTint: .green,
                title: "Web",
                subtitle: "Web pages, local .html files, and folders.",
                accessibilityLabel: "Web wallpaper type",
                action: onChooseHTML
            ),
        ]
        if featureCatalog.isEnabled(.scene) {
            models.append(
                GuideCardModel(
                    id: "scene",
                    icon: "cube.transparent",
                    iconTint: .purple,
                    title: "Scene",
                    subtitle: "Compatible imported scenes.",
                    accessibilityLabel: "Scene wallpaper type",
                    action: onChooseScene
                )
            )
        }
        return models
    }

    private var videoSubtitle: LocalizedStringKey {
        featureCatalog.isEnabled(.playlists) || featureCatalog.isEnabled(.scheduleAutomation)
            ? "MP4 / MOV, playlists, and schedules."
            : "MP4 / MOV from your Mac."
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)

            Text("Set up this display")
                .font(DesignTokens.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
        }
    }

}

/// Card contents, so the grid's column count can follow how many types this SKU
/// actually offers.
private struct GuideCardModel: Identifiable {
    let id: String
    let icon: String
    let iconTint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let accessibilityLabel: LocalizedStringKey
    let action: () -> Void
}

private struct GuideCard: View {
    let icon: String
    let iconTint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let accessibilityLabel: LocalizedStringKey
    var badge: String?
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isFocused }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .fill(iconTint.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(iconTint)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityHidden(true)

                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(DesignTokens.Typography.sectionTitle)
                        if let badge {
                            TypeBadge(badge, tint: iconTint)
                        }
                    }
                    Text(subtitle)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(minHeight: 128, alignment: .center)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? Color.accentColor.opacity(0.45)
                            : Color.primary.opacity(DesignTokens.Card.strokeOpacity),
                        lineWidth: isActive ? 1.5 : DesignTokens.Card.strokeWidth
                    )
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .scaleEffect(isActive && !reduceMotion ? 1.015 : 1.0)
        .shadow(
            color: .black.opacity(isActive ? DesignTokens.Card.shadowOpacity : DesignTokens.Card.strokeOpacity),
            radius: isActive ? DesignTokens.Card.shadowRadius : 4,
            x: 0,
            y: isActive ? DesignTokens.Card.shadowYOffset : 2
        )
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.32, dampingFraction: 0.86)), value: isHovering)
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.32, dampingFraction: 0.86)), value: isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityHint(Text(subtitle))
    }
}
