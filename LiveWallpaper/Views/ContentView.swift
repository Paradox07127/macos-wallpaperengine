import SwiftUI
import AppKit
import LiveWallpaperCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedNavigation: Navigation?
    @State private var isSettingsMode: Bool
    @State private var selectedSettingsNavigation: SettingsNavigation?
    @State private var settingsSearchText = ""
    @State private var pendingSettingsSearchAnchor: SettingsSearchAnchor?
    @State private var lastAppNavigation: Navigation?
    @State private var didConsumeInitialAddWallpaperPrompt = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var isReloading = false
    private let initialAddWallpaperPromptKind: String?

    init(initialNavigation: Navigation? = nil, initialAddWallpaperPromptKind: String? = nil) {
        let startsInSettings = initialNavigation == .general
        _selectedNavigation = State(initialValue: startsInSettings ? nil : initialNavigation)
        _isSettingsMode = State(initialValue: startsInSettings)
        _selectedSettingsNavigation = State(initialValue: startsInSettings ? .general : nil)
        _lastAppNavigation = State(initialValue: startsInSettings ? nil : initialNavigation)
        self.initialAddWallpaperPromptKind = initialAddWallpaperPromptKind
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            if isSettingsMode {
                SettingsDetailContent(
                    selection: $selectedSettingsNavigation,
                    pendingSearchAnchor: $pendingSettingsSearchAnchor
                )
            } else {
                DetailContent(selection: $selectedNavigation)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .providesGalleryCardPreferences()
        .toolbar { toolbarContent }
        .frame(
            minWidth: SettingsWindowMetrics.minimumContentSize.width,
            minHeight: SettingsWindowMetrics.minimumContentSize.height
        )
        .onReceive(NotificationCenter.default.publisher(for: .openGeneralSettings)) { _ in
            scheduleNavigationChange { enterSettingsMode(.general) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsSection)) { notification in
            guard let raw = notification.userInfo?["destination"] as? String,
                  let destination = SettingsNavigation(rawValue: raw) else { return }
            let anchor = (notification.userInfo?["anchor"] as? String)
                .flatMap(SettingsSearchAnchor.init(rawValue:))
            scheduleNavigationChange {
                enterSettingsMode(destination)
                pendingSettingsSearchAnchor = anchor
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWorkshopPane)) { _ in
            scheduleNavigationChange { selectAppNavigation(.workshop) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAppleAerials)) { _ in
            scheduleNavigationChange { selectAppNavigation(.appleAerials) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .screensRefreshed)) { _ in
            scheduleDefaultDisplaySelection()
        }
        .onAppear {
            scheduleDefaultDisplaySelection()
            consumeInitialAddWallpaperPromptIfNeeded()
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        Group {
            if isSettingsMode {
                SettingsSidebar(
                    selection: $selectedSettingsNavigation,
                    searchText: $settingsSearchText,
                    pendingSearchAnchor: $pendingSettingsSearchAnchor,
                    onBack: exitSettingsMode
                )
            } else {
                Sidebar(selection: $selectedNavigation)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectScreenInSettings)) { notification in
            guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID else { return }
            scheduleNavigationChange { selectAppNavigation(.screen(screenID)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .promptAddWallpaper)) { notification in
            handleAddWallpaperPrompt(notification: notification)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if !isSettingsMode {
            ToolbarItem(placement: .navigation) {
                Button {
                    scheduleNavigationChange { enterSettingsMode(.general) }
                } label: {
                    Image(systemName: "gearshape")
                }
                .help(Text(L10n.Toolbar.preferences))
                .accessibilityLabel(Text(L10n.Toolbar.preferences))
                .accessibilityHint(Text("Open application preferences"))
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: { handleAddWallpaperPrompt(kind: "any") }) {
                    Image(systemName: "plus")
                }
                .help(Text(L10n.Toolbar.addWallpaper))
                .accessibilityLabel(Text(L10n.Toolbar.addWallpaper))
                .accessibilityHint(Text("Pick a video, web page, or scene for the selected display"))
                .disabled(screenManager.screens.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: invokeReload) {
                    if #available(macOS 15.0, *) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, options: .continuouslyRepeating, isActive: isReloading)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.pulse, options: .continuouslyRepeating, isActive: isReloading)
                    }
                }
                .help(Text("Reload display content"))
                .accessibilityLabel(Text("Reload display"))
                .accessibilityHint(Text("Reloads the wallpaper content for this screen"))
                .disabled(screenManager.screens.isEmpty)
            }
        }
    }

    private func scheduleDefaultDisplaySelection() {
        DispatchQueue.main.async {
            Task { @MainActor in
                selectDefaultDisplayIfNeeded()
            }
        }
    }

    /// Defer navigation mutations off the current SwiftUI update pass.
    private func scheduleNavigationChange(_ apply: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            apply()
        }
    }

    private func enterSettingsMode(_ destination: SettingsNavigation) {
        if !isSettingsMode {
            lastAppNavigation = selectedNavigation
        }
        isSettingsMode = true
        selectedSettingsNavigation = destination
        settingsSearchText = ""
    }

    private func exitSettingsMode() {
        isSettingsMode = false
        if selectedNavigation == nil {
            selectedNavigation = lastAppNavigation
        }
        scheduleDefaultDisplaySelection()
    }

    private func selectAppNavigation(_ navigation: Navigation?) {
        isSettingsMode = false
        selectedNavigation = navigation
        lastAppNavigation = navigation
    }

    private func selectDefaultDisplayIfNeeded() {
        guard !isSettingsMode else { return }
        guard screenManager.screens.count == 1, let screen = screenManager.screens.first else { return }

        switch selectedNavigation {
        case nil:
            selectedNavigation = .screen(screen.id)
        case .screen(let selectedID) where selectedID != screen.id:
            selectedNavigation = .screen(screen.id)
        default:
            break
        }
    }

    private func handleAddWallpaperPrompt(notification: Notification) {
        guard let kind = notification.userInfo?["kind"] as? String else { return }
        handleAddWallpaperPrompt(kind: kind)
    }

    private func consumeInitialAddWallpaperPromptIfNeeded() {
        guard !didConsumeInitialAddWallpaperPrompt,
              let kind = initialAddWallpaperPromptKind else { return }
        didConsumeInitialAddWallpaperPrompt = true
        handleAddWallpaperPrompt(kind: kind)
    }

    private func handleAddWallpaperPrompt(kind: String) {
        guard let target = toolbarTargetScreen() else { return }
        selectAppNavigation(.screen(target.id))

        switch kind {
        case "any":
            promptAnyWallpaperSource(for: target)
        case "video":
            promptVideoFile(for: target)
        case "html-file":
            promptHTMLFile(for: target)
        case "html-folder":
            promptHTMLFolder(for: target)
        default:
            break
        }
    }

    /// One picker for every wallpaper kind, routed by what the file actually is
    /// — the same classifier the drop target and onboarding use. Replaces the
    /// per-page import buttons that each opened their own narrower panel.
    private func promptAnyWallpaperSource(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        panel.message = String(
            localized: "Choose a video, a web page or folder, or a Wallpaper Engine project folder.",
            comment: "Message for the unified add-wallpaper picker."
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        applyImportRoute(for: url, to: screen)
    }

    private func applyImportRoute(for url: URL, to screen: Screen) {
        switch WallpaperImportRouter.route(url, sceneCapable: sceneCapable) {
        case .video(let videoURL):
            guard let bookmark = ResourceUtilities.createVideoBookmark(for: videoURL) else {
                reportImportFailure(
                    url: videoURL,
                    message: String(
                        localized: "macOS didn't grant access to that file. Try one in a folder you own.",
                        comment: "Add-wallpaper failure when a security-scoped bookmark can't be made."
                    )
                )
                return
            }
            screenManager.setVideo(url: videoURL, bookmarkData: bookmark, for: screen)
        case .html(let source):
            screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
        case .sceneProject(let folderURL):
            #if !LITE_BUILD
            Task { @MainActor in
                await screenManager.importWallpaperEngineProject(at: folderURL, for: screen)
            }
            #endif
        case .sceneLibrary(let folderURL):
            #if !LITE_BUILD
            // A library root has no single wallpaper to apply — it populates the
            // Workshop library, which is what the folder button there did.
            WorkshopFolderImportCoordinator.shared.importProjects(from: folderURL)
            selectAppNavigation(.workshop)
            #endif
        case .unsupported:
            reportImportFailure(
                url: url,
                message: String(
                    localized: "Choose a video, a web page or folder, or a Wallpaper Engine project folder.",
                    comment: "Message for the unified add-wallpaper picker."
                )
            )
        }
    }

    /// The picker is already dismissed by the time we know, so a beep would be
    /// the user's only feedback that nothing happened.
    private func reportImportFailure(url: URL, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "Can't use \(url.lastPathComponent)",
            comment: "Add-wallpaper failure alert title. The placeholder is the chosen file name."
        )
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK", comment: "Dismiss button on the add-wallpaper failure alert."))
        alert.runModal()
    }

    private var sceneCapable: Bool { featureCatalog.isEnabled(.scene) }

    /// Symbol effect is click feedback only — `reloadAllScreens()` is fire-and-forget.
    private func invokeReload() {
        guard !isReloading, let target = toolbarTargetScreen() else { return }
        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
            isReloading = true
        }
        screenManager.reloadWallpaperForScreen(target)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.2))) {
                isReloading = false
            }
        }
    }

    /// The display the toolbar acts on: the selected one, else the first.
    private func toolbarTargetScreen() -> Screen? {
        if case .screen(let id) = selectedNavigation,
           let match = screenManager.screens.first(where: { $0.id == id }) {
            return match
        }
        return screenManager.screens.first
    }

    private func promptVideoFile(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedVideoContentTypes
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = ResourceUtilities.createVideoBookmark(for: url) else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        screenManager.setVideo(url: url, bookmarkData: bookmark, for: screen)
    }

    private func promptHTMLFile(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ResourceUtilities.supportedHTMLContentTypes
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url,
              let source = ResourceUtilities.htmlSourceFromPickedFile(url) else { return }
        screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
    }

    private func promptHTMLFolder(for screen: Screen) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let folderURL = panel.url,
              let bookmark = ResourceUtilities.createBookmark(for: folderURL) else { return }
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? []
        let indexFileName = ResourceUtilities.inferHTMLIndexFileName(from: entries)
        screenManager.setHTMLWallpaperPreservingConfig(
            source: .folder(bookmarkData: bookmark, indexFileName: indexFileName),
            for: screen
        )
    }
}

