import AppKit
@testable import LiveWallpaper
import XCTest

final class MeteorShowerLifecycleTests: XCTestCase {
    /// Flight and removal ran on different clocks: the animation on the layer's,
    /// which pauses with the shower, and removal on the wall clock. A removal that
    /// came due while the shower was suspended was skipped and never rescheduled,
    /// so every sleep left the meteors then in flight on the layer for good.
    @MainActor
    func testMeteorSuspendedPastItsFlightIsStillRemovedOnResume() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()

        let shower = MeteorShower()
        try shower.attach(to: XCTUnwrap(view.layer), bounds: view.bounds, density: 1)
        defer { shower.detach() }
        let meteor = try XCTUnwrap(shower.debugLaunchNow())
        XCTAssertNotNil(meteor.superlayer)

        shower.setSuspended(true)
        // Longer than the longest flight (2.4 s): the old wall-clock removal comes due here.
        try await Task.sleep(for: .seconds(2.7))
        XCTAssertNotNil(meteor.superlayer, "a frozen meteor was swept mid-air")

        // Resume also restarts launching, so the assertion is on this one layer,
        // not on the count.
        shower.setSuspended(false)
        let deadline = Date().addingTimeInterval(4)
        while meteor.superlayer != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(meteor.superlayer, "a meteor suspended past its flight was never removed")
    }
}
