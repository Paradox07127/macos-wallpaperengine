#if DEBUG
import AppKit

extension QAControlPlane {
    /// Read-only hit testing, in window points with a top-left origin. Includes AppKit chrome.
    func uiHitTest(_ arguments: [String: Any]) throws -> Any {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "LiveWallpaperSettingsWindow" || $0.accessibilityIdentifier() == "LiveWallpaperSettingsWindow" }),
              let root = window.contentView?.superview else {
            throw QAError.message("Open the main window first")
        }
        let x = (arguments["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (arguments["y"] as? NSNumber)?.doubleValue ?? 0
        let point = NSPoint(x: x, y: window.frame.height - y)
        var chain: [[String: Any]] = []
        var view = root.hitTest(point)
        while let current = view {
            chain.append([
                "class": String(describing: type(of: current)),
                "frame": NSStringFromRect(current.convert(current.bounds, to: nil)),
                "hidden": current.isHidden,
                "alpha": current.alphaValue,
            ])
            view = current.superview
        }
        return ["windowSize": NSStringFromSize(window.frame.size), "windowFrame": NSStringFromRect(window.frame), "screenFrame": NSStringFromRect(window.screen?.frame ?? .zero), "key": window.isKeyWindow, "appActive": NSApp.isActive, "hitChain": chain]
    }
}
#endif
