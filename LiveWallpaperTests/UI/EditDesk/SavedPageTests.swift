import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Suite("Saved page", .serialized)
struct SavedPageTests {
    @MainActor
    private final class MemoryBookmarks: BookmarkPersisting {
        func load() -> [WallpaperBookmark] {
            []
        }

        func save(_: [WallpaperBookmark]) {}
    }

    private func makeRouter(_ navigation: Navigation? = nil) -> EditDeskRouter {
        EditDeskRouter(initialNavigation: navigation, initialAddWallpaperRequest: nil, isWorkshopAvailable: { true })
    }

    private func makeManager() -> ScreenManager {
        ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
    }

    private func store(_ labels: [String]) -> (BookmarkStore, [WallpaperBookmark]) {
        let store = BookmarkStore(persistence: MemoryBookmarks())
        let added = labels.enumerated().map { index, label in
            store.add(label: label, content: .video(bookmarkData: Data([UInt8(index + 1)])))
        }
        return (store, added)
    }

    private func model(_ store: BookmarkStore, undo: EditDeskUndoStack? = nil) -> SavedBookmarks {
        #if LITE_BUILD
        SavedBookmarks(store: store, undo: undo, displays: { [] }, apply: { _, _ in }, applyToAll: { _, _ in })
        #else
        SavedBookmarks(
            store: store, workshopStore: workshopStore(), undo: undo, displays: { [] }, apply: { _, _ in },
            applyToAll: { _, _ in }
        )
        #endif
    }

    #if !LITE_BUILD
    private func workshopStore() -> WorkshopBookmarkStore {
        WorkshopBookmarkStore(defaults: UserDefaults(suiteName: "saved-page.\(UUID().uuidString)")!)
    }
    #endif

    // MARK: Routing

    @Test("Bookmarks navigation opens the Saved page on Bookmarks, and Manage Schemes opens it on Schemes")
    func routesChooseTheTab() throws {
        let launched = makeRouter(.bookmarks)
        #expect(launched.page == .schemes)
        #expect(launched.takeSavedTab() == .bookmarks)
        #expect(launched.takeSavedTab() == nil, "the tab request is taken once")

        let router = makeRouter()
        router.openSaved(.schemes)
        #expect(router.page == .schemes)
        #expect(router.takeSavedTab() == .schemes)

        let host = try RepositoryRoot.source("LiveWallpaper/Views/EditDesk/Detail/DisplayDetailHost.swift")
        #expect(host.contains("router.openSaved(.schemes)"), "Manage Schemes does not pick the Schemes tab")
    }

    // MARK: Tabs

