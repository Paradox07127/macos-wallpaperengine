import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// SCREENS.md S4: the library's wallpaper modal, drawn as an overlay inside `HomePage`'s ZStack
/// rather than a sheet, because the display float layer has to stay reachable above it. Values
/// arrive through `WallpaperModalContract`; this view draws them and hands events back out.
@MainActor
struct WallpaperModal: View {
    let content: WallpaperModalContent
    let targets: [ModalDisplayTarget]
    let actions: WallpaperModalActions
    let navigation: ModalNavigation
    /// The stage's own `bounds.size`. A `GeometryReader` here would measure one title bar short.
    let windowSize: CGSize
    /// Height the scrim leaves untouched so the traffic lights and window drag still work.
    let titlebarInset: CGFloat
    let onDismiss: () -> Void
    let onDrag: (ModalDragPhase) -> Void

    /// A drag ESC cancelled must not restart on the next `onChanged`: the gesture keeps reporting
    /// until the mouse comes up.
    private enum DragState: Equatable { case idle, active, cancelled }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragState: DragState = .idle
    @State private var isNavigatingForward = true
    @State private var confirmingDelete = false
    #if !LITE_BUILD
    @Environment(SteamCMDDoctorService.self) private var doctor: SteamCMDDoctorService?
    #endif

    private static let barPadding: CGFloat = 20

    var body: some View {
        EditDeskModalChrome(
            windowSize: windowSize,
            titlebarInset: titlebarInset,
            backdrop: nil,
            panelFrameOverride: LibraryDetailGeometry.panelFrame(in: windowSize),
            onDismiss: onDismiss,
            onEscape: cancelDragForEscape,
            onTargetShortcut: applyToShortcut
        ) { panel in
            panelBody(panel)
                .id(content.itemID)
        }
    }

    // MARK: Panel

