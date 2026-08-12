import AppKit
import LiveWallpaperCore

/// Borderless non-activating panel for the Monitor board over one display's wallpaper.
final class MonitorOverlayWindow: NSPanel {

    /// Above desktop icons, below application windows.
    private static let desktopLevel = NSWindow.Level(
        rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2
    )

    init(screenFrame: NSRect, level: MonitorOverlayLevel) {
        super.init(
            contentRect: screenFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isExcludedFromWindowsMenu = true
        isRestorable = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        apply(level: level)
        setInteractive(false)
    }

    func apply(level: MonitorOverlayLevel) {
        switch level {
        case .desktop: self.level = Self.desktopLevel
        case .front: self.level = .statusBar
        }
    }

    /// Non-interactive ⇒ click-through to desktop/apps underneath.
    func setInteractive(_ interactive: Bool) {
        ignoresMouseEvents = !interactive
    }

    func applyFrame(_ frame: NSRect) {
        setFrame(frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