// MARK: - Navigation

enum Navigation: Hashable {
    case general
    case screen(CGDirectDisplayID)
    case appleAerials
    case bookmarks
    case workshop
    case systemWallpaper
}

// MARK: - Sidebar View
struct Sidebar: View {
    @Binding var selection: Navigation?
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @AppStorage(SidebarDisplayOrder.preferencesKey) private var displayOrderData = Data()

    var body: some View {
        List(selection: $selection) {
            Section {
                if screenManager.screens.isEmpty {
                    HStack {
                        Image(systemName: "display.slash")
                            .foregroundStyle(.secondary)
                        Text("No displays detected")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                } else {
                    ForEach(orderedScreens, id: \.id) { screen in
                        NavigationLink(value: Navigation.screen(screen.id)) {
                            ScreenRow(screen: screen)
                        }
                        .dropDestination(for: URL.self) { urls, _ in
                            return handleVideoDrop(urls: urls, for: screen)
                        }
                    }
                    .onMove(perform: moveDisplays)
                }
            } header: {
                SidebarSectionHeader(title: "Displays")
            }

            Section {
                NavigationLink(value: Navigation.bookmarks) {
                    Label("Bookmarks", systemImage: "bookmark.fill")
                }
                NavigationLink(value: Navigation.appleAerials) {
                    Label("Apple Aerials", systemImage: "sparkles.tv")
                }
                #if !LITE_BUILD
                if featureCatalog.isEnabled(.wpeImport) {
                    NavigationLink(value: Navigation.workshop) {
                        Label("Steam Workshop", systemImage: "cube.transparent.fill")
                    }
                    .accessibilityLabel(Text("Steam Workshop"))
                    .accessibilityHint(Text("Browse installed and online Workshop wallpapers"))
                }
                #endif
                if #available(macOS 26.0, *) {
                    NavigationLink(value: Navigation.systemWallpaper) {
                        Label("System Wallpaper", systemImage: "macwindow.on.rectangle")
                    }
                    .accessibilityHint(Text("Hand videos to macOS so they play without Loomscreen running"))
                }
            } header: {
                SidebarSectionHeader(title: "Library")
            }

        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if featureCatalog.isEnabled(.systemMonitor) {
                VStack(spacing: 0) {
                    SystemMonitorPill(
                        activeDisplayCount: activeWallpaperDisplayCount,
                        totalDisplayCount: screenManager.screens.count
                    )
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .padding(.vertical, DesignTokens.Spacing.sm)
                }
            }
        }
        .navigationSplitViewColumnWidth(
            min: SettingsWindowMetrics.sidebarColumnWidth,
            ideal: SettingsWindowMetrics.sidebarColumnWidth,
            max: SettingsWindowMetrics.sidebarColumnMaxWidth
        )
    }

