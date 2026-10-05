import AppKit
import Foundation
#if !LITE_BUILD
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
#endif
import Testing

#if !LITE_BUILD
@MainActor
@Suite("Workshop filter ribbon — control heights")
struct WorkshopRibbonLayoutTests {
    private static func height(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view.fixedSize()).fittingSize.height
    }

    @Test("Filters and Liked are filter-bar controls' height, with or without a count badge")
    func togglesAreTheControlHeight() {
        let controlHeight = DesignTokens.LibraryFilterBar.controlHeight
        for count in [0, 3] {
            let filters = Self.height(WorkshopFiltersToggle(isExpanded: .constant(false), activeFilterCount: count))
            #expect(filters == controlHeight, Comment(rawValue: "Filters with \(count) active is \(filters)pt tall"))
        }
        for isOn in [false, true] {
            let liked = Self.height(WorkshopLikedToggle(isOn: .constant(isOn)))
            #expect(liked == controlHeight, Comment(rawValue: "Liked (\(isOn)) is \(liked)pt tall"))
        }
    }

    @Test("Native menu triggers retain the full custom label size")
    func nativeMenuKeepsTheWholeTrigger() {
        for size in [CGSize(width: 22, height: 22), CGSize(width: 100, height: 28)] {
            let view = NativeMenuButton {
                Button("Name") {}
            } label: {
                Image(systemName: "ellipsis").frame(width: size.width, height: size.height)
            }
            #expect(NSHostingView(rootView: view.fixedSize()).fittingSize == size)
        }
    }

    @Test("No ribbon control is taller than the search field, so the row is its insets plus one control")
    func ribbonRowIsOneControlTall() throws {
        let suite = try TestScratch.defaultsSuite("workshop.ribbon.heights")
        defer { suite.discard() }
        let services = WorkshopServices()
        services.hasWebAPIKey = true
        let model = BrowseViewModel(services: services, defaults: suite.defaults)
        let ribbon = BrowseFilterRibbon(viewModel: model, hasWebAPIKey: true, showsLikes: .constant(false))
            .frame(width: 1040)
        let expected = DesignTokens.EditDesk.Spacing.filterRowInset + DesignTokens.LibraryFilterBar.controlHeight
            + DesignTokens.EditDesk.Spacing.filterRowToCards - DesignTokens.LibraryGrid.verticalPadding
        #expect(Self.height(ribbon) == expected)
    }
}
#endif

@Suite("Edit Desk workshop page — source contract")
struct WorkshopPageSourceTests {
    private static let root = "LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift"
    private static let home = "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift"
    private static let page = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopPage.swift"
    private static let session = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopSession.swift"
    private static let browsePane = "LiveWallpaper/Views/Workshop/BrowsePane.swift"
    private static let steamMenu = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopSteamMenu.swift"

