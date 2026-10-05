import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// Toolbar icon groups take a native macOS 26 toolbar's glass-group geometry: 36pt capsules, 36pt keys.
@MainActor
@Suite("Glass toolbar groups")
struct GlassToolbarGroupTests {

    private func near(_ size: CGSize, _ width: CGFloat, _ height: CGFloat) -> Bool {
        abs(size.width - width) < 0.5 && abs(size.height - height) < 0.5
    }

    @Test("A one-key group is a 36pt circle")
    func oneKeyIsACircle() {
        let size = NSHostingView(rootView: GlassToolbarGroup { GlassToolbarItem("sidebar.right") {} }).fittingSize
        #expect(near(size, 36, 36), Comment(rawValue: "\(size)"))
    }

    @Test("Three keys share one 36pt capsule, 36pt a key")
    func threeKeysShareOneCapsule() {
        let size = NSHostingView(rootView: GlassToolbarGroup {
            GlassToolbarItem("rectangle.2.swap") {}
            GlassToolbarItem("arrow.triangle.2.circlepath") {}
            GlassToolbarItem("trash", role: .destructive) {}
        }).fittingSize
        #expect(near(size, 108, 36), Comment(rawValue: "\(size)"))
    }

}
