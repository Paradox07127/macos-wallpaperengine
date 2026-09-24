import Foundation
import Testing

/// SCREENS.md S6 repaints two Edit Desk detail icon buttons — the HUD's transport primary and the
/// top bar's 🗑 — without touching any other `GlassIconButton` call site.
@Suite("Edit Desk detail icon buttons — source contract")
struct DetailIconButtonSourceTests {
    private static let hudPath = "LiveWallpaper/Views/EditDesk/Detail/DetailHero.swift"
    private static let topBarPath = "LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift"
    private static let componentPath =
        "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/GlassIconButton.swift"

    @Test("Transport uses the shared system glass button without a second capsule")
    func hudPrimaryUsesSystemGlass() throws {
        let source = try RepositoryRoot.source(Self.hudPath)
        #expect(source.contains("GlassIconButton(status.intendsToPlay"))
        #expect(!source.contains("flatFill:"))
        #expect(!source.contains("adaptiveGlassSurface(.capsule"))
    }

    @Test("Toolbar actions use the same system glass button and label destructive actions")
    func toolbarUsesSystemGlass() throws {
        let source = try RepositoryRoot.source(Self.topBarPath)
        #expect(source.contains("GlassIconButton"))
        #expect(!source.contains("flatFill:"))
        #expect(source.contains("role: .destructive"))
        #expect(source.contains("accessibilityLabel(Text(\"Clear Wallpaper\"))"))
    }

    @Test("Only those two call sites opt into the flat variant")
    func flatFillIsNotUsedElsewhere() throws {
        let owned = Set([Self.hudPath, Self.topBarPath, Self.componentPath])
        for directory in ["LiveWallpaper", "Packages"] {
            for file in RepositoryRoot.swiftFiles(under: directory) {
                let path = RepositoryRoot.relativePath(of: file)
                guard !owned.contains(path) else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                #expect(!source.contains("flatFill:"), "\(path) also opted into the flat variant")
            }
        }
    }

    @Test("Every other prominent call site is untouched")
    func prominentCallSitesAreUntouched() throws {
        let pinned = [
            "LiveWallpaper/Monitor/Board/EditChrome.swift": "prominence: isOpen ? .prominent : .regular,",
            "LiveWallpaper/Views/ScreenDetail/Header.swift": "prominence: isCurrentBookmarked ? .prominent : .regular",
            "LiveWallpaper/Views/MenuBarContent.swift": ".adaptiveGlassButton(.prominent)",
            "LiveWallpaper/Views/Schedule/TimeEditorPopover.swift": ".adaptiveGlassButton(.prominent)",
            "LiveWallpaper/Views/Schemes/SchemeCapturePopover.swift": ".adaptiveGlassButton(.prominent, size: .small)",
            "LiveWallpaper/Views/Bookmarks/Popover.swift": ".adaptiveGlassButton(.prominent, size: .small)",
            "LiveWallpaper/Views/ScreenDetail/VideoPreviewSection.swift": ".adaptiveGlassButton(.prominent, size: .large)",
        ]
        for (path, fragment) in pinned {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains(fragment), "\(path) no longer contains \(fragment)")
        }
    }

    @Test("The flat variant is opt-in, so untouched call sites keep the glass tiers")
    func flatFillDefaultsToNil() throws {
        let source = try RepositoryRoot.source(Self.componentPath)
        #expect(source.contains("flatFill: FlatFill? = nil"))
    }
}
