import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// Pure float-layer geometry and per-mode wording — kept static so tests drive it without a window.
enum FloatLayerGeometry {
    static let panelHeight: CGFloat = 104
    static let thumbnailHeight: CGFloat = 84

    /// SCREENS S5 quotes 150×84 and 130×84; deriving the width from the aspect ratio instead lands
    /// 1pt and 4pt off those, and is what keeps a portrait or ultrawide display from stretching.
    static func thumbnailWidth(aspect: CGFloat) -> CGFloat {
        min(max((thumbnailHeight * aspect).rounded(), 60), 150)
    }

    /// 160pt of strip per display over a 120pt run-in, never wider than the window less its gutters.
    static func stripWidth(count: Int, windowWidth: CGFloat) -> CGFloat {
        min(windowWidth - 48, CGFloat(count) * 160 + 120)
    }

    static func needsScroll(count: Int) -> Bool {
        count >= 5
    }

    static func captionKey(for mode: FloatLayerMode) -> String {
        switch mode {
        case .dropTarget: "Drag to a display\nto apply"
        case .selectTarget: "After downloading\napply to"
        }
    }

    static func highlightLabel(for mode: FloatLayerMode, displayName: String) -> String {
        switch mode {
        case .dropTarget: String(localized: "Drop to replace", bundle: .appLanguage)
        case .selectTarget: String(localized: "Selected · \(displayName)", bundle: .appLanguage)
        }
    }
}

/// SCREENS S5: the drop strip that rides above the modal. It reports where each thumbnail landed
/// and never hit-tests the drag itself — the host owns both the hit test and the apply.
struct DisplayFloatLayer: View {
    let targets: [ModalDisplayTarget]
    let mode: FloatLayerMode
    let highlighted: CGDirectDisplayID?
    let windowWidth: CGFloat
    let onSelect: (CGDirectDisplayID) -> Void
    let onApplyAll: () -> Void
    let onTargetFrame: (FloatTargetFrame) -> Void
    /// The thumbnail run's frame in `EditDeskCoordinateSpace`: with ≥5 displays it clips.
    let onRunFrame: (CGRect) -> Void

    @State private var isApplyAllHovering = false

    private var isScrolling: Bool {
        FloatLayerGeometry.needsScroll(count: targets.count)
    }

    var body: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            caption
            thumbnailRun
            Rectangle()
                .fill(DesignTokens.EditDesk.Colors.strokePanel)
                .frame(width: 1, height: 60)
            applyAllButton
        }
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
        .frame(height: FloatLayerGeometry.panelHeight)
        // Only the scrolling run can give width back, so the strip budget is what bounds the
        // panel there; below the threshold the thumbnails are rigid and the panel is their size.
        .frame(width: isScrolling ? FloatLayerGeometry.stripWidth(count: targets.count, windowWidth: windowWidth) : nil)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.floatPanel)
                .fill(DesignTokens.EditDesk.Colors.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.floatPanel)
                .strokeBorder(DesignTokens.EditDesk.Colors.strokePanel, lineWidth: 1)
        )
        .shadow(
            color: DesignTokens.EditDesk.Shadow.floatPanel.color,
            radius: DesignTokens.EditDesk.Shadow.floatPanel.radius,
            y: DesignTokens.EditDesk.Shadow.floatPanel.y
        )
    }

    private var caption: some View {
        Text(LocalizedStringKey(FloatLayerGeometry.captionKey(for: mode)))
            .font(DesignTokens.EditDesk.Typography.metaMono)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
            .frame(width: 70, alignment: .leading)
    }

    private var thumbnailRun: some View {
        Group {
            if isScrolling {
                ScrollView(.horizontal, showsIndicators: false) {
                    thumbnailRow
                }
                .frame(maxWidth: .infinity)
            } else {
                thumbnailRow
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EditDeskCoordinateSpace.name)) } action: {
            onRunFrame($0)
        }
    }

    private var thumbnailRow: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            ForEach(targets) { target in
                FloatDisplayThumbnail(
                    target: target,
                    mode: mode,
                    isHighlighted: highlighted == target.id,
                    onSelect: onSelect,
                    onTargetFrame: onTargetFrame
                )
            }
        }
    }

    private var applyAllButton: some View {
        Button(action: onApplyAll) {
            HStack(spacing: 4) {
                Text(verbatim: "⧉")
                Text("All Displays")
            }
            .font(DesignTokens.EditDesk.Typography.chip)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard)
                    .fill(DesignTokens.EditDesk.Colors.fillFloatButton)
            )
            .overlay {
                if isApplyAllHovering {
                    RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.gridCard)
                        .fill(DesignTokens.EditDesk.Colors.fillNavPill)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isApplyAllHovering = $0 }
    }
}

private struct FloatDisplayThumbnail: View {
    let target: ModalDisplayTarget
    let mode: FloatLayerMode
    let isHighlighted: Bool
    let onSelect: (CGDirectDisplayID) -> Void
    let onTargetFrame: (FloatTargetFrame) -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch mode {
        case .dropTarget:
            tile.allowsHitTesting(false)
        case .selectTarget:
            Button { onSelect(target.id) } label: { tile }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .accessibilityAddTraits(isHighlighted ? [.isButton, .isSelected] : .isButton)
        }
    }

    private var tile: some View {
        artwork
            .frame(width: FloatLayerGeometry.thumbnailWidth(aspect: target.aspectRatio), height: FloatLayerGeometry.thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip))
            .overlay { highlightOverlay }
            .overlay { hoverOverlay }
            .overlay(alignment: .bottomLeading) { name }
            .overlay(alignment: .topTrailing) { shortcutBadge }
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip)
                    .strokeBorder(
                        isHighlighted ? DesignTokens.EditDesk.Colors.success : DesignTokens.EditDesk.Colors.strokeShell,
                        lineWidth: isHighlighted ? 2 : 1
                    )
            }
            .shadow(color: isHighlighted ? DesignTokens.EditDesk.Colors.dropHighlightGlow : .clear, radius: 30)
            // The highlight is colour only, so Reduce Motion keeps a fade rather than snapping.
            .animation(.easeOut(duration: reduceMotion ? 0.15 : 0.18), value: isHighlighted)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(EditDeskCoordinateSpace.name)) } action: {
                onTargetFrame(FloatTargetFrame(id: target.id, rect: $0))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Drop target: \(target.name)"))
    }

    @ViewBuilder
    private var artwork: some View {
        if let thumbnail = target.thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            DesignTokens.Colors.surfaceRaised
        }
    }

    @ViewBuilder
    private var highlightOverlay: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip)
                .fill(DesignTokens.EditDesk.Colors.dropHighlight)
                .overlay {
                    Text(verbatim: FloatLayerGeometry.highlightLabel(for: mode, displayName: target.name))
                        .font(DesignTokens.EditDesk.Typography.dropLabel)
                        .foregroundStyle(DesignTokens.Colors.overlayForeground)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 4)
                }
        }
    }

    @ViewBuilder
    private var hoverOverlay: some View {
        if isHovering, !isHighlighted {
            RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip)
                .fill(DesignTokens.EditDesk.Colors.fillNavPill)
        }
    }

    private var name: some View {
        Text(verbatim: target.name)
            .font(DesignTokens.EditDesk.Typography.floatName)
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .lineLimit(1)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .padding(6)
    }

    private var shortcutBadge: some View {
        Text(verbatim: "⌘\(target.shortcutIndex)")
            .font(DesignTokens.EditDesk.Typography.badgeMono)
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.badge)
                    .fill(DesignTokens.EditDesk.Colors.mediaChipFill)
            )
            .padding(4)
    }
}
