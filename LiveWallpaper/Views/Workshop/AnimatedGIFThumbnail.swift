#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

enum GIFPlaybackMode {
    case hoverToPlay
    case autoPlay
}

struct AnimatedGIFThumbnail: View {
    let url: URL?
    var playbackMode: GIFPlaybackMode = .hoverToPlay
    /// Off for tiles that draw their own bottom band — the badge sits in the
    /// same corner and would end up buried under it.
    var showsPlayingBadge: Bool = true
    /// Decode budget. Grid tiles never need the 1920×1080 poster Steam stores;
    /// the detail hero does.
    var previewSize: WorkshopPreviewSize = .tile
    /// The parent flipping it false resumes play.
    var isBlurred: Bool = false
    /// `.fit` shows the whole picture inside the frame; `.fill` crops it to cover the frame.
    var contentMode: ContentMode = .fill
    @Binding var isHovered: Bool

    @State private var controller = GIFAnimationController()
    @State private var phase: LoadPhase = .loading
    @State private var retryAttempt = 0
    @State private var isVisible = false
    @State private var hostAllowsPlayback = false
    private let loadAsset: @MainActor (URL, WorkshopPreviewSize) async -> WorkshopPreviewAsset?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A collapsed inspector keeps its subtree mounted, so `onDisappear` never
    /// fires and `isVisible` stays true — an `.autoPlay` hero would keep decoding.
    @Environment(\.inspectorContentIsVisible) private var inspectorContentIsVisible

    private enum LoadPhase { case loading, ready, failed, empty }

    private struct LoadKey: Hashable {
        let url: URL?
        let size: WorkshopPreviewSize
        let isPresented: Bool
        let retryAttempt: Int
    }

    private var loadKey: LoadKey {
        LoadKey(url: url, size: previewSize, isPresented: inspectorContentIsVisible, retryAttempt: retryAttempt)
    }

    private var playbackGate: ThumbnailPlaybackGate {
        ThumbnailPlaybackGate(
            isVisible: isVisible,
            hostIsPresented: phase == .ready && inspectorContentIsVisible && hostAllowsPlayback,
            isHovered: isHovered,
            reduceMotion: reduceMotion,
            isBlurred: isBlurred,
            trigger: playbackMode == .hoverToPlay ? .hover : .auto
        )
    }

