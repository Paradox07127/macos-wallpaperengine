import Foundation
import Testing

/// SCREENS.md S6 repaints two Edit Desk detail icon buttons — the HUD's transport primary and the
/// top bar's 🗑 — without touching any other `GlassIconButton` call site.
@Suite("Edit Desk detail icon buttons — source contract")
struct DetailIconButtonSourceTests {
    private static let hudPath = "LiveWallpaper/Views/EditDesk/Detail/DetailHero.swift"
    private static let topBarPath = "LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift"
    private static let hostPath = "LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift"

    @Test("Transport uses the shared system glass button without a second capsule")
    func hudPrimaryUsesSystemGlass() throws {
        let source = try RepositoryRoot.source(Self.hudPath)
        #expect(source.contains("GlassIconButton(status.intendsToPlay"))
        #expect(!source.contains("adaptiveGlassSurface(.capsule"))
    }

    @Test("Toolbar actions share glass capsules, keep their identifiers, and label the destructive one")
    func toolbarUsesGlassGroups() throws {
        let source = try RepositoryRoot.source(Self.topBarPath)
        #expect(source.contains("GlassToolbarGroup {"))
        #expect(!source.contains("GlassIconButton("), "a top bar action went back to a standalone circle")
        #expect(source.contains(#"GlassToolbarItem("trash", role: .destructive"#))
        #expect(source.contains("accessibilityLabel(Text(\"Clear Wallpaper\"))"))
        #expect(source.contains(#".accessibilityIdentifier("detail.\(symbol)")"#))
        #expect(!source.contains("sidebar.left"), "the layers toggle belongs to the canvas panel alone")
    }

    @Test("The top bar's reload button reloads only the display it shows")
    func reloadReachesThisDisplayOnly() throws {
        let topBar = try RepositoryRoot.source(Self.topBarPath)
        let host = try RepositoryRoot.source(Self.hostPath)
        #expect(topBar.contains("actions.reload"))
        #expect(host.contains("reloadWallpaperForScreen(screen)"))
    }

    @Test("Every other prominent call site is untouched")
    func prominentCallSitesAreUntouched() throws {
        let pinned = [
            "LiveWallpaper/Monitor/Board/EditChrome.swift": "prominence: isOpen ? .prominent : .regular,",
            "LiveWallpaper/Views/MenuBarContent.swift": ".adaptiveGlassButton(.prominent)",
            "LiveWallpaper/Views/Schemes/SchemeCapturePopover.swift": ".adaptiveGlassButton(.prominent, size: .small)",
        ]
        for (path, fragment) in pinned {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains(fragment), "\(path) no longer contains \(fragment)")
        }
    }
}
