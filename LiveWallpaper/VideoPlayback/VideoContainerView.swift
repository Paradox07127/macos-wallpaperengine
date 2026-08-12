import AppKit
import AVKit
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
        } else if playerLayer.responds(to: NSSelectorFromString("setWantsExtendedDynamicRangeContent:")) {
            playerLayer.setValue(enabled, forKey: "wantsExtendedDynamicRangeContent")
        }
    }

    /// `.auto`/`.forceSDR` leave layer colorspace nil (Force SDR uses Rec.709 composition).
    func setColorSpacePreference(_ preference: VideoColorSpace) {
        guard let playerLayer else { return }
        let space: CGColorSpace?
        switch preference {
        case .auto:        space = nil
        case .sRGB:        space = CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3:   space = CGColorSpace(name: CGColorSpace.displayP3)
        case .rec2020HDR:  space = CGColorSpace(name: CGColorSpace.itur_2020)
        case .forceSDR:    space = nil
        }
        // AVPlayerLayer has no typed colorspace; KVC hits CALayer.colorspace.
        // EDR is reconciled separately by WallpaperVideoPlayer (not here).
        if let space {
            playerLayer.setValue(space, forKey: "colorspace")
        } else {
            playerLayer.setValue(nil, forKey: "colorspace")
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

/// Hosts the video layer. Particle weather effects now use the common
/// per-display environment overlay so every renderer shares the same layer.
final class VideoContainerView: NSView {

    // MARK: - Subviews

    private let playerHostView: PlayerHostView
    private let particleOverlayView: ParticleOverlayView
    private var currentPlayer: AVPlayer?
    private var spanRenderConfiguration: VideoSpanRenderConfiguration?

    var fitMode: VideoFitMode = .aspectFill {
        didSet {
            guard oldValue != fitMode else { return }
            playerHostView.setVideoGravity(fitMode.avLayerVideoGravity)
        }
    }

    // MARK: - Initialization

    override init(frame frameRect: NSRect) {
        let localBounds = NSRect(origin: .zero, size: frameRect.size)
        playerHostView = PlayerHostView(frame: localBounds)
        playerHostView.autoresizingMask = []
        particleOverlayView = ParticleOverlayView(frame: localBounds)
        particleOverlayView.autoresizingMask = []

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

    func applyColorSpacePreference(_ preference: VideoColorSpace) {
        playerHostView.setColorSpacePreference(preference)
    }

    func setSpanRenderConfiguration(_ configuration: VideoSpanRenderConfiguration?) {
        guard spanRenderConfiguration != configuration else { return }
        spanRenderConfiguration = configuration
        needsLayout = true
    }

    // MARK: - Public API — Particles

    func setParticleEffect(_ effect: ParticleEffect, density: Double) {
        particleOverlayView.setEffect(effect, density: CGFloat(density))
    }

    func setParticleDensity(_ density: Double) {
        particleOverlayView.updateDensity(CGFloat(density))
    }

    func setParticleEffectsSuspended(_ suspended: Bool) {
        particleOverlayView.setSuspended(suspended)
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
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
        }
    }

    // MARK: - Memory Management

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            playerHostView.setPlayer(nil)
            particleOverlayView.setEffect(.none, density: 0)
            currentPlayer = nil
        }
    }
}
