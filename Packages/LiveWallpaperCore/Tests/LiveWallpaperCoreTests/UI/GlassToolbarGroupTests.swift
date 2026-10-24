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

    @Test("A compact group stands level with a large GlassIconButton: 28pt tall, 28pt a key")
    func compactKeysMatchTheIconButton() {
        let one = NSHostingView(rootView: GlassToolbarGroup(size: .compact) { GlassToolbarItem("bookmark") {} }).fittingSize
        #expect(near(one, 28, 28), Comment(rawValue: "\(one)"))
        let two = NSHostingView(rootView: GlassToolbarGroup(size: .compact) {
            GlassToolbarItem("folder") {}
            GlassToolbarItem("arrow.up.forward.app") {}
        }).fittingSize
        #expect(near(two, 56, 28), Comment(rawValue: "\(two)"))
        let button = NSHostingView(rootView: GlassIconButton("xmark") {}).fittingSize
        #expect(abs(one.height - button.height) < 0.5, Comment(rawValue: "\(one) vs \(button)"))
    }
}
