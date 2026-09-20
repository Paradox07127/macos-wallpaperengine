import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// SCREENS.md S6 keeps three display tags in the top bar; the rest collapse into a `+n`.
enum DetailTagRow {
    static let visibleLimit = 3

    static func split(_ tags: [DetailDisplayTag]) -> (visible: [DetailDisplayTag], overflow: Int) {
        guard tags.count > visibleLimit else { return (tags, 0) }
        return (Array(tags.prefix(visibleLimit)), tags.count - visibleLimit)
    }
}

/// SCREENS.md S6's 56pt bar: back to the overview, the display tags, and the per-display actions.
struct DetailTopBar: View {
    let tags: [DetailDisplayTag]
    @Binding var section: DetailSection
    let actions: DetailActions
    @State private var schemeMenuPresented = false

    /// Traffic lights live in the transparent title bar, same reserve as `Shell/TopBar.swift`.
    private static let trafficLightReserve: CGFloat = 68
    private static let tagHeight: CGFloat = 30
    private static let thumbnailSize = CGSize(width: 26, height: 15)

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.trafficLightReserve)
            backButton
            if section == .overlay {
                tagRow.padding(.leading, DesignTokens.EditDesk.Spacing.s12)
            }
            Spacer(minLength: DesignTokens.EditDesk.Spacing.s12)
            trailingControls
        }
        .overlay(alignment: .center) {
            if section == .wallpaper {
                tagRow
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(height: DesignTokens.EditDesk.Spacing.topBar)
    }

    // MARK: Back

    private var backButton: some View {
        DetailPill(action: actions.back) {
            Text(verbatim: "←")
            Text("Overview")
        }
        .accessibilityLabel(Text("Overview"))
    }

    // MARK: Display tags

    private var tagRow: some View {
        let split = DetailTagRow.split(tags)
        return HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            ForEach(split.visible) { tag in
                displayTag(tag)
            }
            if split.overflow > 0 {
                overflowTag(split.overflow)
            }
        }
    }

    private func displayTag(_ tag: DetailDisplayTag) -> some View {
        Button {
            actions.selectDisplay(tag.id)
        } label: {
            HStack(spacing: 6) {
                thumbnail(tag)
                Text(verbatim: tag.name)
                    .font(DesignTokens.EditDesk.Typography.chip)
                    .foregroundStyle(
                        tag.isCurrent
                            ? DesignTokens.EditDesk.Colors.textPrimary
                            : DesignTokens.EditDesk.Colors.textSecondary
                    )
                    .lineLimit(1)
            }
            .padding(.leading, 6)
            .padding(.trailing, DesignTokens.EditDesk.Spacing.s12)
            .frame(height: Self.tagHeight)
            .background(
                Capsule().fill(
                    tag.isCurrent
                        ? DesignTokens.EditDesk.Colors.fillSelectedChip
                        : DesignTokens.EditDesk.Colors.fillNavPill
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(DetailPressStyle())
        .accessibilityAddTraits(tag.isCurrent ? .isSelected : [])
    }

    private func thumbnail(_ tag: DetailDisplayTag) -> some View {
        Group {
            if let image = tag.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                DesignTokens.Colors.surfaceRaised
            }
        }
        .frame(width: Self.thumbnailSize.width, height: Self.thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.badge, style: .continuous))
    }

    private func overflowTag(_ count: Int) -> some View {
        Text(verbatim: "+\(count)")
            .font(DesignTokens.EditDesk.Typography.metaMono)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textSecondary)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
            .frame(height: Self.tagHeight)
            .background(Capsule().fill(DesignTokens.EditDesk.Colors.fillNavPill))
    }

    // MARK: Actions

    private var trailingControls: some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s12) {
            GlassSegmentedPicker(
                selection: $section,
                values: [DetailSection.wallpaper, .overlay],
                shell: .editDesk
            ) { item, isSelected in
                Text(Self.sectionTitle(item))
                    .font(DesignTokens.EditDesk.Typography.navItem)
                    .foregroundStyle(
                        isSelected
                            ? DesignTokens.EditDesk.Colors.textPrimary
                            : DesignTokens.EditDesk.Colors.textSecondary
                    )
            }
            .fixedSize()
            schemeMenu
            if section == .overlay {
                DetailPill(action: actions.copyOverlays) {
                    Text(verbatim: "⧉")
                    Text("Copy to Other Displays")
                }
                Toggle(isOn: actions.snapEnabled) {
                    Text(verbatim: "▦")
                    Text("Alignment Snapping")
                }
                .toggleStyle(.button)
                .font(DesignTokens.EditDesk.Typography.chip)
                .tint(DesignTokens.EditDesk.Colors.fillSelectedChip)
            } else {
                GlassIconButton("square.on.square", action: actions.applyToAll)
                    .accessibilityLabel(Text("Apply to All Displays"))
                GlassIconButton(
                    "trash",
                    tint: DesignTokens.EditDesk.Colors.danger,
                    role: .destructive,
                    action: actions.clearWallpaper
                )
                .accessibilityLabel(Text("Clear Wallpaper"))
            }
        }
    }

    /// A `Menu` with `.borderlessButton` drops everything but the first glyph of a custom label.
    private var schemeMenu: some View {
        DetailPill(action: { schemeMenuPresented.toggle() }, label: {
            Text(verbatim: "◈")
            Text("Scheme")
            Text(verbatim: "▾")
        })
        .accessibilityLabel(Text("Scheme"))
        .popover(isPresented: $schemeMenuPresented, arrowEdge: .bottom) {
            Button("Save as Scheme") {
                schemeMenuPresented = false
                actions.saveAsScheme()
            }
            .buttonStyle(.borderless)
            .padding(DesignTokens.Spacing.md)
        }
    }

    private static func sectionTitle(_ section: DetailSection) -> LocalizedStringKey {
        switch section {
        case .wallpaper: "Wallpaper"
        case .overlay: "Overlays"
        }
    }
}

/// The 28pt capsule the back button uses: a flat token fill, so hover and press are drawn here
/// rather than inherited from a system style.
private struct DetailPill<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                label()
            }
            .font(DesignTokens.EditDesk.Typography.chip)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
            .frame(height: 28)
            .background(
                Capsule().fill(
                    isHovering
                        ? DesignTokens.EditDesk.Colors.fillSelectedChip
                        : DesignTokens.EditDesk.Colors.fillNavPill
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(DetailPressStyle())
        .onHover { isHovering = $0 }
    }
}

private struct DetailPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? DesignTokens.Opacity.dimmedIcon : 1)
    }
}
