#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

@MainActor
struct SceneSection: View {
    let screen: Screen
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Quick-apply grid cap; full library lives in the Workshop tab.
    private let recentGridCap = 18

    @State private var recentImports: [WPEHistoryEntry] = []
    @State private var selectedHistoryEntry: WPEHistoryEntry?
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        Group {
            if hasActiveSceneWallpaper {
                activeSceneCard
            } else if recentImports.isEmpty {
                emptyState
            } else if let selected = selectedHistoryEntry {
                unsupportedDetail(for: selected)
            } else {
                historyList
            }
        }
        .animation(reduceMotion ? nil : .default, value: recentImports.isEmpty)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task { @MainActor in reloadHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeImportDidComplete)) { notification in
            Task { @MainActor in
                reloadHistory()
                selectUnsupportedImportIfNeeded(from: notification)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            Task { @MainActor in reloadHistory() }
        }
        .confirmDestructive($pendingDestructive)
        .errorAlert(
            "Apply Failed",
            error: Binding<AppError?>(
                get: { screenManager.wpeImportTracker.error(for: screen.id) },
                set: { if $0 == nil { screenManager.wpeImportTracker.clearError(for: screen.id) } }
            )
        )
    }

    // MARK: - States

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 8) {
                Text("Apply Local Project")
                    .font(.title2.bold())
                Text("Choose a project folder to link and apply")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                Button {
                    presentFolderPicker()
                } label: {
                    Label("Apply Project Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint(Text("Opens a folder chooser to link and apply a local project in place"))

                if featureCatalog.isEnabled(.wpeImport) {
                    browseWorkshopButton("Browse all in Workshop")
                } else {
                    workshopHintText
                }
            }
            .padding(.top, 4)

            Text("Supports Video / Web · Scene support varies")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var historyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Recent Linked Projects")
                        .font(DesignTokens.Typography.sectionTitle)
                    Spacer()
                    if featureCatalog.isEnabled(.wpeImport) {
                        browseWorkshopButton("Browse all in Workshop")
                    }
                    Button {
                        presentFolderPicker()
                    } label: {
                        Label("Apply Project…", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    ForEach(recentImports.prefix(recentGridCap)) { entry in
                        HistoryRow(
                            entry: entry,
                            isActive: activeWorkshopID == entry.id,
                            onTap: { handleTap(entry: entry) },
                            onRemove: { handleRemove(entry: entry) }
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func unsupportedDetail(for entry: WPEHistoryEntry) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Button {
                        selectedHistoryEntry = nil
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .help(Text("Back to library"))
                    .accessibilityLabel(Text("Back to library"))
                    .accessibilityHint(Text("Return to the recent linked projects grid"))
                    Spacer()
                }
                FallbackCard(
                    origin: entry.origin,
                    reason: FallbackCard.reason(for: entry.origin)
                )
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    /// Only the scene-rendering flavour: bookmark and playback failures reach
    /// the same banner but have nothing to do with engine assets.
    private var isSceneRenderingFailure: Bool {
        if case .sceneRenderingFailed = screenManager.runtimeError(for: screen) {
            return true
        }
        return false
    }

    private var hasActiveSceneWallpaper: Bool {
        guard let configuration = screenManager.getConfiguration(for: screen),
              case .scene = configuration.activeWallpaper,
              configuration.wpeOrigin != nil else { return false }
        return true
    }

    @ViewBuilder
    private var activeSceneCard: some View {
        if let configuration = screenManager.getConfiguration(for: screen),
           case .scene(let descriptor) = configuration.activeWallpaper,
           let origin = configuration.wpeOrigin {
            let session = screen.runtimeSession as? SceneWallpaperSession
            // Chrome-free, and NOT scrolled: like the video preview area the 16:9 hero must stay height-bounded by the viewport, otherwise a wide window grows it unboundedly tall and introduces vertical scroll.
            SceneDetailView(
                origin: origin,
                descriptor: descriptor,
                session: session,
                hasSceneRenderingError: isSceneRenderingFailure
            )
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyView()
        }
    }

    private var workshopHintText: some View {
        Text("Browse and manage your whole library in the Steam Workshop tab.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func browseWorkshopButton(_ title: LocalizedStringKey) -> some View {
        Button {
            NotificationCenter.default.post(name: .openWorkshopPane, object: nil)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right")
                    .imageScale(.small)
            }
            .font(DesignTokens.Typography.body)
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens the Steam Workshop tab to browse and manage your full library"))
    }

    // MARK: - Actions

    private var activeWorkshopID: String? {
        screenManager.getConfiguration(for: screen)?.wpeOrigin?.workshopID
    }

    private func reloadHistory() {
        recentImports = SettingsManager.shared.loadGlobalSettings().recentWPEImports
    }

    /// Auto-promote unsupported import for THIS screen into the placeholder card.
    private func selectUnsupportedImportIfNeeded(from notification: Notification) {
        guard let screenID = notification.userInfo?["screenID"] as? CGDirectDisplayID,
              screenID == screen.id,
              let rawType = notification.userInfo?["type"] as? String,
              let type = WPEType(rawValue: rawType) else { return }

        let workshopID = notification.userInfo?["workshopID"] as? String

        DispatchQueue.main.async {
            let entry: WPEHistoryEntry?
            if let workshopID {
                entry = recentImports.first { $0.origin.workshopID == workshopID }
            } else {
                entry = recentImports.first { $0.origin.originalType == type }
            }
            guard let entry else { return }

            switch type {
            case .application, .unknown:
                selectedHistoryEntry = entry
            case .scene where entry.origin.resourceLocation == .unsupported:
                selectedHistoryEntry = entry
            case .scene, .video, .web:
                selectedHistoryEntry = nil
            }
        }
    }

    private func handleTap(entry: WPEHistoryEntry) {
        switch entry.origin.originalType {
        case .application, .unknown:
            selectedHistoryEntry = entry
        case .scene where entry.origin.resourceLocation == .unsupported:
            selectedHistoryEntry = entry
        case .scene, .video, .web:
            Task { @MainActor in
                await screenManager.activateWPEHistoryEntry(entry, for: screen)
                reloadHistory()
            }
        }
    }

    private func handleRemove(entry: WPEHistoryEntry) {
        pendingDestructive = PendingDestructive(
            .removeSceneHistory(sceneName: entry.origin.title)
        ) {
            screenManager.removeWPEImport(workshopID: entry.id)
            if selectedHistoryEntry?.id == entry.id {
                selectedHistoryEntry = nil
            }
            reloadHistory()
        }
    }

    private func presentFolderPicker() {
        guard let url = WPEFolderPicker.chooseImportFolder() else { return }
        Task { @MainActor in
            await screenManager.importWallpaperEngineProject(at: url, for: screen)
            reloadHistory()
        }
    }
}
#endif
