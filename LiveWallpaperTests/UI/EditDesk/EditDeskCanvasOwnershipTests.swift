import Foundation
import Testing

/// Who may paint behind an Edit Desk page: the window root owns the canvas; pages go through
/// `.pageBackground()`, and only the content columns listed here stay solid.
@Suite("Edit Desk canvas ownership — source contract")
struct EditDeskCanvasOwnershipTests {
    private static let canvasOwner = "LiveWallpaper/Views/EditDesk/Shell/EditDeskBackdrop.swift"

    /// Views/EditDesk files that paint a page colour themselves: the canvas, the modal panel, and the
    /// pages that still cover the overview with their own fill.
    private static let paintsPageColour: Set<String> = [
        canvasOwner,
        "LiveWallpaper/Views/EditDesk/Library/EditDeskModalChrome.swift",
        "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift",
        "LiveWallpaper/Views/EditDesk/Detail/DisplayDetail.swift",
        "LiveWallpaper/Views/EditDesk/Detail/EmptyDisplaySetup.swift",
    ]

    /// The solid content columns: the settings page's right-hand side.
    private static let contentColumns: Set<String> = [
        "LiveWallpaper/Views/Settings/DetailContent.swift",
        "LiveWallpaper/Views/Settings/GeneralSettingsView.swift",
        "LiveWallpaper/Views/Settings/AboutTab.swift",
        "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/SettingsFormChrome.swift",
    ]

    /// Pages the Edit Desk embeds that paint through `.pageBackground()`.
    private static let pages = [
        "Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/DetailPageScaffold.swift",
        "LiveWallpaper/Views/Settings/Sidebar.swift",
        "LiveWallpaper/Views/Workshop/BrowsePane.swift",
    ]

    private static let pageColours = ["EditDesk.Colors.background", "Colors.pageBackground", "windowBackgroundColor"]

    private static func files(containing needle: String, under directories: [String]) throws -> Set<String> {
        var found: Set<String> = []
        for directory in directories {
            let files = RepositoryRoot.swiftFiles(under: directory)
            #expect(!files.isEmpty, "no Swift files under \(directory): the scan is misconfigured")
            for file in files where try String(contentsOf: file, encoding: .utf8).contains(needle) {
                found.insert(RepositoryRoot.relativePath(of: file))
            }
        }
        return found
    }

    @Test("Only the root reads the main-window background setting; the settings row writes it")
    func onlyTheRootReadsTheBackgroundSetting() throws {
        let readers = try Self.files(containing: "EditDeskPreferences.background", under: ["LiveWallpaper"])
        #expect(readers == [
            "LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift",
            "LiveWallpaper/Views/Settings/ShelfSettingsRows.swift",
        ], "a second view reads the setting and can paint a canvas of its own: \(readers.sorted())")
    }

    @Test("The root paints one canvas under every page and tells the pages so")
    func theRootPaintsTheCanvasForEveryPage() throws {
        let root = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift")
        #expect(root.components(separatedBy: "EditDeskBackdrop(frosted:").count == 2, "the canvas is not painted exactly once")
        #expect(root.contains(".environment(\\.windowPaintsCanvas, true)"), "pages under the root still paint their own background")
        for colour in Self.pageColours {
            #expect(!root.contains(colour), "the root paints \(colour) under one page instead of the canvas")
        }
    }

    @Test("The canvas falls back to the flat fill under Reduce Transparency and Increase Contrast")
    func theCanvasFallsBackForAccessibility() throws {
        let backdrop = try RepositoryRoot.source(Self.canvasOwner)
        #expect(backdrop.contains("accessibilityReduceTransparency"))
        #expect(backdrop.contains("colorSchemeContrast"))
        #expect(backdrop.contains("if frosted, !reduceTransparency, contrast != .increased"), "the blur is not gated on both settings")
    }

    @Test("Under Views/EditDesk only the listed files paint a page colour, and only the canvas blurs")
    func onlyListedFilesPaintAPageColour() throws {
        var painters: Set<String> = []
        for colour in Self.pageColours {
            try painters.formUnion(Self.files(containing: colour, under: ["LiveWallpaper/Views/EditDesk"]))
        }
        #expect(painters.isSubset(of: Self.paintsPageColour), "unlisted page fills: \(painters.subtracting(Self.paintsPageColour).sorted())")
        let blurs = try Self.files(containing: "NSVisualEffectView", under: ["LiveWallpaper/Views/EditDesk"])
        #expect(blurs == [Self.canvasOwner], "a second blur cannot cover what lies under it in the window: \(blurs.sorted())")
    }

    @Test("Solid content columns are exactly the listed call sites")
    func contentColumnsAreListed() throws {
        let callers = try Self.files(
            containing: ".contentColumnBackground()",
            under: ["LiveWallpaper", "Packages/LiveWallpaperCore/Sources"]
        )
        #expect(callers == Self.contentColumns, "content columns drifted: \(callers.sorted())")
    }

    @Test("Embedded pages paint through pageBackground, not a colour of their own")
    func pagesGoThroughPageBackground() throws {
        for path in Self.pages {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains(".pageBackground()"), "\(path) does not paint through pageBackground()")
            for colour in Self.pageColours {
                #expect(!source.contains(colour), "\(path) paints \(colour) directly")
            }
        }
    }
}
