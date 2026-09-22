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

/// Identical slots on both pages; labels remain in tooltips and accessibility.
struct DetailTopBar: View {
    let tags: [DetailDisplayTag]
    @Binding var section: DetailSection
    let actions: DetailActions
    @Binding var inspectorVisible: Bool
    @Binding var layersVisible: Bool
    var hasWallpaper = true
    @State private var schemeMenuPresented = false

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 68)
            icon("chevron.left", "Overview", action: actions.back)
            icon("sidebar.left", "Layers") { layersVisible.toggle() }
                .disabled(section != .overlay)
                .opacity(section == .overlay ? 1 : 0)
            Spacer(minLength: 8).background(WindowDragRegion())
            tagRow
            Spacer(minLength: 8).background(WindowDragRegion())
            sectionPicker
            if let openAutomation = actions.openAutomation {
                icon("list.bullet", "Queue & Schedule", action: openAutomation)
                    .disabled(!hasWallpaper)
            }
            icon("square.stack", "Scheme") { schemeMenuPresented.toggle() }
                .disabled(!hasWallpaper)
                .popover(isPresented: $schemeMenuPresented, arrowEdge: .bottom) {
                    Button("Save as Scheme") { schemeMenuPresented = false; actions.saveAsScheme() }
                        .buttonStyle(.borderless).padding(16)
                }
            icon("square.on.square", section == .overlay ? "Copy to Other Displays" : "Apply to All Displays") {
                section == .overlay ? actions.copyOverlays() : actions.applyToAll()
            }
            .disabled(section == .wallpaper && !hasWallpaper)
            if section == .overlay {
                icon(actions.snapEnabled.wrappedValue ? "viewfinder" : "viewfinder.circle", "Alignment Snapping") {
                    actions.snapEnabled.wrappedValue.toggle()
                }
                .accessibilityValue(Text(actions.snapEnabled.wrappedValue ? "On" : "Off"))
            } else {
                GlassIconButton("trash", size: .regular, tint: .red, role: .destructive, action: actions.clearWallpaper)
                    .help(Text("Clear Wallpaper"))
                    .accessibilityLabel(Text("Clear Wallpaper"))
                    .disabled(!hasWallpaper)
            }
            icon("sidebar.right", "Settings") { inspectorVisible.toggle() }
                .disabled(section == .wallpaper && !hasWallpaper)
        }
        .padding(.horizontal, 16)
        .frame(height: DetailGeometry.topBarHeight)
        .accessibilityElement(children: .contain)
    }

    private var tagRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(tags.prefix(DetailTagRow.visibleLimit))) { tag in
                Button { actions.selectDisplay(tag.id) } label: {
                    HStack(spacing: 7) {
                        Group {
                            if let image = tag.thumbnail {
                                Image(decorative: image, scale: 1).resizable().scaledToFill()
                            } else {
                                Image(systemName: "display").frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(width: 30, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.badge))
                        Text(verbatim: tag.name)
                            .font(DesignTokens.EditDesk.Typography.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 145)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm).fill(tag.isCurrent
                            ? DesignTokens.EditDesk.Colors.fillSelectedChip : DesignTokens.EditDesk.Colors.fillNavPill))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm).strokeBorder(tag.isCurrent ? Color.accentColor : .clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .help(tag.name)
                .accessibilityLabel(Text(verbatim: tag.name))
                .accessibilityAddTraits(tag.isCurrent ? .isSelected : [])
            }
            if tags.count > DetailTagRow.visibleLimit {
                Menu {
                    ForEach(Array(tags.dropFirst(DetailTagRow.visibleLimit))) { tag in
                        Button(tag.name) { actions.selectDisplay(tag.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 28)
                    .accessibilityLabel(Text("Displays"))
            }
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach([DetailSection.wallpaper, .overlay], id: \.self) { item in
                Button { section = item } label: {
                    Image(systemName: item == .wallpaper ? "photo" : "square.3.layers.3d")
                        .frame(width: 40, height: 28)
                        .background(Capsule().fill(section == item
                                ? DesignTokens.EditDesk.Colors.fillSelectedChip : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Text(item == .wallpaper ? "Wallpaper" : "Overlays"))
                .accessibilityLabel(Text(item == .wallpaper ? "Wallpaper" : "Overlays"))
                .accessibilityIdentifier(item == .wallpaper ? "detail.wallpaper" : "detail.overlay")
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
        }
        .padding(4)
        .adaptiveGlassSurface(.capsule, preferMaterial: true)
        .accessibilityElement(children: .contain)
        .fixedSize()
    }

    private func icon(_ symbol: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        GlassIconButton(symbol, size: .regular, action: action)
            .help(Text(label))
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier("detail.\(symbol)")
    }
}
