import AppKit
import LiveWallpaperCore
import SwiftUI

/// AppKit host for the Now Playing layer — one per display, holding exactly one
/// layer. It deliberately does not reuse the Monitor board's host: the board
/// exists to lay out, select, drag and add tiles on a grid, and none of that
/// applies to a single layer whose position comes from the Music settings page.
@MainActor
final class MusicHostView: NSView {
    private let dataModel = DataModel()
    private let hostingView: NSHostingView<MusicOverlayRootContainer>
    private let layoutModel: MusicOverlayLayoutModel

    private(set) var configuration: MusicOverlayConfiguration

    init(
        frame frameRect: NSRect,
        configuration: MusicOverlayConfiguration,
        topInsetFraction: CGFloat = 0,
        isEditingPreview: Bool = false
    ) {
        self.configuration = configuration
        let layoutModel = MusicOverlayLayoutModel(
            configuration: configuration,
            topInsetFraction: topInsetFraction,
            isEditingPreview: isEditingPreview
        )
        self.layoutModel = layoutModel
        self.hostingView = NSHostingView(
            rootView: MusicOverlayRootContainer(layout: layoutModel, data: dataModel)
        )

        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Data pump (externally driven)

    func push(_ snapshot: MonitorSnapshot) {
        dataModel.update(snapshot)
    }

    func apply(configuration: MusicOverlayConfiguration, topInsetFraction: CGFloat? = nil) {
        self.configuration = configuration
        layoutModel.configuration = configuration
        if let topInsetFraction { layoutModel.topInsetFraction = topInsetFraction }
    }

    /// Stops the 1 Hz clock and the reactive animations while suspended.
    func setSuspended(_ suspended: Bool) {
        guard layoutModel.suspended != suspended else { return }
        layoutModel.suspended = suspended
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    // MARK: - Pointer

    /// Only the transport controls ever want the pointer, and only while there
    /// is a track drawn under it.
    var wantsPointer: Bool {
        let options = NowPlayingOptions(configuration.options)
        guard options.showControls || options.seekOnProgressDrag else { return false }
        return dataModel.snapshot.nowPlaying?.phase.hasTrack == true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        guard acceptsPointer(atLocalPoint: local) else { return nil }
        return super.hitTest(point)
    }

    /// Gate for one event, in this view's own coordinates. Split out of
    /// `hitTest` so it can be exercised without an NSHostingView underneath.
    func acceptsPointer(atLocalPoint local: NSPoint) -> Bool {
        guard wantsPointer else { return false }
        guard let rect = MusicOverlayLayout.renderRect(
            configuration: configuration,
            boardSize: bounds.size,
            topInsetFraction: layoutModel.topInsetFraction
        ) else { return false }
        // SwiftUI lays out y-down from the top edge; this view is not flipped.
        let boardPoint = isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
        return rect.contains(boardPoint)
    }
}

/// Observable half of the host, so a configuration change re-renders without
/// rebuilding the hosting view.
@MainActor
final class MusicOverlayLayoutModel: ObservableObject {
    @Published var configuration: MusicOverlayConfiguration
    @Published var topInsetFraction: CGFloat
    @Published var suspended = true
    let isEditingPreview: Bool

    init(configuration: MusicOverlayConfiguration, topInsetFraction: CGFloat, isEditingPreview: Bool) {
        self.configuration = configuration
        self.topInsetFraction = topInsetFraction
        self.isEditingPreview = isEditingPreview
    }
}

struct MusicOverlayRootContainer: View {
    @ObservedObject var layout: MusicOverlayLayoutModel
    @ObservedObject var data: DataModel

    var body: some View {
        // One clock for the layer, stopped while suspended — the same contract
        // the board's tiles run on.
        TimelineView(MonitorBoardClock(suspended: layout.suspended)) { timeline in
            GeometryReader { proxy in
                if let rect = MusicOverlayLayout.renderRect(
                    configuration: layout.configuration,
                    boardSize: proxy.size,
                    topInsetFraction: layout.topInsetFraction
                ) {
                    NowPlayingWidgetView(context: MusicOverlayContext(
                        snapshot: data.snapshot,
                        size: layout.configuration.size,
                        options: layout.configuration.options,
                        isEditing: layout.isEditingPreview,
                        reduceMotion: false,
                        now: timeline.date
                    ))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
        .environment(\.monitorSuspended, layout.suspended)
        .background(Color.clear)
    }
}
