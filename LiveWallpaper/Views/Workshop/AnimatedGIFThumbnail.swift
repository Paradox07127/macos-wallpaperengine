#if !LITE_BUILD
import LiveWallpaperCore
import Observation
import SwiftUI

/// Whether an `AnimatedGIFThumbnail` plays on hover (grid / list idiom) or
/// auto-plays (single-item detail surfaces).
enum GIFPlaybackMode {
    case hoverToPlay
    case autoPlay
}

/// Workshop preview tile: static poster by default, plays the GIF/APNG only while hovered (`.hoverToPlay`) or immediately for detail surfaces (`.autoPlay`).
struct AnimatedGIFThumbnail: View {
    let url: URL?
    var playbackMode: GIFPlaybackMode = .hoverToPlay
    /// Off for tiles that draw their own bottom band — the badge sits in the
    /// same corner and would end up buried under it.
    var showsPlayingBadge: Bool = true
    /// Decode budget. Grid tiles never need the 1920×1080 poster Steam stores;
    /// the detail hero does.
    var previewSize: WorkshopPreviewSize = .tile
    /// Adult-content spoiler gate: blurs the poster behind a "click to reveal"
    /// cover and suppresses playback. The parent flipping it false resumes play.
    var isBlurred: Bool = false
    @Binding var isHovered: Bool

    @State private var controller = GIFAnimationController()
    @State private var phase: LoadPhase = .loading
    @State private var isVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A collapsed inspector keeps its subtree mounted, so `onDisappear` never
    /// fires and `isVisible` stays true — an `.autoPlay` hero would keep
    /// decoding inside a zero-width panel.
    @Environment(\.inspectorContentIsVisible) private var inspectorContentIsVisible

    private enum LoadPhase { case loading, ready, failed, empty }

    private var playbackGate: ThumbnailPlaybackGate {
        ThumbnailPlaybackGate(
            isVisible: isVisible,
            hostIsPresented: inspectorContentIsVisible,
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
        isHovered: Binding<Bool> = .constant(false)
    ) {
        self.url = url
        self.playbackMode = playbackMode
        self.showsPlayingBadge = showsPlayingBadge
        self.previewSize = previewSize
        self.isBlurred = isBlurred
        self._isHovered = isHovered
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
        .task(id: url) { await load() }
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

    /// Spoiler scrim over a blurred adult thumbnail; the parent handles the
    /// reveal tap.
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
                .scaledToFill()
                .clipped()
                .accessibilityHidden(true)
        } else if phase == .loading, url != nil {
            ArcSpinner(size: 20, lineWidth: 2, tint: .secondary)
                .opacity(0.7)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "cube.transparent")
                .font(.system(size: 36, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var playingBadge: some View {
        ThumbnailBadge("Playing", systemImage: "play.fill", opacity: 0.7)
    }

    private func load() async {
        controller.stop(resetToPoster: false)
        guard let url else {
            controller.setAsset(nil)
            phase = .empty
            return
        }
        phase = .loading
        let asset = await WorkshopPreviewImageLoader.shared.loadAsset(url, size: previewSize)
        guard !Task.isCancelled else { return }
        controller.setAsset(asset)
        phase = asset == nil ? .failed : .ready
        guard asset != nil else { return }
        applyPlaybackGate()
    }

    /// Single source of truth: the gate decides, the controller obeys. Grid
    /// tiles debounce; detail heroes run while the gate holds.
    private func applyPlaybackGate() {
        guard playbackGate.allowsPlayback else {
            controller.stop()
            return
        }
        controller.play(debounced: playbackMode == .hoverToPlay)
    }
}

/// Frame-stepping state for one thumbnail.
@MainActor
@Observable
final class GIFAnimationController {
    private(set) var displayedFrame: CGImage?
    private(set) var isAnimating = false

    private let clientID = UUID()
    private var asset: WorkshopPreviewAsset?
    private var playbackTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    func setAsset(_ asset: WorkshopPreviewAsset?) {
        stop(resetToPoster: false)
        self.asset = asset
        displayedFrame = asset?.posterFrame
    }

    /// `debounced` waits `ThumbnailPlaybackGate.hoverPreviewDelayNanoseconds`
    /// (now zero — the caller's `settledHover` owns the delay) so a mouse sweep
    /// doesn't thrash the decoder; hover-exit in the window cancels before decode.
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

    /// Restores the poster frame unless suppressed (e.g. on disappear, where
    /// there is nothing left to show).
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
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                // The task strongly holds `gif` and its `CGImageSource`, so `[weak self]` only
                // frees the controller — the decode loop keeps running for a tile already gone.
                // `onDisappear` usually calls `stop()`, but `LazyVGrid` can drop a tile without it.
                // `deinit` can't: the class is `@MainActor`, so a nonisolated `deinit` may not touch the task handles.
                guard !Task.isCancelled, let self else {
                    // Nobody is left to call `stop()`, so release the LRU slot
                    // here or a dead client holds one of the eight until it is
                    // evicted.
                    GIFPlaybackCoordinator.shared.endPlayback(id: id)
                    break
                }
                index = (index + 1) % gif.frameCount
                let frame = await GIFAnimationController.decode(gif, at: index)
                guard !Task.isCancelled else { break }
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
