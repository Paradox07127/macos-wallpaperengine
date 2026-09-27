#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Drives the settings window the way a user does: type into the sidebar's search field, pick the result.
@Suite("Settings search emphasises the row it lands on", .serialized)
@MainActor
struct SettingsSearchRowEmphasisTests {
    private final class WindowDelegate: NSObject, NSWindowDelegate {}

    /// While searching, the sidebar's table holds the Search Results header and then the results.
    private static let firstResultRow = 1

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views)
    }

    private static func settle(_ window: NSWindow, for seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func snapshot(_ view: NSView) throws -> ProbeImage {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try ProbeImage(cgImage: #require(bitmap.cgImage), viewWidth: view.bounds.width)
    }

    /// The box, in points from the top-left, around every pixel inside `rect` that differs between the two pictures.
    private static func changedBox(_ first: ProbeImage, _ second: ProbeImage, in rect: CGRect) -> CGRect? {
        let scale = first.scale
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in Int(rect.minY * scale) ..< min(Int(rect.maxY * scale), first.height) {
            for x in Int(rect.minX * scale) ..< min(Int(rect.maxX * scale), first.width) {
                let a = first.rgb(px: x, y), b = second.rgb(px: x, y)
                guard abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) > 16 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
            width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale
        )
    }

    /// The app's settings window opened on General, parked off every display; `editDesk` picks the Edit Desk layout.
    private static func withSettingsWindow(editDesk: Bool, _ body: (NSWindow, NSView) async throws -> Void) async throws {
        let manager = ScreenManager(startupOptions: ScreenManagerStartupOptions(
            restoreSavedWallpapers: false, startAutomation: false,
            powerMonitor: FakePowerMonitor(), fullScreenDetector: FakeFullScreenDetector(),
            playableVideoLoader: FakePlayableVideoLoader(), displayRegistry: FakeDisplayRegistry(),
            featureCatalog: .unconfigured
        ))
        defer { manager.tearDownForTermination() }
        let doctor = SteamCMDDoctorService()
        let host = SettingsWindowHost(
            manager: manager, wallpaperExportService: WallpaperExportService(),
            workshopDoctorService: doctor, workshopServices: WorkshopServices(),
            workshopSetupController: WorkshopSetupController(doctor: doctor)
        )
        let delegate = WindowDelegate()
        let controller = host.makeWindowController(
            editDeskEnabled: editDesk, initialNavigation: .general, initialAddWallpaperRequest: nil,
            savesFrame: false, delegate: delegate
        )
        let window = try #require(controller.window)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        window.setContentSize(
            editDesk ? SettingsWindowMetrics.editDeskMinimumContentSize : SettingsWindowMetrics.minimumContentSize
        )
        window.parkOffScreen()
        await settle(window, for: 1.2)
        try await body(window, #require(window.contentView))
    }

    /// Types `query` into the sidebar's search field the way AppKit reports typing; `rows` is the sidebar table's row count after.
    private static func search(_ query: String, in window: NSWindow, root: NSView) async throws -> (field: NSTextField, rows: Int) {
        let field = try #require(views(root).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        field.stringValue = query
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
        await settle(window, for: 0.6)
        return try (field, sidebarTable(in: root).numberOfRows)
    }

    private static func sidebarTable(in root: NSView) throws -> NSTableView {
        try #require(views(root).compactMap { $0 as? NSTableView }.first)
    }

    /// The scroll view of the settings page beside the sidebar.
    private static func page(in root: NSView) throws -> NSScrollView {
        try #require(
            views(root).compactMap { $0 as? NSScrollView }.first { !($0.documentView is NSTableView) && $0.frame.width > 300 },
            "no settings page beside the sidebar"
        )
    }

    /// Picks the first search result through the table: a synthetic click reaches the list only in the key window
    /// of an active app. `marked` boxes what changes on the page between the mark's hold and after it fades; nil for nothing.
    private static func pickFirstResult(
        in window: NSWindow, root: NSView
    ) async throws -> (page: NSScrollView, visible: CGRect, marked: CGRect?) {
        try sidebarTable(in: root).selectRowIndexes(IndexSet(integer: firstResultRow), byExtendingSelection: false)
        await settle(window, for: 1.0)
        let page = try page(in: root)
        let visible = page.convert(page.contentView.frame, to: root)
        let marked = try snapshot(root)
        await settle(window, for: 3.6)
        let faded = try snapshot(root)
        return (page, visible, changedBox(marked, faded, in: visible))
    }

    private static func expectRowMark(_ box: CGRect, in visible: CGRect) {
        #expect(
            box.width >= visible.width * 0.6,
            "the mark is \(Int(box.width))pt wide in a \(Int(visible.width))pt page: a section title, not a row"
        )
        #expect(box.height <= 60, "the marks span \(Int(box.height))pt: the section title is marked along with the row")
    }

    @Test("Picking a result scrolls the matching row of a long page into view and marks that row, not its section title")
    func resultMarksItsRow() async throws {
        let query = "Video preload (RAM)"
        try await Self.withSettingsWindow(editDesk: false) { window, root in
            #expect(root.isFlipped, "control: the page rect below is read top-down, as the bitmap is")
            let search = try await Self.search(query, in: window, root: root)
            #expect(search.rows == 2, "control: expected the Search Results header and one result, found \(search.rows) rows")

            let pick = try await Self.pickFirstResult(in: window, root: root)
            let scrolled = pick.page.contentView.bounds.origin.y
            #expect(scrolled > 0, "the page did not scroll; the row was already on screen, so this proves nothing")
            let marked = pick.marked
            let box = try #require(marked, "nothing on the page was marked")
            Self.expectRowMark(box, in: pick.visible)
            let text = search.field.stringValue
            #expect(text == query, "picking a result cleared the search")
            let responder = window.firstResponder as? NSView
            let focusInPage = responder.map { pick.visible.contains($0.convert($0.bounds, to: root).origin) } ?? false
            #expect(!focusInPage, "keyboard focus moved into the page: \(String(describing: window.firstResponder))")
        }
    }

    @Test(
        "Picking the result for the page already showing marks its row, though neither the page nor the anchor changes",
        arguments: [false, true]
    )
    func pickOnThePageShowing(editDesk: Bool) async throws {
        let support = SettingsNavigation.allItems.filter { $0.group == .support }.map(\.destination)
        #expect(
            SettingsNavigationGroup.allCases.last == .support && support == [.advanced, .about],
            "control: Advanced is not the sidebar's second-to-last row"
        )
        try await Self.withSettingsWindow(editDesk: editDesk) { window, root in
            let general = try Self.page(in: root)
            let table = try Self.sidebarTable(in: root)
            table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 2), byExtendingSelection: false)
            await Self.settle(window, for: 0.8)
            let advanced = try Self.page(in: root)
            let opened = advanced !== general
            #expect(opened, "control: selecting Advanced in the sidebar left General showing")

            let rows = try await Self.search("Log Files", in: window, root: root).rows
            #expect(rows == 2, "control: expected the Search Results header and Advanced, found \(rows) rows")
            let selected = try Self.sidebarTable(in: root).selectedRow
            #expect(selected != Self.firstResultRow, "control: the sidebar already holds the result, so picking it changes nothing")
            let pick = try await Self.pickFirstResult(in: window, root: root)
            let samePage = pick.page === advanced
            #expect(samePage, "control: the pick opened another page, so this is not the page already showing")
            let marked = pick.marked
            let box = try #require(marked, "picking the result for the page already showing marked nothing")
            Self.expectRowMark(box, in: pick.visible)
        }
    }

    @Test("Picking a result for another page opens that page and marks the row", arguments: [false, true])
    func pickForAnotherPage(editDesk: Bool) async throws {
        try await Self.withSettingsWindow(editDesk: editDesk) { window, root in
            let general = try Self.page(in: root)
            let rows = try await Self.search("Log Files", in: window, root: root).rows
            #expect(rows == 2, "control: expected the Search Results header and Advanced, found \(rows) rows")
            let pick = try await Self.pickFirstResult(in: window, root: root)
            let opened = pick.page !== general
            #expect(opened, "control: the pick left General showing")
            let marked = pick.marked
            let box = try #require(marked, "picking the result for another page marked nothing")
            Self.expectRowMark(box, in: pick.visible)
        }
    }

    @Test("Picking a result in a section of the page already showing marks its row", arguments: [false, true])
    func pickSectionResultOnThePageShowing(editDesk: Bool) async throws {
        try await Self.withSettingsWindow(editDesk: editDesk) { window, root in
            let general = try Self.page(in: root)
            let rows = try await Self.search("Language", in: window, root: root).rows
            #expect(rows == 2, "control: expected the Search Results header and General, found \(rows) rows")
            let pick = try await Self.pickFirstResult(in: window, root: root)
            let samePage = pick.page === general
            #expect(samePage, "control: the pick opened another page, so this is not the page already showing")
            let marked = pick.marked
            let box = try #require(marked, "picking a result in a section of the page already showing marked nothing")
            Self.expectRowMark(box, in: pick.visible)
        }
    }
}
#endif
