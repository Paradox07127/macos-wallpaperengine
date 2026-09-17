import AppKit
import AVKit
import Combine
import LiveWallpaperCore

// MARK: - PlayerHostView

final class PlayerHostView: NSView {

    override func makeBackingLayer() -> CALayer {
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    func setPlayer(_ player: AVPlayer?) {
        playerLayer?.player = player
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        playerLayer?.contentsScale = scale
        playerLayer?.drawsAsynchronously = true
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        playerLayer?.videoGravity = gravity
    }

    func setExtendedDynamicRangeEnabled(_ enabled: Bool) {
        guard let playerLayer else { return }
        if #available(macOS 26, *) {
            playerLayer.preferredDynamicRange = enabled ? .high : .standard
        } else {
            playerLayer.wantsExtendedDynamicRangeContent = enabled
        }
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            playerLayer?.contentsScale = scale
        }
    }
}

// MARK: - VideoContainerView

final class VideoContainerView: NSView {

    // MARK: - Subviews

    private let playerHostView: PlayerHostView
    private let particleOverlayView: ParticleOverlayView
    private var currentPlayer: AVPlayer?
    private var spanRenderConfiguration: VideoSpanRenderConfiguration?
    /// Holds the last decoded frame after hibernation blanks the player layer so an occluded desktop redraw does not go black. A subview, not a sublayer, so AppKit owns z-order above the player host.
    private let stillFrameView: StillFrameHostView
    private var stillFrameReadinessCancellable: AnyCancellable?
    private var stillFrameDeadline: DispatchWorkItem?

    var fitMode: VideoFitMode = .aspectFill {
        didSet {
            guard oldValue != fitMode else { return }
            playerHostView.setVideoGravity(fitMode.avLayerVideoGravity)
            stillFrameView.setContentsGravity(Self.contentsGravity(for: fitMode))
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        let localBounds = NSRect(origin: .zero, size: frameRect.size)
        playerHostView = PlayerHostView(frame: localBounds)
        playerHostView.autoresizingMask = []
        particleOverlayView = ParticleOverlayView(frame: localBounds)
        particleOverlayView.autoresizingMask = []
        stillFrameView = StillFrameHostView(frame: localBounds)
        stillFrameView.autoresizingMask = []

        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = .clear
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.drawsAsynchronously = true
        layer?.masksToBounds = true

        addSubview(playerHostView)
        // Retain the compatibility object for player state handoff, but do not
        // mount it: `EnvironmentOverlayController` owns the rendered particles.

        stillFrameView.isHidden = true
        stillFrameView.setContentsGravity(Self.contentsGravity(for: fitMode))
        addSubview(stillFrameView, positioned: .above, relativeTo: playerHostView)

        if let window = window {
            layer?.contentsScale = window.backingScaleFactor
        }
    }

    // MARK: - Public API — Video

    func setPlayer(_ player: AVPlayer?) {
        if player === currentPlayer { return }

        currentPlayer = player
        playerHostView.setVideoGravity(fitMode.avLayerVideoGravity)
        playerHostView.setPlayer(player)
    }

    var isReadyForDisplay: Bool {
        playerHostView.playerLayer?.isReadyForDisplay == true
    }

    func applyHDRPreference(_ enabled: Bool) {
        playerHostView.setExtendedDynamicRangeEnabled(enabled)
    }

    func setSpanRenderConfiguration(_ configuration: VideoSpanRenderConfiguration?) {
        guard spanRenderConfiguration != configuration else { return }
        spanRenderConfiguration = configuration
        needsLayout = true
    }

    // MARK: - Public API — Hibernation Still Frame

    /// The frame on the desktop while the player is released (deep hibernation).
    var currentStillFrame: CGImage? {
        stillFrameView.isHidden ? nil : stillFrameView.image
    }

    var isShowingStillFrame: Bool { !stillFrameView.isHidden }

    func showStillFrame(_ image: CGImage) {
        stillFrameReadinessCancellable = nil
        cancelStillFrameDeadline()
        stillFrameView.setImage(image)
        stillFrameView.isHidden = false
        needsLayout = true
    }

    /// Hard bound on how long the still frame may outlive wake start. A load that never reaches `clearStillFrameWhenPlayerIsReady`, or a layer that never reports `isReadyForDisplay`, would otherwise freeze the desktop on a fake frame.
    func clearStillFrameNoLaterThan(_ seconds: TimeInterval) {
        guard isShowingStillFrame else { return }
        cancelStillFrameDeadline()
        let work = DispatchWorkItem { [weak self] in self?.clearStillFrame() }
        stillFrameDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelStillFrameDeadline() {
        stillFrameDeadline?.cancel()
        stillFrameDeadline = nil
    }

    /// Held until the rebuilt player layer actually has a picture; dropping it
    /// at wake time would flash black for the rebuild latency.
    func clearStillFrameWhenPlayerIsReady() {
        guard isShowingStillFrame, let playerLayer = playerHostView.playerLayer else { return }
        if playerLayer.isReadyForDisplay {
            clearStillFrame()
            return
        }
        stillFrameReadinessCancellable = playerLayer.publisher(for: \.isReadyForDisplay)
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.clearStillFrame()
            }
    }

    func clearStillFrame() {
        stillFrameReadinessCancellable = nil
        cancelStillFrameDeadline()
        stillFrameView.isHidden = true
        stillFrameView.setImage(nil)
    }

    private static func contentsGravity(for fitMode: VideoFitMode) -> CALayerContentsGravity {
        switch fitMode.avLayerVideoGravity {
        case .resizeAspect: return .resizeAspect
        case .resize: return .resize
        default: return .resizeAspectFill
        }
    }

    // MARK: - Public API — Particles

    func setParticleEffect(_ effect: ParticleEffect, density: Double) {
        particleOverlayView.setEffect(effect, density: CGFloat(density))
    }

    func setParticleEffectsSuspended(_ suspended: Bool) {
        // Runtime gate only — this overlay is never a subview (see `init`); it just mirrors player state across a handoff. Reduce Motion is handled in `EnvironmentOverlayController`.
        particleOverlayView.setSuspended(suspended, for: .runtime)
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        if let spanRenderConfiguration {
            playerHostView.frame = spanRenderConfiguration.canvasFrameInScreenCoordinates
        } else {
            playerHostView.frame = bounds
        }
        particleOverlayView.frame = bounds
        stillFrameView.frame = playerHostView.frame
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            stillFrameView.layer?.contentsScale = scale
        }
    }

    // MARK: - Memory Management

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            playerHostView.setPlayer(nil)
            particleOverlayView.setEffect(.none, density: 0)
            currentPlayer = nil
            clearStillFrame()
        }
    }
}

// MARK: - StillFrameHostView

private final class StillFrameHostView: NSView {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Contents are assigned directly; there is nothing to redraw.
        layerContentsRedrawPolicy = .never
        layer?.masksToBounds = true
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private(set) var image: CGImage?

    func setImage(_ image: CGImage?) {
        self.image = image
        // Implicit animation would cross-fade the still frame in and out.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    func setContentsGravity(_ gravity: CALayerContentsGravity) {
        layer?.contentsGravity = gravity
    }
}
