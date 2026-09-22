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
        "LiveWallpaper/Views/EditDesk/Library/LibrarySegmentPicker.swift",
    ]

    @Test("NavPill and LibrarySegmentPicker build on GlassSegmentedPicker's editDesk shell")
    func navPillAndSegmentPickerUseEditDeskShell() throws {
        for path in [
            "LiveWallpaper/Views/EditDesk/Shell/NavPill.swift",
            "LiveWallpaper/Views/EditDesk/Library/LibrarySegmentPicker.swift",
        ] {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains("GlassSegmentedPicker("), "\(path) does not build on GlassSegmentedPicker")
            #expect(source.contains("shell: .editDesk"), "\(path) does not request the editDesk shell")
        }
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

    @Test("The top bar's search field is LibrarySearchField")
    func topBarUsesLibrarySearchField() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/TopBar.swift")
        #expect(source.contains("LibrarySearchField("))
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
        #expect(source.contains("applies.run(for: displayID) { await applyCard(cardID, to: displayID) }"))
        #expect(!source.contains("await applyCard(cardID, to: displayID)\n            case"))
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

    @Test("Orphan covers are swept once, when the library model is first built")
    func libraryModelSweepsCoversOnce() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Shell/HomePage.swift")
        #expect(source.contains("let model = SavedLibraryModel(screenManager: screenManager)"))
        #expect(source.contains("model.prepareLibrary()"))
        #expect(
            source.components(separatedBy: "prepareLibrary()").count - 1 == 1,
            "the cover sweep must not run again on every library rebuild"
        )
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

    @Test("The display link is rebuilt when the window moves to another screen")
    func displayLinkFollowsTheWindow() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Stage/EditDeskStageView.swift")
        #expect(source.contains("NSWindow.didChangeScreenNotification"))
        #expect(source.contains("self.stopDisplayLink()\n                    self.startDisplayLinkIfNeeded()"))
        #expect(source.contains("screenObserver.map(NotificationCenter.default.removeObserver)"))
    }
}
