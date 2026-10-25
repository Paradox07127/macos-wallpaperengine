import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// Identical slots on both pages; labels remain in tooltips and accessibility.
struct DetailTopBar: View {
    let tags: [DetailDisplayTag]
    @Binding var section: DetailSection
    let actions: DetailActions
    @Binding var inspectorVisible: Bool
    var hasWallpaper = true
    /// The shown display, which Save as Scheme captures; nil leaves the popover empty.
    var screen: Screen?
    /// True while the column shows a load attempt's page, which carries this display's only Clear; the
    /// actions reading the applied wallpaper (queue, scheme, apply to all) stay dimmed under it too.
    var attemptShown = false
    let segments: Namespace.ID
    /// False while the automation page's mode control holds the shared segment geometry.
    var segmentsAreSource = true
    @Environment(ScreenManager.self) private var screenManager: ScreenManager?
    @State private var bookmarkPresented = false
    @State private var schemeStore = SchemeStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 68)
            GlassToolbarGroup {
                icon("chevron.left", actions.backLabel, action: actions.back)
            }
            displayPicker
            Spacer(minLength: 8).background(WindowDragRegion())
            AdaptiveGlassContainer(spacing: GlassToolbarMetrics.containerSpacing) {
                HStack(spacing: GlassToolbarMetrics.groupSpacing) {
                    sectionPicker.pageGuideTarget(.detailLayers)
                    GlassToolbarGroup { displayActions }.pageGuideTarget(.detailActions)
                    GlassToolbarGroup { sharedActions }.pageGuideTarget(.detailShared)
                    GlassToolbarGroup {
                        PageGuideButton(context: section == .wallpaper ? .configuration : .overlays, grouped: true)
                        icon("sidebar.right", "Settings") { inspectorVisible.toggle() }
                            .disabled(section == .wallpaper && !hasWallpaper)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: DetailGeometry.topBarHeight)
        .accessibilityElement(children: .contain)
        .onChange(of: tags.first(where: \.isCurrent)?.id) {
            bookmarkPresented = false
            actions.schemeCapturePresented.wrappedValue = false
        }
    }

    /// First capsule: what this display shows — change, clear; snapping in the overlay section.
    @ViewBuilder
    private var displayActions: some View {
        if section == .wallpaper {
            NativeMenuButton(toolbarItem: true) { changeMenu } label: {
                menuIcon("rectangle.2.swap")
            }
            .help(Text("Change Wallpaper"))
            .accessibilityLabel(Text("Change Wallpaper"))
            GlassToolbarItem("trash", role: .destructive, action: actions.clearWallpaper)
                .help(Text("Clear Wallpaper"))
                .accessibilityLabel(Text("Clear Wallpaper"))
                .disabled(!hasWallpaper || attemptShown)
        } else {
            icon(actions.snapEnabled.wrappedValue ? "viewfinder" : "viewfinder.circle", "Alignment Snapping") {
                actions.snapEnabled.wrappedValue.toggle()
            }
            .accessibilityValue(Text(actions.snapEnabled.wrappedValue ? "On" : "Off"))
        }
    }

    /// Second capsule: what reaches past this display — playlist and schedule, schemes, the other displays.
    @ViewBuilder
    private var sharedActions: some View {
        if let openAutomation = actions.openAutomation {
            icon("clock.arrow.circlepath", "Wallpaper Automation", action: openAutomation)
                .disabled(!hasWallpaper || attemptShown)
        }
        let bookmarked = actions.bookmark?.isBookmarked == true
        // Only a saved entry can be renamed; the popover offers Workshop and aerial rows removal alone.
        let markedHelp = actions.bookmark?.saved == nil ? Text("Bookmarked") : Text("Bookmarked — click to rename or remove")
        icon(bookmarked ? "bookmark.fill" : "bookmark", bookmarked ? "Bookmarked" : "Bookmark",
             help: bookmarked ? markedHelp : Text("Bookmark this wallpaper")) {
            bookmarkPresented.toggle()
        }
        .disabled(attemptShown)
        .appLanguagePopover(isPresented: $bookmarkPresented, arrowEdge: .bottom) {
            DetailBookmarkPopover(target: actions.bookmark) { bookmarkPresented = false }
        }
        Group {
            if schemeStore.schemes.isEmpty {
                icon("square.stack", "Scheme", action: actions.saveAsScheme)
            } else {
                NativeMenuButton(toolbarItem: true) { schemeMenu } label: { menuIcon("square.stack") }
                    .help(Text("Scheme"))
                    .accessibilityLabel(Text("Scheme"))
            }
        }
        .disabled(!hasWallpaper || attemptShown)
        .appLanguagePopover(isPresented: actions.schemeCapturePresented, arrowEdge: .bottom) {
            if let screen, let screenManager {
                SchemeCapturePopover(screen: screen, nameDraft: actions.schemeNameDraft)
                    .environment(screenManager)
            }
        }
        icon(
            "square.on.square", section == .overlay ? "Copy to Other Displays" : "Apply to All Displays",
            help: tags.count < 2 ? Text("Only one display is connected.") : nil
        ) {
            section == .overlay ? actions.copyOverlays() : actions.applyToAll()
        }
        .disabled(tags.count < 2 || (section == .wallpaper && (!hasWallpaper || attemptShown)))
    }

    /// Shown with a single display too, so the page always names the display it edits.
    private var displayPicker: some View {
        let current = tags.first(where: \.isCurrent)
        return GlassToolbarGroup {
            NativeMenuButton(toolbarItem: true) {
                Picker("Displays", selection: displaySelection) {
                    ForEach(tags) { tag in
                        Text(verbatim: tag.name).tag(Optional(tag.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Group {
                        if let image = current?.thumbnail {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else {
                            Image(systemName: "display").frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 30, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.badge))
                    Text(verbatim: current?.name ?? "")
                        .font(DesignTokens.EditDesk.Typography.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 180)
                    Image(systemName: "chevron.down")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .frame(height: GlassToolbarMetrics.height)
            }
            .help(Text("Displays"))
            .accessibilityLabel(Text("Displays"))
            .accessibilityValue(Text(verbatim: current?.name ?? ""))
        }
        .fixedSize()
    }

    private var displaySelection: Binding<CGDirectDisplayID?> {
        Binding(get: { tags.first(where: \.isCurrent)?.id }, set: { id in
            if let id {
                actions.selectDisplay(id)
            }
        })
    }

    private var sectionPicker: some View {
        GlassSegmentedPicker(selection: $section, values: [DetailSection.wallpaper, .overlay], shell: .detail) { item, _ in
            Image(systemName: item == .wallpaper ? "photo" : "square.3.layers.3d")
                .imageScale(.large)
                .help(Text(item == .wallpaper ? "Wallpaper" : "Overlays"))
                .accessibilityLabel(Text(item == .wallpaper ? "Wallpaper" : "Overlays"))
                .accessibilityIdentifier(item == .wallpaper ? "detail.wallpaper" : "detail.overlay")
        }
        .accessibilityElement(children: .contain)
        .fixedSize()
        .detailSegmentsMorph(in: segments, isSource: segmentsAreSource)
    }

    @ViewBuilder
    private var schemeMenu: some View {
        if !schemeStore.schemes.isEmpty {
            ForEach(schemeStore.schemes) { scheme in
                Button {
                    actions.applyScheme(scheme)
                } label: {
                    Text(verbatim: scheme.name).lineLimit(1)
                }
            }
            Divider()
        }
        Button("Save as Scheme") {
            actions.saveAsScheme()
        }
        Button("Manage Schemes") {
            actions.manageSchemes()
        }
    }

    @ViewBuilder
    private var changeMenu: some View {
        if let chooseFromLibrary = actions.chooseFromLibrary {
            Button("Choose from Library") {
                chooseFromLibrary()
            }
        }
        Button("Import and Apply to \(tags.first(where: \.isCurrent)?.name ?? "")") {
            actions.importFile()
        }
        Button("Enter Web Address") {
            actions.enterWebAddress()
        }
        if let switchBack = actions.switchBackToVideo {
            Button("Switch Back to Previous Video") {
                switchBack()
            }
        }
        if let switchBack = actions.switchBackToWebPage {
            Button("Switch Back to Previous Web Page") {
                switchBack()
            }
        }
    }

    private func menuIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(DesignTokens.Typography.body)
            .imageScale(.large)
            .frame(width: GlassToolbarMetrics.height, height: GlassToolbarMetrics.height)
    }

    /// `help` replaces the label as the tooltip, for a control that has to say why it is dimmed.
    private func icon(
        _ symbol: String, _ label: LocalizedStringKey, help: Text? = nil, action: @escaping () -> Void
    ) -> some View {
        GlassToolbarItem(symbol, action: action)
            .help(help ?? Text(label))
            .accessibilityLabel(Text(label))
            .accessibilityIdentifier("detail.\(symbol)")
    }
}

extension View {
    /// The detail's section control and the automation page's mode control: the source sets the frame both share.
    func detailSegmentsMorph(in namespace: Namespace.ID, isSource: Bool) -> some View {
        matchedGeometryEffect(id: "detailSegments", in: namespace, isSource: isSource)
    }
}
