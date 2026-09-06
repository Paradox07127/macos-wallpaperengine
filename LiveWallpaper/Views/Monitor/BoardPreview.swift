import AppKit
import LiveWallpaperCore
import SwiftUI

/// The still frame of whatever wallpaper is playing behind the overlay. Only a
/// still: a live second copy of the wallpaper here would double its cost for a
/// preview the user looks at for a few seconds.
enum MonitorPreviewBackdrop: Equatable {
    case none
    case still(NSImage)
    case projectPreview(URL, bookmark: Data?)

    static let showsWallpaperDefaultsKey = "Monitor.PreviewShowsWallpaper"

    var isAvailable: Bool { self != .none }
}

struct BoardPreviewArea: View {
    let screen: Screen
    let screenManager: ScreenManager
    var backdrop: MonitorPreviewBackdrop = .none

    @State private var board: MonitorBoardConfiguration = .default
    @State private var mode: MonitorBoardPreviewMode = .snapshot
    /// Captured once per mode change, never on a sample arriving: a board the
    /// user is dragging tiles around in must not relayout under their hand.
    @State private var preview = MonitorBoardPreview(mode: .snapshot)

    /// The real display's menu-bar and Dock zones, from the one calculation the
    /// desktop board uses.
    private var safeArea: MonitorSafeAreaInsets {
        MonitorSafeAreaInsets.of(screen.nsScreen)
    }

    /// The board is laid out at the display's own point size and the whole thing
    /// is scaled down afterwards. Handing a tile the shrunken width instead
    /// re-wraps its text, and the preview stops predicting the desktop.
    private var logicalSize: CGSize {
        CGSize(width: max(screen.frame.width, 1), height: max(screen.frame.height, 1))
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            OverlayPreviewCanvas(screen: screen, backdrop: backdrop) {
                GeometryReader { proxy in
                    let scale = proxy.size.width > 0 ? proxy.size.width / logicalSize.width : 1
                    BoardPreview(
                        configuration: board,
                        preview: preview,
                        safeArea: safeArea,
                        onConfigurationEdited: { edited in
                            // The preview already reflects the drag; mirror it into our
                            // state so the write-back doesn't bounce the tile.
                            board = edited
                            screenManager.setMonitorOverlayBoard(edited, for: screen)
                        }
                    )
                    .frame(width: logicalSize.width, height: logicalSize.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
            controls
        }
        .onAppear {
            reload()
            capture()
        }
        .onChange(of: screen.id) { _, _ in
            reload()
            capture()
        }
        .onChange(of: mode) { _, _ in capture() }
        // Tracks edits made on the real overlay, not just in this preview.
        .onChange(of: persistedBoard) { _, latest in
            if board != latest { board = latest }
        }
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Picker(selection: $mode) {
                ForEach(MonitorBoardPreviewMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Text(caption)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    /// Says what the board is showing, so a frozen reading is never mistaken for
    /// a live one and the fixture is never mistaken for this Mac.
    private var caption: String {
        switch mode {
        case .names:
            return ""
        case .sample:
            return MonitorBoardPreviewStrings.sampleDataCaption
        case .snapshot:
            guard let capturedAt = preview.capturedAt else {
                return MonitorBoardPreviewStrings.noSnapshotCaption
            }
            return MonitorBoardPreviewStrings.snapshotAge(
                MonitorBoardPreviewStrings.relativeAge(capturedAt, now: Date())
            )
        }
    }

    private var persistedBoard: MonitorBoardConfiguration {
        screenManager.monitorOverlay(for: screen).board
    }

    private func reload() {
        let persisted = persistedBoard
        if board != persisted { board = persisted }
    }

    /// One read of what the desktop already has. No lease, no sampler, no
    /// subscription — opening this page must not start a source the user has
    /// not authorized.
    private func capture() {
        preview = MonitorBoardPreview.resolve(
            mode: mode, latest: OverlayController.shared.lastDeliveredData
        )
    }
}

struct BoardPreview: NSViewRepresentable {
    let configuration: MonitorBoardConfiguration
    /// Frozen contents; the preview host is never pushed a live snapshot.
    let preview: MonitorBoardPreview
    /// Menu-bar / Dock zones, WYSIWYG with the real display.
    let safeArea: MonitorSafeAreaInsets
    let onConfigurationEdited: (MonitorBoardConfiguration) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HostView {
        let host = HostView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 168),
            configuration: configuration,
            preview: preview,
            safeArea: safeArea
        )
        host.onConfigurationEdited = onConfigurationEdited
        context.coordinator.attach(host)
        // Defer published state changes until after SwiftUI's view-update transaction.
        Task { @MainActor in
            host.setEditing(true)
            host.setPointerScope(.wholeBoard)
        }
        return host
    }

    func updateNSView(_ host: HostView, context: Context) {
        host.onConfigurationEdited = onConfigurationEdited
        let needsApply = context.coordinator.lastAppliedConfiguration != configuration
        if needsApply {
            context.coordinator.lastAppliedConfiguration = configuration
        }
        let preview = preview
        let safeArea = safeArea
        Task { @MainActor in
            if needsApply {
                host.apply(configuration: configuration, safeArea: safeArea)
            }
            host.setPreview(preview)
            host.setEditing(true)
            host.setPointerScope(.wholeBoard)
        }
    }

    static func dismantleNSView(_ host: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Manages the preview host's edit lifecycle only — no runtime lease, no pump (its data is frozen).
    @MainActor
    final class Coordinator {
        private weak var host: HostView?
        var lastAppliedConfiguration: MonitorBoardConfiguration?

        func attach(_ host: HostView) {
            self.host = host
            self.lastAppliedConfiguration = nil
        }

        func detach() {
            // Flush any debounced board edit before dropping the callback so a final
            // preview edit isn't lost when the host is torn down.
            host?.flushPendingEdits()
            host?.onConfigurationEdited = nil
            host = nil
        }
    }
}
