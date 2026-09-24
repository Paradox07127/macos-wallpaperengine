import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Every page but the overview and the library unmounts `HomePage`, and the library's filter row has
/// to be as the user left it when the library comes back. Driven through the window's own controls, or
/// through the router where the test feeds the library.
@Suite("Edit Desk library state across pages", .serialized)
@MainActor
struct EditDeskLibraryStateTests {
    @Test("Leaving the library for the schemes page and coming back keeps its chip, search and sort", .timeLimit(.minutes(1)))
    func libraryStateOutlivesThePage() async throws {
        let store = BookmarkStore.shared
        let fixtures = ["Alpha", "Beta", "Gamma"].map { name in
            store.add(label: "S4b \(name)", content: .html(source: .inline("S4b \(name)"), config: .default))
        }
        defer {
            for fixture in fixtures {
                store.remove(fixture.id)
            }
        }
        // Recent lists only rows that were used: Gamma never was, and Beta was used last.
        store.touch(fixtures[0].id, at: Date())
        store.touch(fixtures[1].id, at: Date().addingTimeInterval(1))
        let labels = Dictionary(uniqueKeysWithValues: fixtures.map { ("bookmark:\($0.id)", $0.label) })
        // The language the window's `AppLanguageScope` renders in.
        let bundle = AppLanguagePreference.current(in: .appScoped()).localizationBundle()
        let sortTitles = ["Recently Used", "Name", "Type"].map { NSLocalizedString($0, bundle: bundle, comment: "") }

        try await withWindow(navigation: .bookmarks) { window, workshop in
            @MainActor func shelf() -> [String] {
                (Self.stage(in: window)?.shelfItems ?? []).compactMap { labels[$0.id] }
            }
            let opened = await Self.settle(window) { Self.stage(in: window)?.progress == 2 && Self.searchField(in: window) != nil }
            try #require(opened, "the window never opened on the library")
            let field = try #require(Self.searchField(in: window))
            Self.click(Self.chipCenter(.recent, rowMidY: field.convert(field.bounds, to: nil).midY, bundle: bundle), in: window)
            try #require(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("S4b", replacementRange: NSRange(location: NSNotFound, length: 0))
            let sort = try #require(Self.sortButton(in: window, titles: sortTitles))
            try #require(Self.pick(sortTitles[1], in: sort))
            let filtered = await Self.settle(window) { shelf() == ["S4b Alpha", "S4b Beta"] }
            try #require(filtered, Comment(rawValue: "control: Recent, S4b, by name never showed — the shelf is \(shelf())"))

            Self.click(Self.navPillCenter(.schemes, in: window, workshop: workshop, bundle: bundle), in: window)
            let left = await Self.settle(window) { Self.stage(in: window) == nil }
            try #require(left, "the schemes page never replaced the library")
            Self.click(Self.navPillCenter(.library, in: window, workshop: workshop, bundle: bundle), in: window)
            let back = await Self.settle(window) { Self.stage(in: window)?.progress == 2 }
            try #require(back, "the library never came back")

            await Self.settle(window) { shelf() == ["S4b Alpha", "S4b Beta"] }
            #expect(
                shelf() == ["S4b Alpha", "S4b Beta"],
                Comment(rawValue: "the shelf is \(shelf()): All adds Gamma, Recently Used puts Beta first")
            )
            #expect(Self.searchField(in: window)?.stringValue == "S4b", "the search came back empty")
            #expect(Self.sortButton(in: window, titles: sortTitles)?.title == sortTitles[1], "the sort came back as Recently Used")
        }
    }

    /// The overview's shelf has no search field to show the query, so arriving there drops it.
    @Test("Arriving at the overview from another page leaves the library's search behind", .timeLimit(.minutes(1)))
    func overviewDropsTheLibrarySearch() async throws {
        let store = BookmarkStore.shared
        let fixtures = ["S4b Alpha", "Zeta"].map { name in
            store.add(label: name, content: .html(source: .inline(name), config: .default))
        }
        defer {
            for fixture in fixtures {
                store.remove(fixture.id)
            }
        }
        let labels = Dictionary(uniqueKeysWithValues: fixtures.map { ("bookmark:\($0.id)", $0.label) })
        let bundle = AppLanguagePreference.current(in: .appScoped()).localizationBundle()

        try await withWindow(navigation: .bookmarks) { window, workshop in
            @MainActor func shelf() -> Set<String> {
                Set((Self.stage(in: window)?.shelfItems ?? []).compactMap { labels[$0.id] })
            }
            let opened = await Self.settle(window) { Self.stage(in: window)?.progress == 2 && Self.searchField(in: window) != nil }
            try #require(opened, "the window never opened on the library")
            let field = try #require(Self.searchField(in: window))
            try #require(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            editor.insertText("S4b", replacementRange: NSRange(location: NSNotFound, length: 0))
            let filtered = await Self.settle(window) { shelf() == ["S4b Alpha"] }
            try #require(filtered, Comment(rawValue: "control: the search never filtered — the shelf is \(shelf())"))

            Self.click(Self.navPillCenter(.schemes, in: window, workshop: workshop, bundle: bundle), in: window)
            let left = await Self.settle(window) { Self.stage(in: window) == nil }
            try #require(left, "the schemes page never replaced the library")
            Self.click(Self.navPillCenter(.home, in: window, workshop: workshop, bundle: bundle), in: window)
            let home = await Self.settle(window) { Self.stage(in: window) != nil }
            try #require(home, "the overview never came back")

            await Self.settle(window) { shelf() == ["S4b Alpha", "Zeta"] }
            #expect(shelf() == ["S4b Alpha", "Zeta"], Comment(rawValue: "the library's search still filters the shelf: \(shelf())"))
        }
    }

    @Test("A wallpaper used before leaving the library ranks as recently used when the library comes back", .timeLimit(.minutes(1)))
    func recentUseCountsOnReturn() async throws {
        let store = BookmarkStore.shared
        let fixtures = ["Alpha", "Beta", "Gamma"].map { name in
            store.add(label: "S4c \(name)", content: .html(source: .inline("S4c \(name)"), config: .default))
        }
        defer {
            for fixture in fixtures {
                store.remove(fixture.id)
            }
        }
        store.touch(fixtures[0].id, at: Date())
        store.touch(fixtures[1].id, at: Date().addingTimeInterval(1))
        let labels = Dictionary(uniqueKeysWithValues: fixtures.map { ("bookmark:\($0.id)", $0.label) })
        let bundle = AppLanguagePreference.current(in: .appScoped()).localizationBundle()

        try await withWindow(navigation: .bookmarks) { window, workshop in
            @MainActor func shelf() -> [String] {
                (Self.stage(in: window)?.shelfItems ?? []).compactMap { labels[$0.id] }
            }
            let opened = await Self.settle(window) { shelf() == ["S4c Beta", "S4c Alpha", "S4c Gamma"] }
            try #require(opened, Comment(rawValue: "control: the library never opened by recent use — the shelf is \(shelf())"))
            // What applying Gamma from the library records; the browse that is open keeps its order.
            store.touch(fixtures[2].id, at: Date().addingTimeInterval(2))
            await Self.settle(window) { shelf().first == "S4c Gamma" }
            try #require(
                shelf() == ["S4c Beta", "S4c Alpha", "S4c Gamma"],
                Comment(rawValue: "control: the open browse reordered — the shelf is \(shelf())")
            )

            Self.click(Self.navPillCenter(.schemes, in: window, workshop: workshop, bundle: bundle), in: window)
            let left = await Self.settle(window) { Self.stage(in: window) == nil }
            try #require(left, "the schemes page never replaced the library")
            Self.click(Self.navPillCenter(.library, in: window, workshop: workshop, bundle: bundle), in: window)
            let back = await Self.settle(window) { Self.stage(in: window)?.progress == 2 }
            try #require(back, "the library never came back")

            await Self.settle(window) { shelf().first == "S4c Gamma" }
            #expect(
                shelf() == ["S4c Gamma", "S4c Beta", "S4c Alpha"],
                Comment(rawValue: "the shelf is \(shelf()): the browse left open with the library still ranks Gamma as never used")
            )
        }
    }

    @Test("A row marked unavailable is asked about again when the library comes back", .timeLimit(.minutes(1)))
    func unavailableRowIsRecheckedOnReturn() async throws {
        let row = WallpaperBookmark(label: "S4c Drive", content: .html(source: .inline("S4c Drive"), config: .default))
        // The drive behind the row: unplugged at first, plugged back in while another page shows.
        var plugged = false
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { [row] }
        inputs.sourceAvailable = { _ in plugged }

        try await withHome(inputs) { window, router, _ in
            @MainActor func card() -> StageCard? {
                Self.stage(in: window)?.shelfItems.first { $0.id == "bookmark:\(row.id)" }
            }
            let marked = await Self.settle(window) { card()?.statusBadge != nil }
            try #require(marked, "control: the row was never marked unavailable")
            plugged = true
            router.select(.schemes)
            let left = await Self.settle(window) { Self.stage(in: window) == nil }
            try #require(left, "the schemes page never replaced the library")
            router.select(.library)
            let back = await Self.settle(window) { card() != nil }
            try #require(back, "the library never came back")

            let cleared = await Self.settle(window) { card().map { $0.statusBadge == nil } == true }
            #expect(cleared, Comment(rawValue: "the row still reads \(card()?.statusBadge ?? "nothing") with its drive back"))
        }
    }

    #if !LITE_BUILD
    @Test("A search kept across pages finds a row added meanwhile by its tags", .timeLimit(.minutes(1)))
    func keptSearchReadsNewRowsTags() async throws {
        let plain = WallpaperBookmark(label: "S4c Plain", content: .html(source: .inline("S4c Plain"), config: .default))
        var tagged = WallpaperBookmark(label: "S4c Tagged", content: .html(source: .inline("S4c Tagged"), config: .default))
        tagged.wpeOrigin = WPEOrigin(
            workshopID: "S4C", title: "S4c Tagged", originalType: .web,
            sourceFolderBookmark: Data(), cacheRelativePath: nil, previewFileName: nil
        )
        var rows = [plain]
        var inputs = SavedLibraryModel.Inputs()
        inputs.bookmarks = { rows }
        inputs.projectTags = { $0.workshopID == "S4C" ? ["Nebula"] : [] }

        try await withHome(inputs) { window, router, library in
            @MainActor func shelf() -> [String] {
                (Self.stage(in: window)?.shelfItems ?? []).map(\.title)
            }
            let opened = await Self.settle(window) { shelf() == ["S4c Plain"] }
            try #require(opened, Comment(rawValue: "control: the library never showed its row — the shelf is \(shelf())"))
            library.query = "Nebula"
            let searched = await Self.settle(window) { shelf().isEmpty }
            try #require(searched, Comment(rawValue: "control: the search never filtered — the shelf is \(shelf())"))
            router.select(.schemes)
            let left = await Self.settle(window) { Self.stage(in: window) == nil }
            try #require(left, "the schemes page never replaced the library")
            // Downloaded while the schemes page shows; the live model refreshes on the store's change.
            rows.append(tagged)
            library.refresh()
            router.select(.library)
            let back = await Self.settle(window) { Self.stage(in: window) != nil }
            try #require(back, "the library never came back")

            let found = await Self.settle(window) { shelf() == ["S4c Tagged"] }
            #expect(found, Comment(rawValue: "the shelf is \(shelf()): the search never read the tags of the row added meanwhile"))
        }
    }
    #endif

    // MARK: Harness

    /// The app's own Edit Desk window, parked off every display as in `TitleBarStripHitTests`.
    /// `body` also gets whether the nav pill offers Workshop.
    private func withWindow(navigation: Navigation?, _ body: @MainActor (NSWindow, Bool) async throws -> Void) async throws {
        let frameKey = "NSWindow Frame LiveWallpaperEditDeskWindow"
        let previousFrame = UserDefaults.standard.object(forKey: frameKey)
        defer { UserDefaults.standard.set(previousFrame, forKey: frameKey) }
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
        #if !LITE_BUILD
        let doctor = SteamCMDDoctorService()
        let host = SettingsWindowHost(
            manager: manager,
            wallpaperExportService: WallpaperExportService(),
            workshopDoctorService: doctor,
            workshopServices: WorkshopServices(),
            workshopSetupController: WorkshopSetupController(doctor: doctor)
        )
        #else
        let host = SettingsWindowHost(manager: manager, wallpaperExportService: WallpaperExportService())
        #endif
        let delegate = WindowDelegate()
        let controller = host.makeWindowController(
            editDeskEnabled: true, initialNavigation: navigation, initialAddWallpaperRequest: nil, delegate: delegate
        )
        let window = try #require(controller.window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            manager.tearDownForTermination()
        }
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        try await body(window, manager.featureCatalog.isEnabled(.wpeImport))
    }

    /// `HomePage` over a library the test feeds, opened on the library, parked like `withWindow`'s;
    /// `body` changes pages through the router.
    private func withHome(
        _ inputs: SavedLibraryModel.Inputs, _ body: @MainActor (NSWindow, EditDeskRouter, SavedLibraryModel) async throws -> Void
    ) async throws {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false,
            startAutomation: false,
            powerMonitor: FakePowerMonitor(),
            fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(),
            displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
        let router = EditDeskRouter(initialNavigation: .bookmarks, initialAddWallpaperRequest: nil, isWorkshopAvailable: { false })
        let library = SavedLibraryModel(inputs: inputs)
        let host = NSHostingView(rootView: PageSwitch(router: router, toasts: EditDeskToastCenter(), library: library).environment(manager))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: StageGeometry.designWindow),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            manager.tearDownForTermination()
        }
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        try await body(window, router, library)
    }

    /// `EditDeskRoot`'s page switch: only the overview and the library mount `HomePage`.
    private struct PageSwitch: View {
        let router: EditDeskRouter
        let toasts: EditDeskToastCenter
        let library: SavedLibraryModel

        var body: some View {
            if router.page == .home || router.page == .library {
                HomePage(router: router, toasts: toasts, library: library)
            } else {
                Color.clear
            }
        }
    }

    @discardableResult
    private static func settle(_ window: NSWindow, until condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func views(in window: NSWindow) -> [NSView] {
        func walk(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk) ?? []
    }

    /// Only `HomePage` carries the stage, so nil means another page is showing.
    private static func stage(in window: NSWindow) -> EditDeskStageModel? {
        views(in: window).lazy.compactMap { ($0 as? EditDeskStageView)?.model }.first
    }

    private static func searchField(in window: NSWindow) -> NSTextField? {
        views(in: window).lazy.compactMap { $0 as? NSTextField }.first(where: \.isEditable)
    }

    /// The filter row's sort menu, whose button shows the sort's title.
    private static func sortButton(in window: NSWindow, titles: [String]) -> NSPopUpButton? {
        views(in: window).lazy.compactMap { $0 as? NSPopUpButton }.first { titles.contains($0.title) }
    }

    /// The release goes on the queue first, where a control that tracks the press takes it. A SwiftUI
    /// button does not, so it is handed over here: left queued, a menu opened next would swallow it.
    private static func click(_ point: NSPoint, in window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(queued)
        }
    }

    /// SwiftUI fills a `Menu`'s items only while it is open; they stay once the scheduled cancel closes it.
    private static func pick(_ title: String, in popup: NSPopUpButton) -> Bool {
        guard let menu = popup.menu else { return false }
        menu.perform(#selector(NSMenu.cancelTracking), with: nil, afterDelay: 0.2, inModes: [.common])
        popup.performClick(nil)
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: index)
        return true
    }

    /// `NavPill` at `navItem` 13 in `GlassSegmentedPicker`'s editDesk shell (3pt outer padding, 14pt
    /// each side of a title, 2pt between), centred in the 56pt top bar.
    private static func navPillCenter(_ page: EditDeskRouter.Page, in window: NSWindow, workshop: Bool, bundle: Bundle) -> NSPoint {
        let items = NavPill.items(workshopAvailable: workshop, systemWallpaperAvailable: EditDeskRouter.systemWallpaperSupported)
        let widths = items.map { item in
            let title = NSLocalizedString(NavPill.title(for: item).probeKey, bundle: bundle, comment: "")
            return (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width + 2 * 14
        }
        let index = items.firstIndex(of: page) ?? 0
        let pill = 2 * 3 + widths.reduce(0, +) + 2 * CGFloat(items.count - 1)
        let leading = window.frame.width / 2 - pill / 2 + 3 + widths[..<index].reduce(0, +) + 2 * CGFloat(index)
        return NSPoint(x: leading + widths[index] / 2, y: window.frame.height - DesignTokens.EditDesk.Spacing.topBar / 2)
    }

    /// `FilterChip`s from the shelf chrome's gutter: the caption title plus 10pt a side, 8pt apart.
    private static func chipCenter(_ chip: SavedLibraryModel.Chip, rowMidY: CGFloat, bundle: Bundle) -> NSPoint {
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize)
        let chips = SavedLibraryModel.Chip.allCases
        let widths = chips.map { chip in
            let title = NSLocalizedString(HomePage.chipTitle(chip).probeKey, bundle: bundle, comment: "")
            return ceil((title as NSString).size(withAttributes: [.font: font]).width) + 2 * 10
        }
        let index = chips.firstIndex(of: chip) ?? 0
        let leading = DesignTokens.EditDesk.Spacing.gutter + widths[..<index].reduce(0, +)
            + DesignTokens.EditDesk.Spacing.s8 * CGFloat(index)
        return NSPoint(x: leading + widths[index] / 2, y: rowMidY)
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {}
}
