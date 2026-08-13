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
        old?.cleanup()
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