    /// Via `wallpaperSummary` so Usage chip tracks the same observation channel as `ScreenRow`.
    private var activeWallpaperDisplayCount: Int {
        screenManager.screens.reduce(0) { acc, screen in
            acc + (screenManager.wallpaperSummary(for: screen).activity == .active ? 1 : 0)
        }
    }

    private var orderedScreens: [Screen] {
        let screens = screenManager.screens
        let order = SidebarDisplayOrder.decode(displayOrderData)
        let orderedIDs = SidebarDisplayOrder.orderedDisplayIDs(
            from: screens.map(SidebarDisplayOrder.Entry.init(screen:)),
            storedOrder: order
        )
        let screensByID = Dictionary(uniqueKeysWithValues: screens.map { ($0.id, $0) })
        return orderedIDs.compactMap { screensByID[$0] }
    }

    private func moveDisplays(from source: IndexSet, to destination: Int) {
        var reorderedScreens = orderedScreens
        reorderedScreens.move(fromOffsets: source, toOffset: destination)
        displayOrderData = SidebarDisplayOrder.encode(
            reorderedScreens.map(SidebarDisplayOrder.Entry.init(screen:))
        )
    }

    /// First supported video URL (Finder sometimes puts sidecar files first).
    private func handleVideoDrop(urls: [URL], for screen: Screen) -> Bool {
        guard let videoURL = urls.first(where: ResourceUtilities.isSupportedVideoURL) else { return false }
        guard let bookmarkData = ResourceUtilities.createVideoBookmark(for: videoURL) else { return false }
        screenManager.setVideo(url: videoURL, bookmarkData: bookmarkData, for: screen)
        return true
    }
}

