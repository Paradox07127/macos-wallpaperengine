import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// SCREENS.md S6 keeps three display tags in the top bar; the rest collapse into a `+n`.
enum DetailTagRow {
    static let visibleLimit = 3

    /// A current display past the first three takes the last visible slot, so the page always names it.
    static func split(_ tags: [DetailDisplayTag]) -> (visible: [DetailDisplayTag], overflow: Int) {
        guard tags.count > visibleLimit else { return (tags, 0) }
        var visible = Array(tags.prefix(visibleLimit))
        if let current = tags.dropFirst(visibleLimit).first(where: \.isCurrent) {
            visible[visibleLimit - 1] = current
        }
        return (visible, tags.count - visibleLimit)
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
    var schedulePausedUntil: Date?
    /// True while the column shows a load attempt's page, which carries this display's only Clear; the
    /// actions reading the applied wallpaper (queue, scheme, apply to all) stay dimmed under it too.
    var attemptShown = false
    @State private var schemeMenuPresented = false
    @State private var changeMenuPresented = false
    @State private var schemeStore = SchemeStore.shared

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
            if section == .wallpaper, let until = schedulePausedUntil, let resume = actions.resumeSchedule {
                schedulePause(until: until, resume: resume)
            }
            if section == .wallpaper {
                icon("rectangle.2.swap", "Change Wallpaper") { changeMenuPresented.toggle() }
                    .appLanguagePopover(isPresented: $changeMenuPresented, arrowEdge: .bottom) { changeMenu }
                icon("arrow.triangle.2.circlepath", "Reload display", help: Text("Reload display content")) { actions.reload() }
                    .disabled(!hasWallpaper || attemptShown)
            }
            if let openAutomation = actions.openAutomation {
                icon("list.bullet", "Playlist & Schedule", action: openAutomation)
                    .disabled(!hasWallpaper || attemptShown)
            }
            icon("square.stack", "Scheme") {
                if schemeStore.schemes.isEmpty {
                    actions.saveAsScheme()
                } else {
                    schemeMenuPresented.toggle()
                }
            }
            .disabled(!hasWallpaper || attemptShown)
            .appLanguagePopover(isPresented: $schemeMenuPresented, arrowEdge: .bottom) { schemeMenu }
            icon(
                "square.on.square", section == .overlay ? "Copy to Other Displays" : "Apply to All Displays",
                help: tags.count < 2 ? Text("Only one display is connected.") : nil
            ) {
                section == .overlay ? actions.copyOverlays() : actions.applyToAll()
            }
            .disabled(tags.count < 2 || (section == .wallpaper && (!hasWallpaper || attemptShown)))
            if section == .overlay {
                icon(actions.snapEnabled.wrappedValue ? "viewfinder" : "viewfinder.circle", "Alignment Snapping") {
                    actions.snapEnabled.wrappedValue.toggle()
                }
                .accessibilityValue(Text(actions.snapEnabled.wrappedValue ? "On" : "Off"))
            } else {
                GlassIconButton("trash", size: .regular, tint: .red, role: .destructive, action: actions.clearWallpaper)
                    .help(Text("Clear Wallpaper"))
                    .accessibilityLabel(Text("Clear Wallpaper"))
                    .disabled(!hasWallpaper || attemptShown)
            }
            icon("sidebar.right", "Settings") { inspectorVisible.toggle() }
                .disabled(section == .wallpaper && !hasWallpaper)
        }
        .padding(.horizontal, 16)
        .frame(height: DetailGeometry.topBarHeight)
        .accessibilityElement(children: .contain)
        .onChange(of: tags.first(where: \.isCurrent)?.id) {
            schemeMenuPresented = false
            changeMenuPresented = false
        }
    }

    private var tagRow: some View {
        let split = DetailTagRow.split(tags)
        return HStack(spacing: 8) {
            ForEach(split.visible) { tag in
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
            if split.overflow > 0 {
                Menu {
                    ForEach(tags.filter { tag in !split.visible.contains { $0.id == tag.id } }) { tag in
                        Button(tag.name) { actions.selectDisplay(tag.id) }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 28)
                    .help(Text("Displays"))
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
        .adaptiveGlassSurface(.capsule)
        .accessibilityElement(children: .contain)
        .fixedSize()
    }

    private func schedulePause(until: Date, resume: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            StatusChip(
                text: Text(
                    "Schedule paused until \(until, format: .dateTime.hour().minute())",
                    comment: "Detail notice: this display's daily schedule is paused until the given time."
                ),
                tint: DesignTokens.Colors.Status.info,
                systemImage: "pause.circle"
            )
            Button(action: resume) {
                Text("Resume", comment: "Detail top bar button that resumes this display's paused daily schedule.")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(Text("Apply this time slot's wallpaper now", comment: "Tooltip on the button that resumes a paused daily schedule."))
            .accessibilityLabel(Text("Resume Schedule", comment: "Resumes this display's paused daily schedule."))
        }
        .accessibilityElement(children: .contain)
    }

    private var schemeMenu: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Button("Save as Scheme") {
                schemeMenuPresented = false
                actions.saveAsScheme()
            }
            Divider()
            Text("Apply to This Display")
                .font(DesignTokens.Typography.badge)
                .foregroundStyle(.secondary)
            ForEach(schemeStore.schemes) { scheme in
                Button {
                    schemeMenuPresented = false
                    actions.applyScheme(scheme)
                } label: {
                    Text(verbatim: scheme.name).lineLimit(1)
                }
            }
            Divider()
            Button("Manage Schemes") {
                schemeMenuPresented = false
                actions.manageSchemes()
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPopoverChrome(width: 240)
    }

    private var changeMenu: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if let chooseFromLibrary = actions.chooseFromLibrary {
                Button("Choose from Library") {
                    changeMenuPresented = false
                    chooseFromLibrary()
                }
            }
            Button("Import and Apply to \(tags.first(where: \.isCurrent)?.name ?? "")") {
                changeMenuPresented = false
                actions.importFile()
            }
            Button("Enter Web Address") {
                changeMenuPresented = false
                actions.enterWebAddress()
            }
            if actions.switchBackToVideo != nil || actions.switchBackToWebPage != nil {
                Divider()
            }
            if let switchBack = actions.switchBackToVideo {
                Button("Switch Back to Previous Video") {
                    changeMenuPresented = false
                    switchBack()
                }
            }
            if let switchBack = actions.switchBackToWebPage {
                Button("Switch Back to Previous Web Page") {
                    changeMenuPresented = false
                    switchBack()
                }
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsPopoverChrome(width: 260)
    }

    /// `help` replaces the label as the tooltip, for a control that has to say why it is dimmed.
    private func icon(
        _ symbol: String, _ label: LocalizedStringKey, help: Text? = nil, action: @escaping () -> Void
    ) -> some View {
        GlassIconButton(symbol, size: .regular, action: action)
            .help(help ?? Text(label))
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier("detail.\(symbol)")
    }
}
