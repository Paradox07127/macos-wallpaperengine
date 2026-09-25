import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// The library's wallpaper modal, drawn as an overlay inside `HomePage`'s ZStack rather than a
/// sheet, because the display float layer has to stay reachable above it. Values arrive through
/// `WallpaperModalContract`; this view draws them in `WallpaperDetailLayout` and hands events back out.
@MainActor
struct WallpaperModal: View {
    let content: WallpaperModalContent
    let targets: [ModalDisplayTarget]
    let actions: WallpaperModalActions
    /// Open the home page's rename alert and delete confirmation for the shown item. Not presented here:
    /// ← → keep paging under a dialog, so one owned by the modal would act on whatever it shows by then.
    let requestRename: @MainActor () -> Void
    let requestDelete: @MainActor () -> Void
    let navigation: ModalNavigation
    /// The stage's own `bounds.size`. A `GeometryReader` here would measure one title bar short.
    let windowSize: CGSize
    /// Height the scrim leaves untouched so the traffic lights and window drag still work.
    let titlebarInset: CGFloat
    let onDismiss: () -> Void
    let onDrag: (ModalDragPhase) -> Void
    #if !LITE_BUILD
    /// The installed Workshop item's transfer or pending update; nil draws no status line.
    var downloadStatus: WorkshopDownloadPresentation?
    #endif

    /// A drag ESC cancelled must not restart on the next `onChanged`: the gesture keeps reporting
    /// until the mouse comes up.
    private enum DragState: Equatable { case idle, active, cancelled }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragState: DragState = .idle
    @State private var isNavigatingForward = true
    #if !LITE_BUILD
    @Environment(\.openURL) private var openURL
    @Environment(SteamCMDDoctorService.self) private var doctor: SteamCMDDoctorService?
    @State private var descriptionExpanded = false
    #endif

    var body: some View {
        EditDeskModalChrome(
            windowSize: windowSize,
            titlebarInset: titlebarInset,
            title: content.title,
            actions: actions.headerActions(isUpdating: isUpdating, requestRename: requestRename, requestDelete: requestDelete),
            onDismiss: onDismiss,
            onEscape: cancelDragForEscape,
            onTargetShortcut: applyToShortcut
        ) { _ in
            panelBody
                .id(content.itemID)
        }
    }

    // MARK: Panel

    private var panelBody: some View {
        WallpaperDetailLayout(
            facts: content.facts,
            tags: content.tags,
            onPrevious: navigation.canGoPrevious ? { navigate(forward: false) } : nil,
            onNext: navigation.canGoNext ? { navigate(forward: true) } : nil,
            preview: { previewArea },
            sidebar: { sidebar },
            status: { status },
            buttons: {
                ModalDisplayButtons(
                    targets: targets, canApply: content.canApply,
                    applyTo: actions.applyTo, applyToAll: actions.applyToAllDisplays
                )
            }
        )
        .overlay { shortcuts }
    }

    // MARK: Preview

