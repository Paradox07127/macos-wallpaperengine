import AppKit
import CoreGraphics
import LiveWallpaperCore

/// Renderer-independent particle layer placed above the wallpaper window and
/// below desktop icons. One click-through panel is owned per display.
@MainActor
final class EnvironmentOverlayController {
    private final class Host {
        let window: NSPanel
        let view: ParticleOverlayView
        var suspended = false

        init(window: NSPanel, view: ParticleOverlayView) {
            self.window = window
            self.view = view
        }
    }

    /// The same band the Monitor board uses: above every wallpaper window, below every
    /// application window. Not the plain desktop level — an HTML wallpaper with mouse
    /// interaction on climbs to `desktopIconWindow + 1` and would draw straight over the
    /// particles, which are opaque enough to hide them completely.
    static let overlayLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2
    )

    private var hosts: [CGDirectDisplayID: Host] = [:]

    func apply(
        effect: ParticleEffect,
        density: Double,
        tiltRadians: Double = 0,
        screenID: CGDirectDisplayID,
        screenFrame: NSRect
    ) {
        guard effect != .none else {
            teardown(screenID: screenID)
            return
        }

        let host = hosts[screenID] ?? makeHost(screenID: screenID, screenFrame: screenFrame)
        host.window.setFrame(screenFrame, display: true)
        host.view.frame = NSRect(origin: .zero, size: screenFrame.size)
        host.view.setEffect(effect, density: CGFloat(density), tiltRadians: CGFloat(tiltRadians))
        host.view.setSuspended(host.suspended)
        if !host.suspended {
            host.window.orderFrontRegardless()
        }
    }

    func setSuspended(_ suspended: Bool, screenID: CGDirectDisplayID) {
        guard let host = hosts[screenID], host.suspended != suspended else { return }
        host.suspended = suspended
        host.view.setSuspended(suspended)
        if suspended {
            host.window.orderOut(nil)
        } else {
            host.window.orderFrontRegardless()
        }
    }

    func teardown(screenID: CGDirectDisplayID) {
        guard let host = hosts.removeValue(forKey: screenID) else { return }
        host.view.setEffect(.none)
        host.window.orderOut(nil)
        host.window.close()
    }

    #if DEBUG
    /// Window level actually in force, for the regression test that pins the
    /// particles below application windows.
    func debugWindowLevel(screenID: CGDirectDisplayID) -> Int? {
        hosts[screenID]?.window.level.rawValue
    }
    #endif

    func retainOnly(_ liveScreenIDs: Set<CGDirectDisplayID>) {
        for screenID in Array(hosts.keys) where !liveScreenIDs.contains(screenID) {
            teardown(screenID: screenID)
        }
    }

    func teardownAll() {
        for screenID in Array(hosts.keys) {
            teardown(screenID: screenID)
        }
    }

    private func makeHost(screenID: CGDirectDisplayID, screenFrame: NSRect) -> Host {
        let window = NSPanel(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Order matters: `isFloatingPanel` rewrites `level` to `.floating` (3),
        // which is above every application window — the particles then rained
        // over other apps. Measured, not guessed: setting the flag after the
        // level moved it from -2147483623 to 3.
        window.isFloatingPanel = true
        window.level = Self.overlayLevel
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.isRestorable = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = ParticleOverlayView(frame: NSRect(origin: .zero, size: screenFrame.size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        let host = Host(window: window, view: view)
        hosts[screenID] = host
        return host
    }
}
