import Foundation
import Testing

@Suite("Edit Desk home chrome — source contract")
struct EditDeskChromeSourceTests {
    private static let ownedFiles = [
        "LiveWallpaper/Views/EditDesk/Shell/NavPill.swift",
        "LiveWallpaper/Views/EditDesk/Shell/StatusCapsule.swift",
        "LiveWallpaper/Views/EditDesk/Shell/TopBar.swift",
        "LiveWallpaper/Views/EditDesk/Shell/EditDeskToastCenter.swift",
        "LiveWallpaper/Views/EditDesk/Shell/HomeHints.swift",
        "LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift",
        "LiveWallpaper/Views/EditDesk/Shell/SchemesPage.swift",
        "LiveWallpaper/Views/EditDesk/Shell/SystemWallpaperPage.swift",
    ]

    @Test("NavPill builds on GlassSegmentedPicker's editDesk shell, and the library carries no second pill")
    func navPillUsesEditDeskShellAlone() throws {
        let path = "LiveWallpaper/Views/EditDesk/Shell/NavPill.swift"
        let source = try RepositoryRoot.source(path)
        #expect(source.contains("GlassSegmentedPicker("), "\(path) does not build on GlassSegmentedPicker")
        #expect(source.contains("shell: .editDesk"), "\(path) does not request the editDesk shell")
        let pickers = try RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views").filter { file in
            try String(contentsOf: file, encoding: .utf8).contains("LibrarySegmentPicker")
        }
        #expect(pickers.isEmpty, "the library still opens a second pill: \(pickers.map { RepositoryRoot.relativePath(of: $0) })")
    }

    @Test("The library page is the wallpaper grid alone; Schemes and System Wallpaper mount as pages of their own")
    func schemesAndSystemWallpaperArePages() throws {
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(!home.contains("SchemeLibraryView("), "HomePage still embeds the scheme library")
        #expect(!home.contains("SystemWallpaperLibraryView("), "HomePage still embeds the System Wallpaper library")
        let root = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift")
        #expect(root.contains("SchemesPage(router: router, toasts: toasts)"))
        #expect(root.contains("SystemWallpaperPage(router: router)"))
    }

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

    @Test("The performance-settings shortcut is gone from the status panel and from its caller")
    func performanceSettingsShortcutIsRemoved() throws {
        let capsule = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/StatusCapsule.swift")
        #expect(!capsule.contains("Performance Settings"))
        #expect(!capsule.contains("onOpenPerformanceSettings"))
        #expect(capsule.contains("Displays Rendering"), "the footer's remaining line stays")
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(!home.contains("onOpenPerformanceSettings"))
    }

    @Test("The library chips row is built from FilterChip")
    func chipsRowUsesFilterChip() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift")
        #expect(source.contains("FilterChip("))
    }

    @Test("The library's search field is LibrarySearchField in the filter row, ahead of sort and import, and the top bar has none")
    func filterRowCarriesTheSearchField() throws {
        let row = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift")
        let search = try #require(row.range(of: "LibrarySearchField("), "the filter row has no search field")
        let sort = try #require(row.range(of: "\n            sortControl\n"))
        #expect(search.upperBound <= sort.lowerBound, "the search field sits after sort and import")
        #expect(row.contains(".modifier(LibrarySearchReveal(stage: stage))"), "the field does not ride the rise to the library")
        let bar = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/TopBar.swift")
        #expect(!bar.contains("LibrarySearchField("), "the top bar still carries a search field")
    }

    @Test("The Edit Desk controls moved onto Liquid Glass stay on it, with one prominent button per view")
    func glassControlsFollowTheContract() throws {
        /// A member's body, cut at its own closing brace.
        func member(_ source: String, _ signature: String) throws -> String {
            let start = try #require(source.range(of: signature), Comment(rawValue: "no \(signature)"))
            return try #require(String(source[start.lowerBound...]).components(separatedBy: "\n    }").first)
        }
        let row = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/LibraryChipsRow.swift")
        #expect(row.contains(#"GlassIconButton("plus", size: .regular, action: onImport)"#))
        #expect(row.contains(#".accessibilityLabel(Text("Add to Library"))"#))
        #expect(row.contains(".adaptiveGlassButton(.regular, shape: .capsule, size: .regular)"))
        #expect(row.contains(".appLanguagePopover(isPresented: $sortPresented, arrowEdge: .bottom) { sortMenu }"))
        #expect(row.contains(".onChange(of: stage.snappedIndex) { sortPresented = false }"), "the popover outlives a swipe")
        #expect(row.contains(".settingsPopoverChrome(width: 200)"))
        #expect(!row.contains("Menu {"), "a Menu cannot take glass")
        #expect(!row.contains("\"+ Import\""))

        let status = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/StatusCapsule.swift")
        let collapsed = try member(status, "private var collapsedCapsule: some View {")
        #expect(collapsed.contains(".adaptiveGlassSurface(.capsule, interactive: true)"))
        #expect(collapsed.contains(".buttonStyle(.plain)"))
        #expect(!collapsed.contains("Capsule().fill("), "a flat fill under the glass hides it")
        #expect(!collapsed.contains("strokeBorder("))

        let onboarding = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Onboarding/OnboardingCapsule.swift")
        let capsule = try member(onboarding, "private func capsule(_ dots: [Bool]) -> some View {")
        #expect(capsule.contains(".adaptiveGlassSurface(.capsule, interactive: true)"))
        #expect(!capsule.contains("Capsule().fill("), "a flat fill under the glass hides it")
        #expect(!capsule.contains("strokePanel"), "only the hover edge stays")
        #expect(onboarding.contains(".buttonStyle(OnboardingPressStyle())"))

        let float = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/DisplayFloatLayer.swift")
        let applyAll = try member(float, "private var applyAllTile: some View {")
        #expect(applyAll.contains(".adaptiveGlassSurface(.roundedRectangle(DesignTokens.EditDesk.Corner.gridCard))"))
        #expect(!applyAll.contains("fillFloatButton"))

        let detail = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DetailTopBar.swift")
        let glass = try RepositoryRoot.source("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/AdaptiveGlass.swift")
        #expect(detail.contains(".adaptiveGlassSurface(.capsule)"))
        #expect(!detail.contains("preferMaterial"), "the section picker is forced back onto material")
        #expect(!glass.contains("preferMaterial"))

        let modal = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/WallpaperModal.swift")
        #expect(modal.contains("applyButton(primary).adaptiveGlassButton(.prominent, size: .large)"))
        #expect(modal.contains("applyButton(target).adaptiveGlassButton(.regular, size: .large)"))
        #expect(!modal.contains(".tint(target.isPrimary"))

        let workshop = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Workshop/WorkshopModal.swift")
        #expect(workshop.components(separatedBy: ".adaptiveGlassButton(.regular, size: .large)").count - 1 == 3)
        #expect(workshop.contains(#"GlassIconButton("arrow.up.forward.app", size: .regular, action: actions.openInSteam)"#))
        #expect(!workshop.contains("WorkshopBarButton"))
        #expect(!workshop.contains("Opacity.dimmedIcon"), "a disabled glass button dims itself")

        let banner = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/WallpapersOffBanner.swift")
        #expect(banner.contains(".adaptiveGlassButton(.prominent, size: .small)"))
        #expect(!banner.contains(".buttonStyle(.borderedProminent)"))

        for (name, source) in [("WallpaperModal", modal), ("WorkshopModal", workshop), ("WallpapersOffBanner", banner)] {
            let prominent = source.components(separatedBy: ".adaptiveGlassButton(.prominent").count - 1
            #expect(prominent == 1, Comment(rawValue: "\(name) has \(prominent) prominent buttons"))
        }
    }

    @Test("No token-bypass literals in the files this package owns")
    func noTokenBypassLiterals() throws {
        for path in Self.ownedFiles {
            let source = try RepositoryRoot.source(path)
            #expect(!source.contains(".font(.system("), "\(path) has an inline .font(.system( literal")
            #expect(!source.contains("Color(red:"), "\(path) has a literal Color(red:")
            #expect(
                source.range(of: #"cornerRadius:\s*[0-9]"#, options: .regularExpression) == nil,
                "\(path) has a literal cornerRadius"
            )
        }
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
        let start = try #require(source.range(of: "private func performLibraryCardAction"))
        let body = try #require(String(source[start.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(body.contains("promptLibraryImport()"), "Import More still applies the file to a display")
        #expect(!body.contains("promptImport("))
        let panel = try #require(source.range(of: "private func promptLibraryImport()"))
        let panelBody = try #require(String(source[panel.lowerBound...]).components(separatedBy: "\n    }").first)
        #expect(panelBody.contains("importToLibrary(panel.urls)"), "the panel and the shelf import on two separate paths")
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

    @Test("Local and Workshop applies announce success with the same line")
    func applySuccessTextIsShared() throws {
        for path in [
            "LiveWallpaper/Views/EditDesk/Shell/HomePage.swift",
            "LiveWallpaper/Views/EditDesk/Workshop/DeferredApplyToasts.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains("ApplyOutcome.appliedText(on:"), "\(path) words its success toast on its own")
        }
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

    @Test("The modal's … menu and the grid's and shelf's context menus draw the same rows")
    func libraryMenusShareOneSource() throws {
        let modal = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/WallpaperModal.swift")
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(modal.contains("WallpaperMenuRows(items: actions.menuItems("))
        #expect(!modal.contains("Menu(\"Apply to\")"), "the modal lists its own rows again")
        #expect(home.contains(".contextMenu { WallpaperMenuRows(items: libraryMenu(for: item)) }"))
        #expect(home.contains("stage.cardMenu = { id in library?.items.first { $0.id == id }.map { [libraryMenu(for: $0)] } ?? [] }"))
        #expect(home.contains("modalActions?.menuItems("))
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

    @Test("The Aerials chip filters the library grid rather than mounting the old Aerials page")
    func aerialsChipKeepsTheLibraryGrid() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(!source.contains("AerialsLibraryView("), "the Aerials chip still swaps the grid for the old Aerials page")
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
        #expect(source.contains("chipsRow.modifier(ShelfChromeRide(stage: stage))"))
    }

    @Test("The filter row sits under the shelf's cards but over the library grid")
    func chipRowSitsOverTheGrid() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        let start = try #require(source.range(of: "        ZStack(alignment: .top) {"))
        let tree = try #require(String(source[start.lowerBound...]).components(separatedBy: "\n        }").first)
        let grid = try #require(tree.range(of: "libraryLayer"))
        let chips = try #require(tree.range(of: "shelfChrome"))
        #expect(grid.upperBound <= chips.lowerBound, "declared under the grid, the row vanishes behind it as it rides through")
        #expect(tree.contains("shelfChrome\n                .zIndex(landedOnLibrary ? 0 : -1)"), "the row has to drop under the cards off the library")
        #expect(tree.contains("EditDeskShelfScrim(stage: stage)\n                .zIndex(-1)"), "the scrim has to stay under the row it backs")
    }

    @Test("The library grid cross-fades in on its own layer, at once under Reduce Motion")
    func libraryGridFadesOnItsOwnLayer() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("private static let libraryFadeDuration: TimeInterval = 0.10"))
        let start = try #require(source.range(of: "private var libraryLayer: some View {"))
        let layer = try #require(String(source[start.lowerBound...]).components(separatedBy: "\n    }\n").first)
        #expect(layer.contains(
            ".animation(DesignTokens.motion(reduceMotion, .easeOut(duration: Self.libraryFadeDuration)), value: isLibraryOpen)"
        ))
        // Anywhere above the layer it would also drive the top bar, and the nav pill would lose its own slide.
        #expect(source.components(separatedBy: "value: isLibraryOpen)").count - 1 == 1)
    }

    @Test("A swipe that lands on another page slides the nav pill the way a click does")
    func swipeSlidesTheNavPill() throws {
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        let picker = try RepositoryRoot.source("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/GlassSegmentedPicker.swift")
        let slide = ".snappy(duration: 0.18)"
        #expect(picker.contains("withAnimation(DesignTokens.motion(reduceMotion, \(slide)))"), "the pill's click animation changed; match it here")
        let start = try #require(home.range(of: "case let .snapped(index):"))
        let snapped = try #require(String(home[start.upperBound...]).components(separatedBy: "case let .playbackTapped").first)
        let animated = try #require(snapped.range(of: "withAnimation(DesignTokens.motion(stage.reduceMotion, \(slide))) {"))
        let selects = snapped.components(separatedBy: "router.select(").count - 1
        #expect(selects == 2)
        #expect(snapped[animated.upperBound...].components(separatedBy: "router.select(").count - 1 == selects)
    }

    @Test("The filter row rides the shelf by drawing, not by re-laying-out, and never re-mounts")
    func shelfChromeRidesWithoutRelayout() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        let start = try #require(source.range(of: "struct ShelfChromeRide: ViewModifier {"))
        let ride = try #require(String(source[start.lowerBound...]).components(separatedBy: "\n}").first)
        #expect(ride.contains(".offset(y: StageGeometry.chipRowTop("), "a per-frame padding re-runs layout")
        #expect(!ride.contains(".padding(.top"))
        #expect(!ride.contains(".animation("), "the stage's spring already drives this; a second one lags it")
        #expect(ride.contains(".allowsHitTesting(opacity > Self.interactiveOpacity)"))
        #expect(ride.contains(".accessibilityHidden(opacity <= Self.interactiveOpacity)"))
        #expect(!source.contains("if stage.showsShelf {"), "the row stays mounted and fades instead")
        #expect(!ride.contains(".transition("), "a transition on a mounted view jumps at the threshold again")
    }

    @Test("Bars in the title-bar strip are stacked above the content laid out below them")
    func titleBarStripBarsSitOnTop() throws {
        // TitleBarStripHitTests is the behavioural check; it needs a window, so it stays out of this shard.
        let detail = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DisplayDetail.swift")
        let topBar = try #require(detail.range(of: "DetailTopBar(tags:"))
        let workspace = try #require(detail.range(of: "\n            workspace\n", range: topBar.upperBound ..< detail.endIndex))
        #expect(detail[topBar.upperBound ..< workspace.lowerBound].contains(".zIndex(1)"), "the settings column would take the top bar's clicks")

        let root = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/EditDeskRoot.swift")
        let settings = try #require(root.range(of: "case .settings:"))
        let columns = try #require(root.range(of: "HStack(spacing: 0) {", range: settings.upperBound ..< root.endIndex))
        #expect(root[settings.upperBound ..< columns.lowerBound].contains(".zIndex(1)"), "the settings column would cover the page tabs")

        // The two library pages stack their bar after the content, as home and Workshop do.
        for (path, content) in [
            ("LiveWallpaper/Views/EditDesk/Shell/SchemesPage.swift", "SchemeLibraryView("),
            ("LiveWallpaper/Views/EditDesk/Shell/SystemWallpaperPage.swift", "SystemWallpaperLibraryView("),
        ] {
            let page = try RepositoryRoot.source(path)
            let library = try #require(page.range(of: content))
            let bar = try #require(page.range(of: "TopBar("))
            #expect(library.upperBound <= bar.lowerBound, "\(path): the library's scroll view would take the top bar's clicks")
        }
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

    @Test("Grid tiles and Workshop cards draw now-playing as the capsule, whose waveform holds still under Reduce Motion")
    func nowPlayingIsTheCapsuleEverywhere() throws {
        let capsule = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Library/NowPlayingCapsule.swift")
        let effect = try #require(capsule.range(of: ".symbolEffect(.variableColor"), "the waveform no longer animates by variable colour")
        let call = String(capsule[effect.lowerBound...].prefix { $0 != "\n" })
        #expect(call.contains("isActive:") && call.contains("reduceMotion"), Comment(rawValue: "the waveform ignores Reduce Motion: \(call)"))
        let home = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        let tile = try String(home[#require(home.range(of: "struct LibraryGridTile: View")).lowerBound...])
        #expect(tile.contains("NowPlayingCapsule(badge: nowPlaying, animates: nowPlaying.isLive)"), "the grid tile draws no capsule")
        #expect(!tile.contains("ThumbnailBadge(verbatim:"), "the grid tile still draws now-playing as a plain badge")
        let browse = try RepositoryRoot.source("LiveWallpaper/Views/Workshop/BrowseCard.swift")
        #expect(browse.contains("NowPlayingCapsule(badge: inUseBadge, animates: false)"), "the Workshop card draws no capsule, or one that moves")
        #expect(!browse.contains("ThumbnailBadge(verbatim: inUseBadge"), "the Workshop card still draws now-playing as a plain badge")
    }
}