struct SidebarSectionHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.caption)
            .bold()
            .foregroundStyle(.secondary)
            .padding(.top, DesignTokens.Sidebar.sectionHeaderTopPadding)
            .padding(.bottom, DesignTokens.Sidebar.sectionHeaderBottomPadding)
    }
}

// MARK: - Display rename

/// Right-click rename for a display. Shared by the sidebar row and the Settings
/// arrangement map so both offer the same two actions.
struct ScreenRenameMenu: ViewModifier {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @State private var isRenaming = false
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Rename…") {
                    draft = screen.name
                    isRenaming = true
                }
                if screen.customName != nil {
                    Button("Use System Name") {
                        screenManager.setCustomName(nil, for: screen)
                    }
                }
            }
            .alert("Rename Display", isPresented: $isRenaming) {
                TextField("Display name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { screenManager.setCustomName(draft, for: screen) }
            }
    }
}

extension View {
    func screenRenameMenu(for screen: Screen) -> some View {
        modifier(ScreenRenameMenu(screen: screen))
    }
}

// MARK: - Screen Row
struct ScreenRow: View {
    var screen: Screen
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        let summary = screenManager.wallpaperSummary(for: screen)

        HStack(spacing: 8) {
            Image(systemName: iconName(for: summary))
                .foregroundStyle(iconColor(for: summary))
                .frame(width: 22, height: 22)

            Text(verbatim: screen.name)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: screen.name))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .screenRenameMenu(for: screen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayAccessibilityLabel)
        .accessibilityValue(accessibilityValue(for: summary))
        .accessibilityHint(Text("Select to configure this display"))
    }

    private var displayAccessibilityLabel: Text {
        Text(
            "\(screen.name), \(Int(screen.frame.width)) by \(Int(screen.frame.height)) pixels",
            comment: "Sidebar row VoiceOver label combining display name and resolution. First placeholder is the display name, second and third are width and height in pixels."
        )
    }

    private func iconName(for summary: WallpaperSessionSummary) -> String {
        switch summary.wallpaperType {
        case .video:
            return summary.isConfigured ? "display.and.arrow.down" : "display"
        case .html:
            return "globe"
        case .scene:
            return "cube.transparent"
        case nil:
            return "display"
        }
    }

    private func iconColor(for summary: WallpaperSessionSummary) -> Color {
        switch summary.activity {
        case .active:   return DesignTokens.Colors.Status.active
        case .paused, .policySuspended: return DesignTokens.Colors.Status.warning
        case .restoring: return DesignTokens.Colors.Status.active
        case .error:    return DesignTokens.Colors.Status.danger
        case .off:      return .secondary
        case .inactive: return .secondary
        }
    }

    private func accessibilityValue(for summary: WallpaperSessionSummary) -> Text {
        switch summary.wallpaperType {
        case .html:
            return Text("Web wallpaper active")
        case .video:
            return summary.activity == .active || summary.activity == .restoring
                ? Text("Wallpaper playing")
                : Text("Wallpaper paused")
        case .scene:
            return Text("Scene wallpaper")
        case nil:
            return Text("No wallpaper configured")
        }
    }
}

