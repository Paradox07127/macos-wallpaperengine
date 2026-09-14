import AppKit
import LiveWallpaperCore
import SwiftUI

@MainActor
final class MusicHostView: NSView {
    private let dataModel = DataModel()
    private let hostingView: NSHostingView<MusicOverlayRootContainer>
    private let layoutModel: MusicOverlayLayoutModel

    private(set) var configuration: MusicOverlayConfiguration

    init(
        frame frameRect: NSRect,
        configuration: MusicOverlayConfiguration,
        safeArea: MonitorSafeAreaInsets = .none,
        isEditingPreview: Bool = false
    ) {
        self.configuration = configuration
        let layoutModel = MusicOverlayLayoutModel(
            configuration: configuration,
            safeArea: safeArea,
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
        dataModel.updateNowPlaying(snapshot.nowPlaying)
    }

    func apply(configuration: MusicOverlayConfiguration, safeArea: MonitorSafeAreaInsets? = nil) {
        self.configuration = configuration
        layoutModel.configuration = configuration
        if let safeArea {
            layoutModel.safeArea = safeArea
        }
    }

    func setSuspended(_ suspended: Bool) {
        guard layoutModel.suspended != suspended else { return }
        layoutModel.suspended = suspended
    }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
    }

    // MARK: - Pointer

    /// Transport appears only on hover, so the window must receive events before a button exists (`BoardPointerScopeTests`).
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

    func acceptsPointer(atLocalPoint local: NSPoint) -> Bool {
        guard wantsPointer else { return false }
        guard let rect = MusicOverlayLayout.renderRect(
            configuration: configuration,
            boardSize: bounds.size,
            safeArea: layoutModel.safeArea
        ) else { return false }
        // SwiftUI lays out y-down from the top edge; this view is not flipped.
        let boardPoint = isFlipped ? local : CGPoint(x: local.x, y: bounds.height - local.y)
        return rect.contains(boardPoint)
    }
}

@MainActor
final class MusicOverlayLayoutModel: ObservableObject {
    @Published var configuration: MusicOverlayConfiguration
    @Published var safeArea: MonitorSafeAreaInsets
    @Published var suspended = true
    let isEditingPreview: Bool

    init(configuration: MusicOverlayConfiguration, safeArea: MonitorSafeAreaInsets, isEditingPreview: Bool) {
        self.configuration = configuration
        self.safeArea = safeArea
        self.isEditingPreview = isEditingPreview
    }
}

struct MusicOverlayRootContainer: View {
    @ObservedObject var layout: MusicOverlayLayoutModel
    @ObservedObject var data: DataModel
    /// The Music layer has no config override, so the system setting is the
    /// whole truth (the board additionally honours `reduceMotionOverride`).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        clocked.appLanguageScoped(defaults: .appScoped())
    }

    private var clocked: some View {
        TimelineView(MonitorBoardClock(suspended: layout.suspended)) { timeline in
            GeometryReader { proxy in
                if let rect = MusicOverlayLayout.renderRect(
                    configuration: layout.configuration,
                    boardSize: proxy.size,
                    safeArea: layout.safeArea
                ) {
                    NowPlayingWidgetView(context: MusicOverlayContext(
                        snapshot: data.snapshot,
                        size: layout.configuration.size,
                        options: layout.configuration.options,
                        isEditing: layout.isEditingPreview,
                        reduceMotion: reduceMotion,
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