    @Test("Lite keeps the Workshop page empty")
    func liteKeepsTheWorkshopPageEmpty() throws {
        let source = try RepositoryRoot.source(Self.root)
        #expect(source.contains("case .workshop:\n                        #if !LITE_BUILD"))
        #expect(source.contains("\n                        #else\n                        Color.clear\n                        #endif"))
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

    @Test("One toast host at the root serves every page, Settings included, and opens a toast's display")
    func theToastHostLivesAtTheRoot() throws {
        for path in [Self.home, Self.page] {
            let hosts = try RepositoryRoot.source(path).components(separatedBy: "EditDeskToastHost(").count - 1
            #expect(hosts == 0, Comment(rawValue: "\(path) mounts \(hosts) toast hosts; they would double up with the root's"))
        }
        let root = try RepositoryRoot.source(Self.root)
        #expect(root.components(separatedBy: "EditDeskToastHost(").count - 1 == 1)
        #expect(root.contains(
            ".overlay(alignment: .top) {\n            EditDeskToastHost(center: toasts, onOpenDisplay: { router?.showDetail($0) })"
        ))
    }

    @Test("The root observes every deferred ticket and announces each settled ID once")
    func rootAnnouncesDeferredApplyOutcomes() throws {
        let root = try RepositoryRoot.source(Self.root)
        #expect(root.contains(".onChange(of: deferredApplyTicketStates, initial: true)"))
        #expect(root.contains("workshopSession?.deferredApply.tickets.values"))
        #expect(root.contains("($0.id, $0.state)"))
        #expect(root.contains("announcedTickets.insert(ticket.id).inserted"))
        #expect(root.contains("DeferredApplyToasts.messages("))
        // The result names its display (clickable, replaces that display's failure) and honours the master switch.
        #expect(root.contains("screenID: ticket.target.screenID"))
        #expect(root.contains("wallpapersOn: screenManager.wallpapersGloballyEnabled"))
        #expect(root.contains(
            "message.text, style: message.style, screenID: message.screenID, persistent: message.persists,\n                    undoStepID: message.undoStepID"
        ))
        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift")
        #expect(!host.contains("announceSettledTicket"))
        #expect(!host.contains("announcedTickets"))
        #expect(!host.contains("ticketSignature"))
    }

    @Test("A setup error raised while the wizard is up stays in the wizard instead of an alert behind it")
    func setupAlertStaysBehindTheWizard() throws {
        let source = try RepositoryRoot.source(Self.page)
        #expect(source.contains("page.isShowingSetupAlert = error != nil && !page.isShowingWizard"))
    }

    @Test("The Workshop onboarding step closes the page's own item modal and leaves other steps to HomePage")
    func workshopStepClosesTheItemModal() throws {
        let source = try RepositoryRoot.source(Self.page)
        #expect(source.contains(".onChange(of: router.pendingOnboardingStep, initial: true)"))
        #expect(source.contains(
            "guard step == .workshop else { return }\n            router.pendingOnboardingStep = nil\n            presentedItemID = nil"
        ))
    }

    @Test("Showing a page guide closes the Home item modal so its shortcuts stop firing underneath")
    func homePageGuideClosesTheItemModal() throws {
        let source = try RepositoryRoot.source(Self.home)
        let block = try Self.block(in: source, from: ".onChange(of: pageGuide?.context) {", to: "\n        }")
        #expect(block.contains("if pageGuide?.context != nil {\n                presentedItemID = nil"))
    }

    @Test("Showing a page guide closes the Workshop item modal")
    func workshopPageGuideClosesTheItemModal() throws {
        let source = try RepositoryRoot.source(Self.page)
        let block = try Self.block(in: source, from: ".onChange(of: pageGuide?.context != nil)", to: "\n        }")
        #expect(block.contains("presentedItemID = nil"))
    }

    @Test("The Steam wizard disables the page under it but not itself")
    func wizardDisablesThePageBehindIt() throws {
        let source = try RepositoryRoot.source(Self.page)
        let sheets = try #require(source.range(of: ".modifier(WorkshopPageSheets(page: self))"))
        for fragment in [".disabled(isShowingWizard)", ".accessibilityHidden(isShowingWizard)"] {
            let found = try #require(source.range(of: fragment), Comment(rawValue: "WorkshopPage lacks \(fragment)"))
            #expect(
                found.lowerBound < sheets.lowerBound,
                Comment(rawValue: "\(fragment) wraps the wizard overlay too, so the wizard itself is disabled")
            )
        }
    }

    @Test("A Likes modal keeps its opening snapshot while details load, so an unlike cannot orphan it")
    func likesModalKeepsItsSnapshot() throws {
        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModalHost.swift")
        let body = try Self.block(in: host, from: "private func open() async {", to: "\n    }\n")
        #expect(body.contains("detachedItem = refreshDetailsOnOpen ? fallback : nil"))
    }

    private static func block(in source: String, from start: String, to end: String) throws -> Substring {
        let head = try #require(source.range(of: start), Comment(rawValue: "missing \(start)"))
        let tail = try #require(source.range(of: end, range: head.upperBound ..< source.endIndex))
        return source[head.upperBound ..< tail.lowerBound]
    }

    @Test("The Steam menu offers SteamCMD setup only until SteamCMD is ready")
    func steamMenuOffersSetupOnlyUntilReady() throws {
        let menu = try RepositoryRoot.source(Self.steamMenu)
        let gate = try #require(menu.range(of: "if !steamCMDReady {"))
        let end = try #require(menu.range(of: "\n            }", range: gate.upperBound ..< menu.endIndex))
        let gated = menu[gate.upperBound ..< end.lowerBound]
        #expect(gated.contains(#"Button("Set up SteamCMD", action: onInstallSteamCMD)"#))
        #expect(gated.contains(#"Button("Locate automatically", action: onLocateSteamCMD)"#))
        #expect(
            menu.components(separatedBy: "Set up SteamCMD").count == 2,
            "an ungated copy would reinstall a SteamCMD that already works"
        )
        let page = try RepositoryRoot.source(Self.page)
        #expect(page.contains("steamCMDReady: doctor.isBinaryPresumedReady"))
        #expect(page.contains("onLocateSteamCMD: { setupController.autoDetectBinary() }"))
    }

    @Test("While SteamCMD installs, uninstalls or is being located, both setup rows wait")
    func steamMenuHoldsSetupWhileSteamCMDIsBusy() throws {
        let menu = try RepositoryRoot.source(Self.steamMenu)
        let gate = try #require(menu.range(of: "if !steamCMDReady {"))
        let end = try #require(menu.range(of: "\n            }", range: gate.upperBound ..< menu.endIndex))
        let lines = menu[gate.upperBound ..< end.lowerBound].split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for row in [#"Button("Set up SteamCMD", action: onInstallSteamCMD)"#, #"Button("Locate automatically", action: onLocateSteamCMD)"#] {
            let index = try #require(lines.firstIndex(of: row))
            #expect(
                lines.indices.contains(index + 1) && lines[index + 1] == ".disabled(steamCMDBusy)",
                "a locate that finishes mid-install reports SteamCMD missing although the install then succeeds"
            )
        }
        let page = try RepositoryRoot.source(Self.page)
        #expect(page.contains("steamCMDBusy: setupController.isSteamCMDBusy"))
    }

    @Test("The Steam menu always offers a local-folder import, ready or not")
    func steamMenuAlwaysOffersALocalFolderImport() throws {
        let menu = try RepositoryRoot.source(Self.steamMenu)
        let row = try #require(menu.range(of: #"Button("Import a Local Folder", action: onImportLocalFolder)"#))
        let gate = try #require(menu.range(of: "if !steamCMDReady {"))
        let end = try #require(menu.range(of: "\n            }", range: gate.upperBound ..< menu.endIndex))
        #expect(
            !(gate.lowerBound ..< end.upperBound).contains(row.lowerBound),
            "gated on SteamCMD the row would vanish for anyone who is set up"
        )
        let page = try RepositoryRoot.source(Self.page)
        #expect(page.contains("onImportLocalFolder: { SteamWizard.importLocalFolder() }"))
    }

    @Test("Browse is the grid alone, with no inspector column")
    func browsePaneHasNoInspector() throws {
        let source = try RepositoryRoot.source(Self.browsePane)
        #expect(!source.contains("InspectorSplit("), "Browse builds an inspector column again")
        for fragment in [
            "BrowseFilterRibbon(", "paginationBar", "rateLimitBanner", "keyRejectedBanner",
            "installedWorkshopIDs", "hidesDownloadedPref", "loadingSkeleton",
        ] {
            #expect(source.contains(fragment), Comment(rawValue: "BrowsePane lost \(fragment)"))
        }
    }

}
