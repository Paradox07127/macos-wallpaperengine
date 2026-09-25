import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// Toolbar icon groups take a native macOS 26 toolbar's glass-group geometry: 36pt capsules, 36pt keys.
@MainActor
@Suite("Glass toolbar groups")
struct GlassToolbarGroupTests {
    private static func componentSource() throws -> String {
        // Tests/LiveWallpaperCoreTests/UI/<this file> — the package root is four levels up.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = "Sources/LiveWallpaperCore/UI/Components/GlassToolbarGroup.swift"
        return try String(contentsOf: packageRoot.appendingPathComponent(path), encoding: .utf8)
    }

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

    @Test("The capsule goes through AdaptiveGlass; glyphs are toolbar-sized, dim to tertiary, and a destructive one is red")
    func componentContract() throws {
        let source = try Self.componentSource()
        #expect(source.contains(".adaptiveGlassSurface(.capsule)"))
        #expect(!source.contains("glassEffect"), "raw glass skips the macOS 14/15 tier and Reduce Transparency")
        #expect(source.contains(".imageScale(.large)"))
        #expect(source.contains("AnyShapeStyle(.tertiary)"))
        #expect(source.contains("DesignTokens.Colors.Status.danger"))
        #expect(GlassToolbarMetrics.containerSpacing < GlassToolbarMetrics.groupSpacing, "capsules would melt together at rest")
    }
}
