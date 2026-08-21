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

    /// The real display's menu-bar forbidden zone as a fraction of its height (top diff only — Dock excluded).
    private var topInsetFraction: CGFloat {
        let f = screen.nsScreen.frame
        guard f.height > 0 else { return 0 }
        let menuBar = f.maxY - screen.nsScreen.visibleFrame.maxY
        return max(0, min(menuBar / f.height, 1))
    }

    var body: some View {
        OverlayPreviewCanvas(screen: screen, backdrop: backdrop) {
            BoardPreview(
                configuration: board,
                topInsetFraction: topInsetFraction,
                referenceWidth: max(screen.frame.width, 1),
                onConfigurationEdited: { edited in
                    // The preview already reflects the drag; mirror it into our
                    // state so the write-back doesn't bounce the tile.
                    board = edited
                    screenManager.setMonitorOverlayBoard(edited, for: screen)
                }
            )
        }
        .onAppear(perform: reload)
        .onChange(of: screen.id) { _, _ in reload() }
        // Tracks edits made on the real overlay, not just in this preview.
        .onChange(of: persistedBoard) { _, latest in
            if board != latest { board = latest }
        }
    }

    private var persistedBoard: MonitorBoardConfiguration {
        screenManager.monitorOverlay(for: screen).board
    }

    private func reload() {
        let persisted = persistedBoard
        if board != persisted { board = persisted }
    }
}

struct BoardPreview: NSViewRepresentable {
    let configuration: MonitorBoardConfiguration
    /// Menu-bar forbidden-zone fraction, WYSIWYG with the real display.
    let topInsetFraction: CGFloat
    /// Real display width in points — the preview board scales Apple-size
    /// widgets down by boardWidth/referenceWidth so placement is WYSIWYG.
    let referenceWidth: CGFloat
    let onConfigurationEdited: (MonitorBoardConfiguration) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> HostView {
        let host = HostView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 168),
            configuration: configuration,
            nameOnlyTiles: true,
            topInsetFraction: topInsetFraction,
            referenceWidth: referenceWidth
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
        if needsApply { context.coordinator.lastAppliedConfiguration = configuration }
        let referenceWidth = referenceWidth
        let topInsetFraction = topInsetFraction
        Task { @MainActor in
            host.setReferenceWidth(referenceWidth)
            if needsApply {
                host.apply(configuration: configuration, topInsetFraction: topInsetFraction)
            }
            host.setEditing(true)
            host.setPointerScope(.wholeBoard)
        }
    }

    static func dismantleNSView(_ host: HostView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Manages the preview host's edit lifecycle only — no runtime lease, no pump (the preview shows name-only tiles).
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