// MARK: - Detail Content
struct DetailContent: View {
    @Binding var selection: Navigation?
    @Environment(ScreenManager.self) private var screenManager

    var body: some View {
        Group {
            switch selection {
            // `.general` never reaches here — it is the "open settings" signal and
            // flips `isSettingsMode`, which routes to `SettingsDetailContent` instead.
            case .general:
                EmptyView()

            case .screen(let screenId):
                if let screen = screenManager.screens.first(where: { $0.id == screenId }) {
                    DetailView(screen: screen)
                } else {
                    EmptyStateView(
                        icon: "display.trianglebadge.exclamationmark",
                        message: "The selected display is no longer available."
                    )
                }

            case .appleAerials:
                AerialsLibraryView()

            case .bookmarks:
                LibraryView()

            case .workshop:
                #if !LITE_BUILD
                PaneView()
                #else
                EmptyView()
                #endif

            case .systemWallpaper:
                if #available(macOS 26.0, *) {
                    SystemWallpaperLibraryView()
                } else {
                    EmptyStateView(
                        icon: "macwindow.on.rectangle",
                        message: "System Wallpaper requires macOS 26 or later."
                    )
                }

            case .none:
                EmptyStateView(
                    icon: "display",
                    message: "Choose a display from the sidebar to configure your live wallpaper."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.tertiary)
                .symbolRenderingMode(.hierarchical)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
