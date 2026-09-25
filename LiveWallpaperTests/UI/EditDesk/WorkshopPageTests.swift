import Foundation
import Testing

@Suite("Edit Desk workshop page — source contract")
struct WorkshopPageSourceTests {
    private static let root = "LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift"
    private static let home = "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift"
    private static let page = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopPage.swift"
    private static let session = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopSession.swift"
    private static let browsePane = "LiveWallpaper/Views/Workshop/BrowsePane.swift"
    private static let steamMenu = "LiveWallpaper/Views/EditDesk/Workshop/WorkshopSteamMenu.swift"

    @Test("The root routes Workshop to the new page, not the old pane")
    func rootDropsThePaneView() throws {
        let source = try RepositoryRoot.source(Self.root)
        #expect(!source.contains("PaneView()"), "EditDeskRoot still renders the old Workshop shell")
        #expect(source.contains("WorkshopPage("))
    }

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
        #expect(root.contains("EditDeskToastHost(center: toasts, onOpenDisplay: { router?.showDetail($0) })"))
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
