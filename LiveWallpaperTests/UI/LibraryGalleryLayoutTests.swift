import AppKit
import Foundation
@testable import LiveWallpaper
import SwiftUI
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
        "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift",
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
            let grids = source.components(separatedBy: "LibraryGalleryGrid(").count - 1
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

@MainActor
@Suite("System wallpaper tile geometry", .serialized)
struct SystemWallpaperTileGeometryTests {
    private final class SizeProbe {
        var size: CGSize?
    }

    @Test(arguments: [CGSize(width: 80, height: 80), CGSize(width: 40, height: 80), CGSize(width: 80, height: 45)])
    func loadedArtworkKeepsWideTile(size: CGSize) async throws {
        guard #available(macOS 26.0, *) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tile-aspect-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.bitmapData?.initialize(repeating: 128, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let data = try #require(bitmap.representation(using: .jpeg, properties: [:]))
        try data.write(to: url)
        let image = await SystemWallpaperThumbnails.image(for: url)
        try #require(image != nil)
        let probe = SizeProbe()
        let item = SystemWallpaperManifest.Item(id: UUID().uuidString, title: "Fixture", fileName: "fixture.mp4", addedAt: Date())
        let root = ScrollView {
            LazyVGrid(columns: [GridItem(.fixed(240))]) {
                SystemWallpaperTile(item: item, thumbnailURL: url, videoURL: nil, isInUse: false, onRemove: {})
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { probe.size = $0 }
            }
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        let measured = try #require(probe.size)
        #expect(abs(measured.width - 240) < 0.5)
        #expect(abs(measured.height - 135) < 0.5)
    }
}
