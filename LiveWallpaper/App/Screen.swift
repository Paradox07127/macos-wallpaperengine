import AppKit
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class Screen: Identifiable, Hashable {
    let id: CGDirectDisplayID
    /// macOS's own name for the panel, or a geometry string when it reports none.
    let systemName: String
    /// User override.
    var customName: String?
    var name: String {
        guard let customName, !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return systemName
        }
        return customName
    }
    /// Global AppKit layout coordinates in points; never use for resolution labels.
    let frame: CGRect
    /// Pixel dimensions of the selected display mode. Nil when CoreGraphics
    /// cannot supply a mode; do not present logical points as a pixel fallback.
    let pixelSize: CGSize?
    let nsScreen: NSScreen
    let displayFingerprint: String
    /// Set only for panels whose key changed when UUID identity was adopted;
    /// `ScreenManager` uses it once to move their stored settings across.
    let legacyDisplayFingerprint: String?

    // MARK: - Unified Runtime Session

    private(set) var runtimeSession: (any WallpaperRuntimeSession)?

    /// Sessions fading out after being replaced. Held so screen teardown can
    /// flush them instead of leaving an untracked timer owning a live window.
    private(set) var retiringSessions: [ObjectIdentifier: any WallpaperRuntimeSession] = [:]

    var activeWallpaperWindow: NSWindow? {
        runtimeSession?.wallpaperWindow
    }

    /// A policy change also covers windows still visible during their fade.
    /// Keep this separate from activeWallpaperWindow's non-video UI contract.
    func applyCapturePolicy(_ sharingType: NSWindow.SharingType) {
        runtimeSession?.applyCapturePolicy(sharingType)
        for session in retiringSessions.values {
            session.applyCapturePolicy(sharingType)
        }
    }

    var videoPlayer: WallpaperVideoPlayer? {
        runtimeSession?.videoPlayer
    }

    var playbackController: (any WallpaperPlaybackControllable)? {
        runtimeSession as? any WallpaperPlaybackControllable
    }

    var playbackStateVersion: Int = 0

    @objc private func notifyPlaybackStateChanged() {
        playbackStateVersion += 1
    }

    private func handleRuntimeSessionTransition(
        from oldSession: (any WallpaperRuntimeSession)?,
        to newSession: (any WallpaperRuntimeSession)?
    ) {
        (oldSession as? VideoWallpaperSession)?.onVideoPlayerReplacement = nil
        let oldPlayer = oldSession?.videoPlayer
        let newPlayer = newSession?.videoPlayer
        rebindPlaybackObserver(from: oldPlayer, to: newPlayer)
        (newSession as? VideoWallpaperSession)?.onVideoPlayerReplacement = {
            [weak self] oldPlayer, newPlayer in
            self?.rebindPlaybackObserver(from: oldPlayer, to: newPlayer)
        }
    }

    private func rebindPlaybackObserver(
        from oldPlayer: WallpaperVideoPlayer?,
        to newPlayer: WallpaperVideoPlayer?
    ) {
        if !isSameVideoPlayer(oldPlayer, newPlayer), let oldPlayer {
            NotificationCenter.default.removeObserver(
                self,
                name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                object: oldPlayer
            )
        }

        if !isSameVideoPlayer(oldPlayer, newPlayer), let newPlayer {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(notifyPlaybackStateChanged),
                name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
                object: newPlayer
            )
        }

        playbackStateVersion += 1
    }

    private func isSameSession(
        _ lhs: (any WallpaperRuntimeSession)?,
        _ rhs: (any WallpaperRuntimeSession)?
    ) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    private func isSameVideoPlayer(_ lhs: WallpaperVideoPlayer?, _ rhs: WallpaperVideoPlayer?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return lhs === rhs
        case (nil, nil):
            return true
        default:
            return false
        }
    }

    var wallpaperSessionSummary: WallpaperSessionSummary {
        _ = playbackStateVersion
        return runtimeSession?.summary ?? .notConfigured
    }

    func installRuntimeSession(_ session: any WallpaperRuntimeSession) {
        guard !isSameSession(runtimeSession, session) else { return }
        let old = runtimeSession
        let automationPlan = nextAutomationTransitionPlan
        nextAutomationTransitionPlan = nil
        handleRuntimeSessionTransition(from: old, to: session)
        runtimeSession = session
        retire(old, automationPlan: automationPlan)
    }

    /// Set only in a successful automation commit; never leaks into a later manual selection.
    @ObservationIgnored var nextAutomationTransitionPlan: WallpaperTransitionPlan?

    /// Swapped by tests to pin the transition and drive it with a manual clock.
    @ObservationIgnored var transitionEnvironment = WallpaperTransitionEnvironment()

    /// Reveal transitions still running, keyed like `retiringSessions`.
    @ObservationIgnored private(set) var revealTransitions: [ObjectIdentifier: WallpaperRevealTransition] = [:]

    /// Video keeps wallpaperWindow nil, so retirement reaches its window through the player.
    /// A session that never installed a window takes the immediate path below.
    private func retire(_ old: (any WallpaperRuntimeSession)?, automationPlan: WallpaperTransitionPlan? = nil) {
        guard let old else { return }
        // A newer swap ends a reveal still in progress rather than stacking a second mask over it.
        finishRevealTransitions()
        let plan = automationPlan ?? transitionEnvironment.plan(transitionEnvironment.reduceMotion())
        guard let window = old.wallpaperWindow ?? old.videoPlayer?.playbackWindow, plan != .none else {
            old.cleanup()
            return
        }
        if case let .reveal(effect) = plan, startReveal(effect, retiring: old, window: window) {
            return
        }
        crossfade(old, window: window)
    }

    private func crossfade(_ old: any WallpaperRuntimeSession, window: NSWindow) {
        let duration = transitionEnvironment.reduceMotion()
            ? DesignTokens.Motion.wallpaperCrossfadeReducedMotionDuration
            : DesignTokens.Motion.wallpaperCrossfadeDuration
        old.applyPerformanceProfile(.suspended)
        // The outgoing window outlives this call, so it must stop taking input — otherwise an interactive scene/HTML wallpaper keeps swallowing desktop clicks for the whole fade.
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = DesignTokens.Motion.exitTiming
            window.animator().alphaValue = 0
        }
        // Tracked, not fire-and-forget: a display can be removed mid-fade and
        // `resetRuntimeSession` has to be able to flush what is still fading.
        let token = ObjectIdentifier(old)
        retiringSessions[token] = old
        // Not runAnimationGroup's completion handler: that runs nonisolated, and handing it this MainActor-bound session is a Swift 6 sending violation.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, retiringSessions.removeValue(forKey: token) != nil else {
                return
            }
            old.cleanup()
        }
    }

    /// false when the reveal cannot run (no Metal renderer, no content view); the caller crossfades instead.
    private func startReveal(
        _ effect: WallpaperRevealEffect,
        retiring old: any WallpaperRuntimeSession,
        window: NSWindow
    ) -> Bool {
        let token = ObjectIdentifier(old)
        guard let transition = WallpaperRevealTransition(
            effect: effect,
            oldWindow: window,
            newWindow: runtimeSession?.wallpaperWindow ?? runtimeSession?.videoPlayer?.playbackWindow,
            renderer: transitionEnvironment.renderer(),
            makeClock: transitionEnvironment.makeClock,
            onFinish: { [weak self] in self?.completeReveal(token) }
        ) else {
            return false
        }
        old.applyPerformanceProfile(.suspended)
        window.ignoresMouseEvents = true
        retiringSessions[token] = old
        revealTransitions[token] = transition
        guard transition.start() else {
            // start never published a mask or called onFinish. Leave cleanup to
            // the existing crossfade owner; do not strand a retiring session.
            revealTransitions[token] = nil
            retiringSessions[token] = nil
            return false
        }
        return true
    }

    private func completeReveal(_ token: ObjectIdentifier) {
        revealTransitions[token] = nil
        retiringSessions.removeValue(forKey: token)?.cleanup()
    }

    private func finishRevealTransitions() {
        for transition in Array(revealTransitions.values) {
            transition.finish()
        }
    }

    /// Drops every still-fading session immediately. Finishing the fade after the screen goes away would leave a window AppKit can reposition onto a surviving display.
    private func flushRetiringSessions() {
        finishRevealTransitions()
        nextAutomationTransitionPlan = nil
        let fading = retiringSessions.values
        retiringSessions.removeAll()
        for session in fading {
            session.cleanup()
        }
    }

    @discardableResult
    func installRuntimeSession(
        _ session: any WallpaperRuntimeSession,
        replacing expected: (any WallpaperRuntimeSession)?,
        beforeInstall: () -> Bool = { true }
    ) -> Bool {
        guard isSameSession(runtimeSession, expected) else { return false }
        // Single MainActor CAS turn: check + commit so stale candidates cannot win.
        guard beforeInstall() else { return false }
        installRuntimeSession(session)
        return true
    }

    /// Also closes whatever was still fading out on existingScreen: that screen is about to be dropped, and its fade task holds it weakly, so the fade would end without running cleanup().
    func adoptRuntimeSession(from existingScreen: Screen) {
        existingScreen.flushRetiringSessions()
        let new = existingScreen.runtimeSession
        guard !isSameSession(runtimeSession, new) else { return }
        handleRuntimeSessionTransition(from: runtimeSession, to: new)
        runtimeSession = new
    }

    func updateRuntimeFrame(to frame: CGRect) {
        runtimeSession?.updateFrame(to: frame)
    }

    func resetRuntimeSession() {
        flushRetiringSessions()
        let old = runtimeSession
        guard old != nil else { return }
        handleRuntimeSessionTransition(from: old, to: nil)
        runtimeSession = nil
        old?.cleanup()
    }
    
    // MARK: - Initialization

    convenience init(nsScreen: NSScreen) {
        self.init(nsScreen: nsScreen, displayPixelSize: { displayID in
            guard let mode = CGDisplayCopyDisplayMode(displayID),
                  mode.pixelWidth > 0, mode.pixelHeight > 0 else { return nil }
            return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
        })
    }

    init(nsScreen: NSScreen, displayPixelSize: (CGDirectDisplayID) -> CGSize?) {
        self.nsScreen = nsScreen
        self.frame = nsScreen.frame

        self.id = (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
            ?? UInt32(truncatingIfNeeded: Self.generateFallbackID(for: nsScreen))

        pixelSize = displayPixelSize(id)

        let screenName = nsScreen.localizedName
        self.systemName = screenName.isEmpty
            ? "Display \(Int(frame.width))x\(Int(frame.height)) at (\(Int(frame.origin.x)),\(Int(frame.origin.y)))"
            : screenName

        self.displayFingerprint = nsScreen.displayFingerprint
        self.legacyDisplayFingerprint = nsScreen.legacyDisplayFingerprint
    }

    /// Diagonal in inches from the panel's EDID physical size. Nil when the
    /// display reports none — plenty of external panels report 0×0.
    var diagonalInches: Double? {
        let mm = CGDisplayScreenSize(id)
        guard mm.width > 1, mm.height > 1 else { return nil }
        return (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self,
            name: WallpaperVideoPlayer.didChangePlaybackStateNotification,
            object: nil
        )
    }

    private static func generateFallbackID(for screen: NSScreen) -> Int {
        String(format: "%d-%d-%.0f-%.0f",
               Int(screen.frame.origin.x),
               Int(screen.frame.origin.y),
               screen.frame.width,
               screen.frame.height).hash
    }

    // MARK: - Hashable

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    nonisolated static func == (lhs: Screen, rhs: Screen) -> Bool {
        lhs.id == rhs.id
    }

}
