import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Hover autoplay preview row", .serialized)
@MainActor
struct HoverAutoplayPreviewRowTests {
    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views)
    }

    private static func settle(_ window: NSWindow, for seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Parked off every display and never made key.
    private static func mount(_ view: some View) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .appScoped()) { view })
        host.frame = CGRect(x: 0, y: 0, width: 640, height: 160)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        return (window, host)
    }

    private static func savedChoice() -> Bool {
        UserDefaults.appScoped().object(forKey: EditDeskPreferences.hoverAutoplayPreview) as? Bool
            ?? EditDeskPreferences.hoverAutoplayPreviewDefault
    }

    @Test("The switch shows the saved choice, and turning it off saves off")
    func switchShowsAndWritesTheSavedChoice() async throws {
        let defaults = UserDefaults.appScoped()
        let key = EditDeskPreferences.hoverAutoplayPreview
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.set(true, forKey: key)
        let (window, host) = Self.mount(Form { HoverAutoplayPreviewRow() }.formStyle(.grouped))
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        await Self.settle(window, for: 0.8)

        let switches = Self.views(host).compactMap { $0 as? NSSwitch }
        #expect(switches.count == 1, "control: expected the row's one switch, found \(switches.count)")
        let control = try #require(switches.first)
        #expect(control.isEnabled, "the switch cannot be flipped, though hover playback exists")
        #expect(control.state == .on, "the switch does not show the saved choice (on)")

        control.performClick(nil)
        await Self.settle(window, for: 0.3)
        #expect(!Self.savedChoice(), "turning the switch off did not save off")
        #expect(control.state == .off, "the switch did not follow the saved choice to off")
    }

}