    init(
        url: URL?,
        playbackMode: GIFPlaybackMode = .hoverToPlay,
        showsPlayingBadge: Bool = true,
        previewSize: WorkshopPreviewSize = .tile,
        isBlurred: Bool = false,
        contentMode: ContentMode = .fill,
        isHovered: Binding<Bool> = .constant(false),
        controller: GIFAnimationController = GIFAnimationController(),
        loadAsset: @escaping @MainActor (URL, WorkshopPreviewSize) async -> WorkshopPreviewAsset? = { url, size in
            await WorkshopPreviewImageLoader.shared.loadAsset(url, size: size)
        }
    ) {
        self.url = url
        self.playbackMode = playbackMode
        self.showsPlayingBadge = showsPlayingBadge
        self.previewSize = previewSize
        self.isBlurred = isBlurred
        self.contentMode = contentMode
        self._isHovered = isHovered
        _controller = State(initialValue: controller)
        self.loadAsset = loadAsset
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            content
                .blur(radius: isBlurred ? 26 : 0)
            if isBlurred {
                matureCover
            }
        }
        .overlay(alignment: .bottomLeading) {
            if controller.isAnimating, !isBlurred, showsPlayingBadge {
                playingBadge
                    .padding(DesignTokens.Spacing.sm)
                    .transition(.opacity)
            }
        }
        .animation(DesignTokens.motion(reduceMotion, .easeInOut(duration: 0.15)), value: controller.isAnimating)
        .clipped()
        .background {
            // Static and missing previews have no playback lifecycle to observe.
            if phase == .ready, controller.hasAnimatedAsset {
                GIFHostVisibilityProbe { allowed in
                    hostAllowsPlayback = allowed
                    // Resign/activate can coalesce into one SwiftUI update after the coordinator stopped us.
                    applyPlaybackGate(hostAllowsPlayback: allowed)
                }
                .id(loadKey)
            }
        }
        .task(id: loadKey) {
            guard inspectorContentIsVisible, !Task.isCancelled else { return }
            await load()
        }
        .onAppear {
            isVisible = true
            applyPlaybackGate()
        }
        .onChange(of: playbackGate) { _, _ in applyPlaybackGate() }
        .onDisappear {
            isVisible = false
            controller.stop()
        }
    }

    /// The parent handles the reveal tap.
    private var matureCover: some View {
        ZStack {
            Color.black.opacity(0.45)
            VStack(spacing: 5) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 22, weight: .semibold))
                Text("Mature", comment: "Spoiler cover over an adult-rated Workshop thumbnail.")
                    .font(DesignTokens.Typography.captionEmphasized)
                Text("Click to reveal", comment: "Hint on the spoiler cover over an adult-rated Workshop thumbnail.")
                    .font(DesignTokens.Typography.badge)
                    .opacity(0.85)
            }
            .foregroundStyle(DesignTokens.Colors.overlayForeground)
            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Mature content hidden. Activate to reveal."))
    }

    @ViewBuilder
    private var content: some View {
        if let frame = controller.displayedFrame {
            Image(decorative: frame, scale: 1)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: contentMode)
                .clipped()
                .accessibilityHidden(true)
        } else if phase == .loading, url != nil {
            ArcSpinner(size: 20, lineWidth: 2, tint: .secondary)
                .opacity(0.7)
                .accessibilityHidden(true)
        } else if phase == .failed, !isBlurred {
            failedPreview
        } else {
            Image(systemName: "cube.transparent")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var failedPreview: some View {
        VStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "cube.transparent")
                .font(.system(size: DesignTokens.EmptyState.compactIconSize))
                .foregroundStyle(DesignTokens.Colors.textTertiary)
                .accessibilityHidden(true)
            Text("Preview unavailable", comment: "Workshop thumbnail could not be loaded after retries.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
            Button {
                phase = .loading
                retryAttempt += 1
            } label: {
                Label("Retry thumbnail", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(DesignTokens.Typography.caption)
            .accessibilityIdentifier("workshop.thumbnail.retry")
        }
        .padding(DesignTokens.Spacing.sm)
    }

    private var playingBadge: some View {
        ThumbnailBadge("Playing", systemImage: "play.fill", opacity: 0.7)
    }

    private func load() async {
        controller.stop(resetToPoster: false)
        // A new source needs its own mounted host result before it can start.
        hostAllowsPlayback = false
        guard let url else {
            controller.setAsset(nil)
            phase = .empty
            return
        }
        phase = .loading
        let asset = await loadAsset(url, previewSize)
        guard !Task.isCancelled else { return }
        controller.setAsset(asset)
        phase = asset == nil ? .failed : .ready
        guard asset != nil else { return }
        applyPlaybackGate()
    }

    private func applyPlaybackGate(hostAllowsPlayback: Bool? = nil) {
        var gate = playbackGate
        if let hostAllowsPlayback {
            gate.hostIsPresented = phase == .ready && inspectorContentIsVisible && hostAllowsPlayback
        }
        guard gate.allowsPlayback else {
            controller.stop()
            return
        }
        controller.play(debounced: playbackMode == .hoverToPlay)
    }
}

@MainActor
@Observable
final class GIFAnimationController {
    private(set) var displayedFrame: CGImage?
    private(set) var isAnimating = false

    private let clientID = UUID()
    private var asset: WorkshopPreviewAsset?

    var hasAnimatedAsset: Bool {
        if case .animatedGIF = asset {
            return true
        }
        return false
    }

    private var playbackTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    func setAsset(_ asset: WorkshopPreviewAsset?) {
        stop(resetToPoster: false)
        self.asset = asset
        displayedFrame = asset?.posterFrame
    }

    /// `debounced` waits `ThumbnailPlaybackGate.hoverPreviewDelayNanoseconds` (now
    /// zero — the caller's `settledHover` owns the delay); hover-exit cancels first.
    func play(debounced: Bool) {
        guard case .animatedGIF = asset, playbackTask == nil else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if debounced {
                try? await Task.sleep(nanoseconds: ThumbnailPlaybackGate.hoverPreviewDelayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            self?.beginPlayback()
        }
    }

    func stop(resetToPoster: Bool = true) {
        debounceTask?.cancel()
        debounceTask = nil
        let wasRegistered = isAnimating || playbackTask != nil
        playbackTask?.cancel()
        playbackTask = nil
        isAnimating = false
        if wasRegistered {
            GIFPlaybackCoordinator.shared.endPlayback(id: clientID)
        }
        if resetToPoster {
            displayedFrame = asset?.posterFrame
        }
    }

    #if DEBUG
    var clientIDForTesting: UUID {
        clientID
    }

    /// Synchronous `play`: lets a test register a replacement in the same turn that stopped its predecessor.
    func beginPlaybackNowForTesting() {
        beginPlayback()
    }
    #endif

    private func beginPlayback() {
        guard case .animatedGIF(let gif) = asset, playbackTask == nil else { return }
        let id = clientID
        GIFPlaybackCoordinator.shared.requestPlayback(id: id) { [weak self] in
            self?.stop()
        }
        isAnimating = true
        playbackTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled {
                let delay = index < gif.frameDelays.count ? gif.frameDelays[index] : 0.1
                let next = (index + 1) % gif.frameCount
                let frame = await PreviewFrameLoader.frame(after: delay) {
                    await GIFAnimationController.decode(gif, at: next)
                }
                // Cancellation comes from `stop()`, which already released the slot; a later `play()` may have re-registered this same id.
                guard !Task.isCancelled else { break }
                // The task strongly holds `gif` and its `CGImageSource`, so `[weak self]` only
                // frees the controller — and `LazyVGrid` can drop a tile without `onDisappear`.
                // `deinit` can't: the class is `@MainActor`, so it may not touch the task handles.
                guard let self else {
                    // Nobody is left to call `stop()`, so release the LRU slot here or a dead
                    // client holds one of the eight until it is evicted.
                    GIFPlaybackCoordinator.shared.endPlayback(id: id)
                    break
                }
                index = next
                if let frame { self.displayedFrame = frame }
            }
        }
    }

    /// Decodes off the main actor: `CGImageSourceCreateImageAtIndex` is
    /// free-threaded, keeping heavy decodes off the render loop.
    private static func decode(_ gif: WorkshopAnimatedGIF, at index: Int) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            gif.frame(at: index)
        }.value
    }
}
#endif