    /// Mounts the page in a parked window long enough for its `onChange` hooks to run.
    private func mount(_ page: some View, manager: ScreenManager, while body: () async -> Void) async {
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .standard) {
            page.environment(manager).frame(width: 1280, height: 820)
        })
        let window = ParkedTestWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.parkOffScreen()
        await settle()
        await body()
        window.orderOut(nil)
        window.contentView = nil
    }

    private func settle() async {
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("The chosen tab is written to its key and read back on the next visit")
    func tabIsRemembered() async {
        let defaults = UserDefaults.appScoped()
        let key = EditDeskRouter.SavedTab.preferencesKey
        #expect(key == "loomscreen.savedLibrary.selectedTab.v1")
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        let (bookmarks, _) = store([])

        let first = makeRouter()
        first.openSaved(.schemes)
        await mount(SchemesPage(router: first, toasts: EditDeskToastCenter(), bookmarkStore: bookmarks), manager: manager) {
            #expect(defaults.string(forKey: key) == "schemes")
            #expect(first.pendingSavedTab == nil, "the page did not take the request")
        }

        let second = makeRouter()
        second.select(.schemes)
        await mount(SchemesPage(router: second, toasts: EditDeskToastCenter(), bookmarkStore: bookmarks), manager: manager) {
            #expect(defaults.string(forKey: key) == "schemes", "a plain visit reset the remembered tab")
            second.openSaved(.bookmarks)
            await settle()
            #expect(defaults.string(forKey: key) == "bookmarks")
        }
    }

    // MARK: Bookmarks

    @Test("The bookmarks tab lists every saved wallpaper, and an empty store is the empty state")
    func listsBookmarks() {
        let (full, added) = store(["Beta", "Alpha"])
        let saved = model(full)
        #expect(saved.items.map(\.id) == added.map { "bookmark:\($0.id)" })
        #expect(!saved.isEmpty)
        #expect(saved.visibleItems(sort: .name).map(\.title) == ["Alpha", "Beta"])
        saved.searchText = "alp"
        #expect(saved.visibleItems(sort: .name).map(\.title) == ["Alpha"])

        let (empty, _) = store([])
        #expect(model(empty).isEmpty)
    }

    #if !LITE_BUILD
    @Test("The Workshop Bookmarks section shows only while a Workshop item is bookmarked")
    func workshopSectionFollowsItsStore() {
        let (bookmarks, _) = store([])
        let workshop = workshopStore()
        let saved = SavedBookmarks(
            store: bookmarks, workshopStore: workshop, undo: nil, displays: { [] }, apply: { _, _ in }, applyToAll: { _, _ in }
        )
        #expect(saved.visibleWorkshopBookmarks.isEmpty)
        #expect(saved.isEmpty, "nothing is saved in either store")
        workshop.add(WorkshopBookmark(id: 42, rawTitle: "Forest", previewImageURL: nil, tags: ["Scene"]))
        #expect(saved.visibleWorkshopBookmarks.map(\.id) == [42])
        #expect(!saved.isEmpty)
        workshop.remove(42)
        #expect(saved.visibleWorkshopBookmarks.isEmpty)
    }
    #endif

    @Test("Remove Bookmark in a card's context menu is one undoable step", .timeLimit(.minutes(1)))
    func removeBookmarkIsUndoable() async throws {
        let (bookmarks, added) = store(["Before", "Saved", "After"])
        let manager = UndoTestManager()
        let undo = EditDeskUndoStack(
            manager: manager, router: ApplyRouter(manager: manager, bookmarks: bookmarks, sceneCapable: true),
            bookmarks: bookmarks
        )
        let saved = model(bookmarks, undo: undo)
        let item = try #require(saved.items.first { $0.title == "Saved" })
        let rows = saved.menuItems(for: item, exportService: nil)
        let titles = rows.map(\.title)
        for key in ["Apply to All Displays", "Rename", "Remove Bookmark"] {
            #expect(titles.contains(String(localized: String.LocalizationValue(key), bundle: .appLanguage)), Comment(rawValue: key))
        }
        let remove = try #require(rows.first { $0.title == String(localized: "Remove Bookmark", bundle: .appLanguage) })
        #expect(remove.isDestructive)

        remove.action()

        #expect(bookmarks.bookmarks.map(\.label) == ["Before", "After"])
        guard case let .bookmark(recorded, index)? = undo.undoSteps.last?.change else {
            Issue.record("Remove Bookmark recorded no step")
            return
        }
        #expect(recorded == added[1])
        #expect(index == 1)
        _ = try #require(await undo.undo())
        #expect(bookmarks.bookmarks.map(\.label) == ["Before", "Saved", "After"])
    }

    // MARK: Probe

    #if !LITE_BUILD
    @Test("Probe: the Saved page's two tabs at 1280×820")
    func probeImages() async {
        let defaults = UserDefaults.appScoped()
        let key = EditDeskRouter.SavedTab.preferencesKey
        defer { defaults.removeObject(forKey: key) }
        let manager = makeManager()
        defer { manager.tearDownForTermination() }
        let (bookmarks, _) = store(["Aurora Loop", "Rain on Glass", "City Lights", "Ocean Drift"])
        for (tab, name) in [(EditDeskRouter.SavedTab.bookmarks, "saved-bookmarks"), (.schemes, "saved-schemes")] {
            let router = makeRouter()
            router.openSaved(tab)
            _ = await ProbeRenderer.render(name, size: CGSize(width: 1280, height: 820), settle: 1) {
                SchemesPage(router: router, toasts: EditDeskToastCenter(), bookmarkStore: bookmarks)
                    .environment(manager)
                    .background { EditDeskBackdrop(frosted: false) }
            }
        }
    }
    #endif
}