    private var previewShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DesignTokens.EditDesk.Corner.panelLarge, style: .continuous)
    }

    /// The whole picture fitted into the layout's 4:3 box, square or wide, on a sunken fill.
    private var previewArea: some View {
        ZStack {
            DesignTokens.Colors.surfaceSunken
            previewImage
                .id(content.itemID)
                .transition(previewTransition)
        }
        .clipShape(previewShape)
        .animation(navigationAnimation, value: content.itemID)
        .overlay(previewShape.strokeBorder(DesignTokens.EditDesk.Colors.strokeBadge, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            mediaChip(Text("Still preview", comment: "Wallpaper modal chip over a preview that is a still frame, not the moving wallpaper."))
                .padding(DesignTokens.EditDesk.Spacing.s8)
        }
        // MOTION 7 asks for .3 under the ghost; `quietStroke` is the nearest step in the scale.
        .opacity(dragState == .active ? DesignTokens.Opacity.quietStroke : 1)
        .accessibilityLabel(Text(verbatim: "\(content.title), \(content.kind.localizedName)"))
        .gesture(dragGesture, including: content.canApply ? .all : .subviews)
        .grabCursor(content.canApply)
    }

    @ViewBuilder
    private var previewImage: some View {
        if let image = content.preview {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: Self.placeholderSymbol(content.kind))
                .font(DesignTokens.EditDesk.Typography.modalTitle)
                .foregroundStyle(DesignTokens.EditDesk.Colors.textTertiary)
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

    // MARK: Right column

    /// Notices first, then the description, the required items, the presets and the Steam links; an
    /// item without a Workshop page says where its file lives instead.
    @ViewBuilder
    private var sidebar: some View {
        #if !LITE_BUILD
        if let origin = content.unsupportedOrigin {
            UnsupportedProjectNotice(origin: origin, showsIdentity: true)
        }
        #endif
        if let notice = content.notice {
            InlineNoticeBanner(
                tint: content.canApply ? DesignTokens.Colors.Status.warning : DesignTokens.Colors.Status.danger,
                symbol: "exclamationmark.triangle",
                title: Text(verbatim: notice)
            )
        }
        if content.isUnavailableOnSteam {
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.danger,
                symbol: "xmark.octagon.fill",
                title: Text("Unavailable — removed or hidden on Steam")
            )
        }
        #if !LITE_BUILD
        if let text = content.descriptionText {
            WallpaperDetailSection(title: Text("Description")) {
                CollapsibleDescription(
                    text: text.isEmpty
                        ? String(localized: "No description provided.", bundle: .appLanguage, comment: "Placeholder when a Workshop item has no description.")
                        : text,
                    isExpanded: $descriptionExpanded,
                    collapsedLineLimit: 4
                )
            }
        }
        if !requiredItemIDs.isEmpty {
            DetailRequiredItemsSection(itemIDs: requiredItemIDs, onOpenItem: { openURL(WorkshopCommunityURL.item(itemID: $0)) })
        }
        if let id = content.workshopID, let doctor {
            DetailPresetsSection(wallpaperID: id, communityURL: WorkshopCommunityURL.item(itemID: id), doctor: doctor)
            communityLinks(id)
        }
        #endif
        if !content.fileFacts.isEmpty {
            WallpaperDetailSection(title: Text("File", comment: "Wallpaper detail section: where the wallpaper's file or page lives.")) {
                WallpaperFactGrid(facts: content.fileFacts)
            }
        }
    }

    #if !LITE_BUILD
    /// The unsupported-project notice already lists the missing ones, so the section would repeat them.
    private var requiredItemIDs: [UInt64] {
        guard content.unsupportedOrigin?.missingDependencyIDs.isEmpty ?? true else { return [] }
        return content.dependencyIDs.compactMap(UInt64.init)
    }

    private func communityLinks(_ id: UInt64) -> some View {
        WorkshopChipFlow(spacing: DesignTokens.Spacing.md, lineSpacing: DesignTokens.Spacing.xs) {
            communityLink(Text("Comments"), systemImage: "bubble.left", url: WorkshopCommunityURL.comments(itemID: id))
            communityLink(Text("Change Notes"), systemImage: "clock.arrow.circlepath", url: WorkshopCommunityURL.changeNotes(itemID: id))
            communityLink(Text("Collections"), systemImage: "square.stack", url: WorkshopCommunityURL.collections(itemID: id))
        }
        .font(DesignTokens.Typography.caption)
    }

    private func communityLink(_ title: Text, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label { title } icon: { Image(systemName: systemImage) }
        }
        .buttonStyle(.link)
        .fixedSize()
    }
    #endif

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        #if !LITE_BUILD
        if let downloadStatus {
            ModalDownloadStatusLine(presentation: downloadStatus)
        }
        #endif
    }

    private var isUpdating: Bool {
        if case .checking = content.installed?.updateState {
            return true
        }
        return false
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
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func applyToShortcut(_ index: Int) {
        guard content.canApply, let target = ModalKeyMap.target(forShortcut: index, in: targets) else { return }
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

    private static func placeholderSymbol(_ kind: LibraryItem.Kind) -> String {
        switch kind {
        case .video: "play.rectangle"
        case .web: "globe"
        case .scene: "cube.transparent"
        case .aerial: "sparkles"
        }
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

/// Draws `StageMenuItem` rows as SwiftUI menu content: the library grid's and shelf's context menus.
struct WallpaperMenuRows: View {
    let items: [StageMenuItem]

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if item.submenu.isEmpty {
                Button(item.title, role: item.isDestructive ? .destructive : nil, action: item.action)
                    .disabled(!item.isEnabled)
            } else {
                Menu(item.title) {
                    WallpaperMenuRows(items: item.submenu)
                }
                .disabled(!item.isEnabled)
            }
        }
    }
}

extension View {
    /// Confirms deleting an installed Workshop wallpaper; `itemID` is the entry it is open for, nil closes it.
    func wallpaperDeleteConfirmation(
        itemID: Binding<String?>, title: String, deletesFiles: Bool, delete: @escaping @MainActor (String) -> Void
    ) -> some View {
        confirmationDialog(
            Text("Delete this wallpaper?"),
            isPresented: Self.isPresented(itemID),
            titleVisibility: .visible,
            presenting: itemID.wrappedValue
        ) { id in
            if deletesFiles {
                Button("Delete & Free Up Space", role: .destructive) { delete(id) }
            } else {
                Button("Remove from Library Only", role: .destructive) { delete(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            if deletesFiles {
                Text(
                    "Delete “\(title)” from this Mac’s Steam library and Loomscreen to free space. This cannot be undone; the wallpaper can be downloaded again. Steam subscriptions are unchanged."
                )
            } else {
                Text("Remove “\(title)” from Loomscreen. Original files are kept.")
            }
        }
    }

    /// Renames a saved Wallpaper Library entry; `itemID` is the entry it is open for, nil closes it.
    func wallpaperRenameAlert(
        itemID: Binding<String?>, name: Binding<String>, rename: @escaping @MainActor (String) -> Void
    ) -> some View {
        alert(
            Text("Rename Wallpaper"),
            isPresented: Self.isPresented(itemID),
            presenting: itemID.wrappedValue
        ) { id in
            TextField("Wallpaper name", text: name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { rename(id) }
        }
    }

    /// True while `itemID` holds an entry; dismissing clears it.
    private static func isPresented(_ itemID: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { itemID.wrappedValue != nil },
            set: { presented in
                if !presented {
                    itemID.wrappedValue = nil
                }
            }
        )
    }
}
