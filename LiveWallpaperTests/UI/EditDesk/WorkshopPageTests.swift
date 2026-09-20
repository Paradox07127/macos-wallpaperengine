import Foundation
import Testing

@Suite("Edit Desk workshop page — source contract")
struct WorkshopPageSourceTests {
    private static let root = "LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift"
    private static let home = "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift"
    private static let page = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopPage.swift"
    private static let session = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopSession.swift"
    private static let browsePane = "LiveWallpaper/Views/Workshop/BrowsePane.swift"

    @Test("The root routes Workshop to the new page, not the old pane")
    func rootDropsThePaneView() throws {
        let source = try RepositoryRoot.source(Self.root)
        #expect(!source.contains("PaneView()"), "EditDeskRoot still renders the old Workshop shell")
        #expect(source.contains("WorkshopPage("))
    }

    @Test("Lite keeps the Workshop page empty")
    func liteKeepsTheWorkshopPageEmpty() throws {
        let source = try RepositoryRoot.source(Self.root)
        #expect(source.contains("case .workshop:\n                    #if !LITE_BUILD"))
        #expect(source.contains("\n                    #else\n                    Color.clear\n                    #endif"))
    }

    @Test("The session and the toast centre are owned by the root, not by a page")
    func rootOwnsTheLongLivedState() throws {
        let root = try RepositoryRoot.source(Self.root)
        #expect(root.contains("@State private var workshopSession: WorkshopSession?"))
        #expect(root.contains("@State private var toasts = EditDeskToastCenter()"))
        let home = try RepositoryRoot.source(Self.home)
        #expect(
            !home.contains("@State private var toasts"),
            "HomePage still builds its own toast centre, so a page switch would drop queued toasts"
        )
        #expect(home.contains("let toasts: EditDeskToastCenter"))
    }

    @Test("Exactly one toast host is mounted per page and none at the root")
    func oneToastHostPerPage() throws {
        for path in [Self.home, Self.page] {
            let hosts = try RepositoryRoot.source(path).components(separatedBy: "EditDeskToastHost(").count - 1
            #expect(hosts == 1, Comment(rawValue: "\(path) mounts \(hosts) toast hosts"))
        }
        let root = try RepositoryRoot.source(Self.root)
        #expect(!root.contains("EditDeskToastHost("), "a root host would double up with the page's own")
    }

    @Test("The page reuses the shell top bar and asks Browse for the Edit Desk layout")
    func pageUsesTheSharedChrome() throws {
        let source = try RepositoryRoot.source(Self.page)
        #expect(source.contains("TopBar("))
        #expect(source.contains("presentation: .editDesk"))
        #expect(!source.contains("LibrarySearchField("), "the ribbon carries the only Workshop search field")
        #expect(!source.contains("InspectorSplit"), "the Edit Desk workshop page has no inspector column")
    }

    @Test("Browse branches on presentation only where the inspector split is built")
    func browsePaneBranchesInTheLayoutLayer() throws {
        let source = try RepositoryRoot.source(Self.browsePane)
        #expect(source.contains("if presentation == .editDesk"))
        let splits = source.components(separatedBy: "InspectorSplit(").count - 1
        #expect(splits == 1, "the split is built once, in the legacy branch")
        // The pieces R-21 keeps identical across both presentations.
        for fragment in [
            "BrowseFilterRibbon(", "paginationBar", "rateLimitBanner", "keyRejectedBanner",
            "installedWorkshopIDs", "hidesDownloadedPref", "loadingSkeleton",
        ] {
            #expect(source.contains(fragment), Comment(rawValue: "BrowsePane lost \(fragment)"))
        }
    }

    @Test("The workshop grid and its skeleton share one column preset")
    func gridAndSkeletonShareTheColumnPreset() throws {
        let source = try RepositoryRoot.source(Self.browsePane)
        let uses = source.components(separatedBy: "columnWidth: gridColumnWidth").count - 1
        #expect(uses == 2, "the real grid and the skeleton must ask for the same width")
    }

    @Test("No token-bypass literals in the files this package owns")
    func noTokenBypassLiterals() throws {
        for path in [Self.page, Self.session, "LiveWallpaper/Views/EditDesk/Workshop/WorkshopSteamMenu.swift"] {
            let source = try RepositoryRoot.source(path)
            #expect(!source.contains(".font(.system("), "\(path) has an inline .font(.system( literal")
            #expect(!source.contains("Color(red:"), "\(path) has a literal Color(red:")
            #expect(
                source.range(of: #"cornerRadius:\s*[0-9]"#, options: .regularExpression) == nil,
                "\(path) has a literal cornerRadius"
            )
        }
    }
}