    private func panelBody(_ panel: CGRect) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: content.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    previewArea(size: LibraryDetailGeometry.previewSize(in: panel))
                    metadata
                    HStack(spacing: 12) {
                        if let reveal = actions.showInFinder {
                            GlassIconButton("folder", size: .regular, action: reveal)
                                .help(Text("Show in Finder")).accessibilityLabel(Text("Show in Finder"))
                        }
                        if let open = actions.openInSteam {
                            GlassIconButton("arrow.up.forward.app", size: .regular, action: open)
                                .help(Text("Open in Steam")).accessibilityLabel(Text("Open in Steam"))
                        }
                        if actions.addToPlaylist != nil || actions.schedule != nil {
                            addMenu
                        }
                        moreMenu
                    }
                }
                .frame(width: LibraryDetailGeometry.previewSize(in: panel).width)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let description = content.descriptionText, !description.isEmpty {
                            Text("About this wallpaper").font(.headline)
                            Text(verbatim: description).font(.body).textSelection(.enabled)
                        }
                        if !content.tags.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], alignment: .leading, spacing: 8) {
                                ForEach(content.tags, id: \.self) { tag in
                                    Text(verbatim: tag).font(.caption).lineLimit(1)
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .frame(maxWidth: .infinity)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                        communityPresets
                        if !content.dependencyIDs.isEmpty {
                            Text("Dependencies").font(.headline)
                            ForEach(content.dependencyIDs, id: \.self) { id in
                                if let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") {
                                    Link(destination: url) { Label(id, systemImage: "shippingbox") }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            HStack(spacing: 12) {
                GlassIconButton("chevron.left", size: .regular) { navigate(forward: false) }
                    .disabled(!navigation.canGoPrevious)
                    .help(Text("Previous Wallpaper")).accessibilityLabel(Text("Previous Wallpaper"))
                GlassIconButton("chevron.right", size: .regular) { navigate(forward: true) }
                    .disabled(!navigation.canGoNext)
                    .help(Text("Next Wallpaper")).accessibilityLabel(Text("Next Wallpaper"))
                Spacer(minLength: 16)
                applyControls
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .overlay { shortcuts }
        .confirmationDialog(
            Text("Delete this wallpaper?"),
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            deleteConfirmButton
            Button("Cancel", role: .cancel) {}
        } message: {
            deleteMessage
        }
    }

    // MARK: Preview

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge, style: .continuous)
    }

    private func previewArea(size: CGSize) -> some View {
        ZStack {
            previewImage(size: size)
                .id(content.itemID)
                .transition(previewTransition)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(previewShape)
        .animation(navigationAnimation, value: content.itemID)
        .overlay(previewShape.strokeBorder(DesignTokens.EditDesk.Colors.strokeBadge, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            mediaChip(Text("Still preview · \(Self.kindName(content.kind))"))
                .padding(DesignTokens.EditDesk.Spacing.s8)
        }
        // MOTION 7 asks for .3 under the ghost; `quietStroke` is the nearest step in the scale.
        .opacity(dragState == .active ? DesignTokens.Opacity.quietStroke : 1)
        .accessibilityLabel(Text(verbatim: "\(content.title), \(Self.kindName(content.kind))"))
        .gesture(dragGesture, including: content.isDraggable ? .all : .subviews)
        .grabCursor(content.isDraggable)
    }

    @ViewBuilder
    private func previewImage(size: CGSize) -> some View {
        if let image = content.preview {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
        } else {
            ZStack {
                DesignTokens.Colors.surfaceRaised
                Image(systemName: Self.placeholderSymbol(content.kind))
                    .font(DesignTokens.EditDesk.Typography.modalTitle)
                    .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func mediaChip(_ label: Text) -> some View {
        label
            .font(DesignTokens.EditDesk.Typography.metaMono)
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s8)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.chip, style: .continuous)
                    .fill(DesignTokens.EditDesk.Colors.mediaChipFill)
            )
    }

    @ViewBuilder
    private var presetCapsule: some View {
        if let presetName = content.presetName {
            Text("◈ Preset \(presetName) ▾")
                .font(DesignTokens.EditDesk.Typography.chip)
                .foregroundStyle(DesignTokens.Colors.overlayForeground)
                .padding(.horizontal, DesignTokens.EditDesk.Spacing.s12)
                .frame(height: 28)
                .background(Capsule().fill(DesignTokens.EditDesk.Colors.mediaChipFill))
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DesignTokens.EditDesk.Spacing.s12) {
                ModalMetaLine(title: content.title, metaParts: content.metaParts, installed: content.installed)
                    .id(content.itemID)
                    .transition(.opacity)
                Spacer(minLength: 0)
            }
            .animation(navigationAnimation, value: content.itemID)
            .frame(maxHeight: .infinity)
            applyControls
                .padding(.bottom, DesignTokens.EditDesk.Spacing.s12)
            ModalShortcutHint(showsPlayback: actions.togglePlayback != nil)
                .padding(.bottom, DesignTokens.EditDesk.Spacing.s12)
        }
        .padding(.horizontal, Self.barPadding)
        .frame(height: ModalGeometry.bottomBarHeight)
    }

    private var applyControls: some View {
        let split = ModalGeometry.applyButtons(targets: targets)
        return HStack(spacing: 10) {
            ForEach(([split.primary].compactMap(\.self)) + split.secondary) { target in
                Button { actions.applyTo(target.id) } label: {
                    Label(target.name, systemImage: target.isApplied ? "checkmark" : "display")
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.bordered).controlSize(.large)
                .tint(target.isPrimary ? .accentColor : nil)
                .help(Text("Apply to \(target.name)"))
                .accessibilityLabel(Text("Apply to \(target.name)"))
                .accessibilityValue(target.isApplied ? Text("Applied") : Text(""))
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(Self.kindName(content.kind), systemImage: Self.placeholderSymbol(content.kind))
                .font(.subheadline.weight(.medium))
            ForEach(Array(content.metaParts.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, part in
                Text(verbatim: part).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let rating = content.contentRating {
                Text(verbatim: rating).font(.caption).foregroundStyle(.secondary)
            }
            if let date = content.importedAt {
                LabeledContent("Imported") { Text(date, style: .date) }.font(.caption)
            }
            if let installed = content.installed {
                if installed.isWindowsOnly {
                    Label("Windows Only", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if !installed.inUseOnDisplayNames.isEmpty {
                    Label(installed.inUseOnDisplayNames.joined(separator: ", "), systemImage: "display").font(.caption).foregroundStyle(.secondary)
                }
                if case .checking = installed.updateState {
                    ProgressView().controlSize(.small)
                }
                if case let .failed(message) = installed.updateState {
                    Text(verbatim: message).font(.caption).foregroundStyle(.red)
                }
                if case .available = installed.updateState {
                    Label("Needs Update", systemImage: "arrow.down.circle").font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private var communityPresets: some View {
        #if !LITE_BUILD
        if let id = content.workshopID, let doctor,
           let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") {
            DetailPresetsSection(wallpaperID: id, communityURL: url, doctor: doctor)
        }
        #endif
    }

    private var addMenu: some View {
        ModalGlyphMenu(glyph: "＋", label: Text("Add")) {
            if let addToPlaylist = actions.addToPlaylist {
                Menu("Add to Playlist") {
                    ForEach(targets) { target in
                        Button(target.name) { addToPlaylist(target.id) }
                    }
                }
            }
            if let schedule = actions.schedule {
                Button("Add to Schedule", action: schedule)
            }
        }
    }

    private var moreMenu: some View {
        ModalGlyphMenu(glyph: "…", label: Text("More actions")) {
            Menu("Apply to") {
                ForEach(targets) { target in
                    Button(target.name) { actions.applyTo(target.id) }
                }
            }
            Button("All Displays", action: actions.applyToAllDisplays)
            if let showInFinder = actions.showInFinder {
                Button("Show in Finder", action: showInFinder)
            }
            if let openInSteam = actions.openInSteam {
                Button("Open in Steam", action: openInSteam)
            }
            if let removeFromSaved = actions.removeFromSaved {
                Button("Remove from Saved", role: .destructive, action: removeFromSaved)
            }
            updateRow
            if actions.deleteInstalled != nil {
                Button("Delete…", role: .destructive) { confirmingDelete = true }
            }
        }
    }

    @ViewBuilder
    private var updateRow: some View {
        if case .checking = content.installed?.updateState, let cancelUpdate = actions.cancelUpdate {
            Button("Cancel update", action: cancelUpdate)
        } else if let checkForUpdate = actions.checkForUpdate {
            Button("Check for updates", action: checkForUpdate)
        }
    }

    // MARK: Delete confirmation

    @ViewBuilder
    private var deleteConfirmButton: some View {
        if content.installed?.deletesFiles == true {
            Button("Delete & Free Up Space", role: .destructive) { actions.deleteInstalled?() }
        } else {
            Button("Remove from Library Only", role: .destructive) { actions.deleteInstalled?() }
        }
    }

    @ViewBuilder
    private var deleteMessage: some View {
        if content.installed?.deletesFiles == true {
            Text(
                "Delete “\(content.title)” from this Mac’s Steam library and Loomscreen to free space. This cannot be undone; the wallpaper can be downloaded again. Steam subscriptions are unchanged."
            )
        } else {
            Text("Remove “\(content.title)” from Loomscreen. Original files are kept.")
        }
    }

    // MARK: Keyboard

    /// ESC and ⌘n belong to the chrome; these are the keys only the library modal answers. They
    /// ride zero-sized buttons rather than `onKeyPress`: the stage's `NSView` is usually first
    /// responder and swallows `keyDown` while the modal blocks it.
    private var shortcuts: some View {
        ZStack {
            if navigation.canGoPrevious {
                Button { navigate(forward: false) } label: { EmptyView() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            if navigation.canGoNext {
                Button { navigate(forward: true) } label: { EmptyView() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            if let togglePlayback = actions.togglePlayback {
                Button(action: togglePlayback) { EmptyView() }
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func applyToShortcut(_ index: Int) {
        guard let target = ModalKeyMap.target(forShortcut: index, in: targets) else { return }
        actions.applyTo(target.id)
    }

    /// True when ESC went to the drag instead of the modal.
    private func cancelDragForEscape() -> Bool {
        guard dragState == .active else { return false }
        dragState = .cancelled
        onDrag(.cancelled)
        return true
    }

    private func navigate(forward: Bool) {
        isNavigatingForward = forward
        if forward {
            navigation.next()
        } else {
            navigation.previous()
        }
    }

    // MARK: Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(EditDeskCoordinateSpace.name))
            .onChanged { value in
                switch dragState {
                case .idle:
                    dragState = .active
                    onDrag(.began(value.location))
                case .active:
                    onDrag(.moved(value.location))
                case .cancelled:
                    break
                }
            }
            .onEnded { value in
                if dragState == .active {
                    onDrag(.ended(value.location))
                }
                dragState = .idle
            }
    }

    // MARK: Motion

    private var navigationAnimation: Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeOut(duration: 0.25)
    }

    /// MOTION 6: the incoming preview enters from the side the navigation is heading.
    private var previewTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        let travel: CGFloat = isNavigatingForward ? 24 : -24
        return .asymmetric(
            insertion: .offset(x: travel).combined(with: .opacity),
            removal: .offset(x: -travel).combined(with: .opacity)
        )
    }

    // MARK: Kind

    private static func kindName(_ kind: LibraryItem.Kind) -> String {
        switch kind {
        case .video: String(localized: "Video", bundle: .appLanguage)
        case .web: String(localized: "Web", bundle: .appLanguage)
        case .scene: String(localized: "Scene", bundle: .appLanguage)
        case .aerial: String(localized: "Aerial", bundle: .appLanguage)
        }
    }

    private static func placeholderSymbol(_ kind: LibraryItem.Kind) -> String {
        switch kind {
        case .video: "play.rectangle"
        case .web: "globe"
        case .scene: "cube.transparent"
        case .aerial: "sparkles"
        }
    }
}

/// SCREENS.md S4's bottom-bar button skin: a flat token fill, so hover and press have to be drawn
/// here rather than inherited from a system style.
/// SCREENS.md S4 gives every bottom-bar control the same 38pt height.
private let modalButtonHeight: CGFloat = 38

private struct ModalBarButton<Label: View>: View {
    let fill: Color
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(height: modalButtonHeight)
                .background(shape.fill(fill))
                .overlay(
                    shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(shape)
        }
        .buttonStyle(ModalPressStyle())
        .onHover { isHovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.button, style: .continuous)
    }
}

/// The 38×38 glyph menus ("＋" and "…") at the end of the bottom bar.
private struct ModalGlyphMenu<Content: View>: View {
    let glyph: String
    let label: Text
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            Text(verbatim: glyph)
                .font(DesignTokens.EditDesk.Typography.button)
                .frame(width: modalButtonHeight, height: modalButtonHeight)
                .background(shape.fill(DesignTokens.EditDesk.Colors.fillTertiaryButton))
                .overlay(
                    shape.strokeBorder(DesignTokens.EditDesk.Colors.strokeRegular, lineWidth: 1)
                        .opacity(isHovering ? 1 : 0)
                )
                .contentShape(shape)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
        .frame(width: modalButtonHeight, height: modalButtonHeight)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.button, style: .continuous)
    }
}

private struct ModalPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? DesignTokens.Opacity.dimmedIcon : 1)
    }
}

private extension View {
    /// `pointerStyle` needs macOS 15; on 14 the preview keeps the arrow cursor.
    @ViewBuilder
    func grabCursor(_ enabled: Bool) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(enabled ? .grabIdle : nil)
        } else {
            self
        }
    }
}
