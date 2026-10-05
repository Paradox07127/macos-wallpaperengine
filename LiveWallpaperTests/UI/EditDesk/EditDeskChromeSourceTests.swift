import Foundation
import Testing

@Suite("Edit Desk home chrome — source contract")
struct EditDeskChromeSourceTests {

    @Test("The status panel closes on an outside click, on Escape and when the app deactivates")
    func statusPanelCarriesEveryDismissalPath() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/StatusCapsule.swift")
        #expect(source.contains("NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])"))
        #expect(source.contains("return event"), "a swallowed click would cost the user a second one")
        #expect(source.contains("NSEvent.removeMonitor"))
        #expect(source.contains("NSApplication.didResignActiveNotification"))
        #expect(source.contains("NSWindow.didResignKeyNotification"))
        #expect(source.contains(".onKeyPress(.escape)"))
        #expect(!source.contains(".popover("), "NSPopover imposes a system arrow and shadow on a hand-drawn panel")
        #expect(!source.contains("onTapGesture"), "the trigger is a Button, so it is keyboard reachable")
        #expect(
            source.contains("Button(action: collapse)"),
            "the open panel covers its own trigger, so its headline has to carry the way back"
        )
    }

    @Test("The nav pill routes through the router instead of writing the page directly")
    func navPillGoesThroughSelect() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("Binding(get: { router.page }, set: { router.select($0) })"))
        #expect(source.contains("page: pageBinding,"))
        #expect(!source.contains("page: $router.page"), "a direct binding skips previousPage and the Workshop check")
    }

    @Test("Drops are applied off the stage's event loop")
    func dropsDoNotBlockTheEventLoop() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("applies.run(for: displayID) { await applyCard(cardID, to: displayID, cancellation: $0) }"))
        #expect(!source.contains("await applyCard(cardID, to: displayID, cancellation: $0)\n            case"))
    }

    @Test("An ⌥-click on a grid tile and the stage's apply request go through one quick-apply helper")
    func gridOptionClickSharesTheQuickApply() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        let start = try #require(source.range(of: "private var wallpaperGrid: some View {"))
        let grid = try #require(String(source[start.lowerBound...]).components(separatedBy: "\n    }\n").first)
        #expect(grid.contains("NSApp.currentEvent?.modifierFlags.contains(.option) == true"), "a grid tile ignores ⌥")
        #expect(grid.contains("NSApp.currentEvent?.type == .leftMouseUp"), "a VoiceOver press, whose VO key holds ⌥, applies the tile")
        #expect(grid.contains("quickApply(item.id)"), "an ⌥-click on a grid tile applies on a path of its own")
        #expect(
            grid.contains(#".accessibilityAction(named: Text("Apply")) { quickApply(item.id) }"#),
            "a grid tile offers VoiceOver no Apply, which a shelf card does"
        )
        let request = try #require(source.range(of: "case let .cardApplyRequested(cardID):"))
        let branch = try #require(String(source[request.upperBound...]).components(separatedBy: "\n            case ").first)
        #expect(branch.contains("quickApply(cardID)"), "the stage's apply request picks its display on its own")
    }

    @Test("The stage's previous-track action reaches the playlist coordinator")
    func previousTrackIsWired() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("screenManager.regressPlaylist(for: screen)"))
    }

    @Test("The menu bar's add-wallpaper request is consumed once and leaves the panorama in place")
    func addWallpaperRequestIsConsumedOnce() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains(
            ".onChange(of: router.pendingAddWallpaper, initial: true) { consumeAddWallpaperRequest() }"
        ))
        let start = try #require(source.range(of: "private func consumeAddWallpaperRequest()"))
        // Cut at the function's own closing brace: the next function opens a picker on the main
        // display, and reading it as part of this one would pass the fallback assertion below.
        let body = try #require(String(source[start.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(body.contains("router.pendingAddWallpaper = nil"))
        #expect(body.contains("router.closeDetail()"))
        #expect(body.contains("presentedItemID = nil"))
        #expect(!body.contains("router.showDetail"), "an add request must not open a display detail")
        #expect(!body.contains("CGDisplayIsMain"), "a vanished target must not silently become the main display")
    }

    @Test("The wallpaper library's import entries, a drop on the shelf among them, only add to the library")
    func libraryImportEntriesOnlyAdd() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("onImport: promptLibraryImport"), "the row's + still applies the file to a display")
        let panel = try #require(source.range(of: "private func promptLibraryImport()"))
        let panelBody = try #require(String(source[panel.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(panelBody.contains("importToLibrary(panel.urls)"), "the panel and the shelf import on two separate paths")
        #expect(!panelBody.contains("promptImport("))
        #expect(!panelBody.contains("applies.run"))
        let importer = try #require(source.range(of: "private func importToLibrary(_ urls:"))
        let importBody = try #require(String(source[importer.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(importBody.contains("LibraryImporter(") && importBody.contains(".add(urls)"))
        #expect(!importBody.contains("applies.run"), "adding to the library must not apply to a display")
        let drop = try #require(source.range(of: "case let .filesDroppedOnShelf(urls):"), "a drop on the shelf is ignored")
        let branch = try #require(String(source[drop.upperBound...]).components(separatedBy: "\n            case ").first)
        #expect(branch.contains("importToLibrary(urls)"), "a drop on the shelf never joins the library")
        #expect(!branch.contains("applies.run"), "a drop on the shelf applies the files to a display")
        let treeStart = try #require(source.range(of: "        ZStack(alignment: .top) {"))
        let tree = try #require(String(source[treeStart.lowerBound...]).components(separatedBy: "\n        }").first)
        let stage = try #require(tree.range(of: "EditDeskStageRepresentable(model: stage)"))
        let highlight = try #require(tree.range(of: "ShelfDropHighlight(stage: stage)"), "the shelf band never lights for a drop")
        #expect(stage.upperBound <= highlight.lowerBound, "declared under the stage, the band's light hides behind the cards")
    }

    @Test("Orphan covers are swept once, when the window builds the library model, sparing those undo can bring back")
    func libraryModelSweepsCoversOnce() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift")
        #expect(source.contains("let library = SavedLibraryModel(screenManager: screenManager)"))
        #expect(source.contains("library.prepareLibrary(alsoKeeping: undo.retainedCoverFileNames)"))
        #expect(
            source.components(separatedBy: "prepareLibrary(").count - 1 == 1,
            "the cover sweep must not run again on every library rebuild"
        )
        let homeSweeps = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift").contains("prepareLibrary(")
        #expect(!homeSweeps, "the sweep would run again each time a page switch remounts HomePage")
    }

    @Test("The library's delete confirmation and rename alert have one presenter, which finds the entry by the ID it opened for")
    func libraryItemDialogsHaveOnePresenter() throws {
        // ← → keep paging the modal under a dialog, so a dialog the modal presented would act on the entry shown by then.
        var presenters: [String: [String]] = [:]
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for modifier in [".wallpaperDeleteConfirmation(", ".wallpaperRenameAlert("] {
                let count = source.components(separatedBy: modifier).count - 1
                presenters[modifier, default: []] += Array(repeating: RepositoryRoot.relativePath(of: file), count: count)
            }
        }
        let home = "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift"
        #expect(presenters[".wallpaperDeleteConfirmation("] == [home])
        #expect(presenters[".wallpaperRenameAlert("] == [home])
        let source = try RepositoryRoot.source(home)
        let start = try #require(source.range(of: "private struct LibraryItemCommands: ViewModifier {"))
        let commands = try #require(source[start.upperBound...].components(separatedBy: "\n    }\n").first)
        #expect(!commands.contains("_ in"), "a dialog action that drops its ID acts on whichever entry is current")
    }

    @Test("Leaving the wallpaper library clears its search")
    func leavingTheLibraryClearsItsSearch() throws {
        // Bound to `Bool` first: `#expect` on `contains` renders the whole file on failure.
        let clears = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
            .contains("page.library?.query = \"\"")
        #expect(clears, "a search typed in the library keeps filtering the shelf, where no field shows it")
    }

    @Test("The per-frame shelf chrome reads progress in its own view, not in HomePage's body")
    func shelfChromeOwnsItsProgressDependency() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        // Only the view tree: the modifiers below it read `stage.progress` inside closures, which
        // run on their own events rather than while the body is being evaluated.
        let start = try #require(source.range(of: "        ZStack(alignment: .top) {"))
        let tree = try #require(String(source[start.lowerBound...]).components(separatedBy: "\n        }").first)
        #expect(!tree.contains("stage.progress"), "a progress read here re-runs the whole page every frame")
        #expect(tree.contains("EditDeskShelfScrim(stage: stage)"))
        #expect(tree.contains("HomeHints(stage: stage)"))
        let chrome = try #require(source.range(of: "private var shelfChrome: some View"))
        let chromeBody = try #require(String(source[chrome.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(chromeBody.contains("chipsRow"))
        #expect(chromeBody.contains(".modifier(ShelfChromeRide(stage: stage))"))
        #expect(!chromeBody.contains("stage.progress"))
    }

    @Test("Aerials are matched by the file their bookmark resolves to, never by the bookmark's bytes")
    func aerialsAreNeverMatchedByBookmarkBytes() throws {
        // Every scan bookmarks each file anew; `SavedLibraryModel.aerial(_:matches:)` is the one comparison.
        let helper = "LiveWallpaper/Views/EditDesk/Library/SavedLibraryModel.swift"
        var offenders: [String] = []
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views") {
            let path = RepositoryRoot.relativePath(of: file)
            let source = try String(contentsOf: file, encoding: .utf8)
            if path != helper, source.contains("asset.bookmarkData ==") || source.contains("== asset.bookmarkData") {
                offenders.append(path)
            }
        }
        #expect(offenders.isEmpty, "an aerial matched by bookmark bytes: \(offenders.joined(separator: "; "))")
    }

    @Test("The display link is rebuilt when the window moves to another screen")
    func displayLinkFollowsTheWindow() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Stage/EditDeskStageView.swift")
        #expect(source.contains("NSWindow.didChangeScreenNotification"))
        #expect(source.contains("self.stopDisplayLink()\n                    self.startDisplayLinkIfNeeded()"))
        #expect(source.contains("screenObserver.map(NotificationCenter.default.removeObserver)"))
    }

}
