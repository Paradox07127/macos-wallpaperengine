import AppKit
import LiveWallpaperCore
import Observation

@MainActor @Observable
final class Screen: Identifiable, Hashable {
    let id: CGDirectDisplayID
    /// macOS's own name for the panel, or a geometry string when it reports none.
    let systemName: String
    /// User override, re-applied by `ScreenManager` on every screen refresh
    /// (`Screen` instances are rebuilt from scratch each time).
    var customName: String?
    /// What every UI surface shows. Trimmed-empty overrides fall back to the system name.
    var name: String {
        guard let customName, !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return systemName
        }
        return customName
    }
    let frame: CGRect
    let nsScreen: NSScreen
    let displayFingerprint: String
    /// Set only for panels whose key changed when UUID identity was adopted;
    /// `ScreenManager` uses it once to move their stored settings across.
    let legacyDisplayFingerprint: String?

    // MARK: - Unified Runtime Session

    private(set) var runtimeSession: (any WallpaperRuntimeSession)?

    /// Sessions fading out after being replaced. Held so screen teardown can
    /// flush them instead of leaving an untracked timer owning a live window.
    private var retiringSessions: [ObjectIdentifier: any WallpaperRuntimeSession] = [:]

    var activeWallpaperWindow: NSWindow? {
        runtimeSession?.wallpaperWindow
    }

    var videoPlayer: WallpaperVideoPlayer? {
        runtimeSession?.videoPlayer
    }

    var playbackController: (any WallpaperPlaybackControllable)? {
        runtimeSession as? any WallpaperPlaybackControllable
    }

    /// Incremented whenever the video player's playback state changes,
    /// triggering @Observable updates for any SwiftUI view reading it.
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
        handleRuntimeSessionTransition(from: old, to: session)
        runtimeSession = session
        retire(old)
    }

    /// `WallpaperPreparation.prepareAndCommit` shows the incoming window before
    /// committing it, behind this one, so fading the outgoing window out reveals
    /// it — one animation, no compositing of two live scenes.
    ///
    /// Video keeps `wallpaperWindow` nil — that property also drives capture
    /// sharing, the HTML coordinator and the playback inspector, and widening it
    /// would change all three — so its window is reached through the player.
    /// A session that never installed a window takes the immediate path below.
    private func retire(_ old: (any WallpaperRuntimeSession)?) {
        guard let old else { return }
        guard let window = old.wallpaperWindow ?? old.videoPlayer?.playbackWindow,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            old.cleanup()
            return
        }
        old.applyPerformanceProfile(.suspended)
        // The outgoing window outlives this call, so it must stop taking input —
        // otherwise an interactive scene/HTML wallpaper keeps swallowing desktop
        // clicks for the whole fade.
        window.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DesignTokens.Motion.wallpaperCrossfadeDuration
            context.timingFunction = DesignTokens.Motion.exitTiming
            window.animator().alphaValue = 0
        }
        // Tracked, not fire-and-forget: a display can be removed mid-fade and
        // `resetRuntimeSession` has to be able to flush what is still fading.
        let token = ObjectIdentifier(old)
        retiringSessions[token] = old
        // Not `runAnimationGroup`'s completion handler: that runs nonisolated, and
        // handing it this MainActor-bound session is a Swift 6 sending violation.
        // Started from the MainActor instead, so the session never leaves it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DesignTokens.Motion.wallpaperCrossfadeDuration))
            guard let self, retiringSessions.removeValue(forKey: token) != nil else {
                return
            }
            old.cleanup()
        }
    }

    /// Drops every still-fading session immediately. Called when the screen goes
    /// away, where finishing the fade would leave a window AppKit can reposition
    /// onto a surviving display.
    private func flushRetiringSessions() {
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

    func adoptRuntimeSession(from existingScreen: Screen) {
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

    init(nsScreen: NSScreen) {
        self.nsScreen = nsScreen
        self.frame = nsScreen.frame

        self.id = (nsScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)
            ?? UInt32(truncatingIfNeeded: Self.generateFallbackID(for: nsScreen))

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
