import Foundation
import Testing

@Suite("Library gallery layout")
struct LibraryGalleryLayoutTests {
    /// The pages whose tiles are 16:9 wallpaper stills.
    private static let widePages = [
        "LiveWallpaper/Views/Bookmarks/LibraryView.swift",
        "LiveWallpaper/Views/Schemes/SchemeLibraryView.swift",
        "LiveWallpaper/Views/Aerials/AerialsLibraryView.swift",
        "LiveWallpaper/Views/SystemWallpaper/SystemWallpaperLibraryView.swift",
        "LiveWallpaper/Views/SystemWallpaper/SystemWallpaperAddSheet.swift",
    ]

    /// The pages whose tiles are square.
    private static let squarePages = [
        "LiveWallpaper/Views/Workshop/InstalledView.swift",
    ]

    @Test("Wallpaper pages draw the wide ladder, Workshop the square one")
    func pagesDrawTheLadderTheirTileShapeNeeds() throws {
        // Bound to `Bool` first: `#expect` on `contains` renders the whole file on failure.
        for path in Self.widePages {
            let source = try RepositoryRoot.source(path)
            let usesWide = source.contains("aspect: .wide")
            let usesSquare = source.contains("aspect: .square")
            #expect(usesWide, Comment(rawValue: "\(path) is not on the wide ladder"))
            #expect(!usesSquare, Comment(rawValue: "\(path) mixes in square columns"))
        }
        for path in Self.squarePages {
            let source = try RepositoryRoot.source(path)
            let usesSquare = source.contains("aspect: .square")
            let usesWide = source.contains("aspect: .wide")
            #expect(usesSquare, Comment(rawValue: "\(path) is not on the square ladder"))
            #expect(!usesWide, Comment(rawValue: "\(path) mixes in wide columns"))
        }
    }

    @Test("Every library grid takes the shared inset")
    func everyLibraryGridTakesTheSharedInset() throws {
        for path in Self.widePages + Self.squarePages {
            let source = try RepositoryRoot.source(path)
            let grids = source.components(separatedBy: "LazyVGrid(").count - 1
            let insets = source.components(separatedBy: ".libraryGridPadding()").count - 1
            #expect(
                grids > 0 && grids == insets,
                Comment(rawValue: "\(path): \(grids) grid(s) but \(insets) libraryGridPadding() call(s)")
            )
        }
    }

    @Test("Library pages state their size at the foot of the page")
    func libraryPagesStateTheirSizeAtTheFoot() throws {
        // The add sheet is the exception: it has a footer bar of its own.
        let paged = (Self.widePages + Self.squarePages)
            .filter { !$0.hasSuffix("SystemWallpaperAddSheet.swift") }
        for path in paged {
            let hasStatusBar = try RepositoryRoot.source(path).contains("LibraryStatusBar(")
            #expect(hasStatusBar, Comment(rawValue: "\(path) has no status bar"))
        }
    }
}
