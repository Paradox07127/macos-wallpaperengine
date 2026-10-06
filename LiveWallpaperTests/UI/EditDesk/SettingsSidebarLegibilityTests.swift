#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@MainActor
@Observable
private final class SidebarSelection {
    var value: SettingsNavigation? = .general
}

/// The Edit Desk hosts `SettingsSidebar` in a bare `HStack` (`EditDeskRoot`'s settings branch), with no
/// `NavigationStack` or `NavigationSplitView` around it.
@Suite("Settings sidebar legibility", .serialized)
@MainActor
struct SettingsSidebarLegibilityTests {
    /// Table rows: the Setup header, then General, Appearance, Display Defaults, Shortcuts.
    private static let headerRow = 0
    private static let displayDefaultsRow = 3
    private static let shortcutsRow = 4

    private static let size = CGSize(width: 480, height: 640)

    /// A list row's ink: the pixel farthest from the row's own background, as a grey level 0–255.
    private struct RowInk {
        let ink: Int
        let background: Int
    }

    private static func grey(_ colour: ProbeColor) -> Int {
        (colour.r + colour.g + colour.b) / 3
    }

    private static func ink(in image: ProbeImage, row rect: CGRect) -> RowInk {
        let scale = image.scale
        let background = grey(image.rgb(px: Int((rect.maxX - 6) * scale), Int(rect.midY * scale)))
        var ink = background
        for y in Int(rect.minY * scale) ..< Int(rect.maxY * scale) {
            for x in Int(rect.minX * scale) ..< Int(rect.maxX * scale) {
                let value = grey(image.rgb(px: x, y))
                if abs(value - background) > abs(ink - background) {
                    ink = value
                }
            }
        }
        return RowInk(ink: ink, background: background)
    }

    private static func views(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(views)
    }

    private static func sidebarTable(in window: NSWindow) -> NSTableView? {
        guard let root = window.contentView else { return nil }
        return views(root).lazy.compactMap { $0 as? NSTableView }.first
    }

    private static func settle(_ window: NSWindow, for seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(10))
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// Through the table, not a synthetic click: a click reaches the list only in the key window of an
    /// active app, which a test host in the background (or behind a locked screen) never is.
    private static func select(row: Int, of table: NSTableView) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// `EditDeskRoot`'s settings column: the sidebar in a bare `HStack` on the window's flat canvas.
    private static func editDeskSidebar(_ selection: SidebarSelection) -> some View {
        HStack(spacing: 0) {
            SettingsSidebar(
                selection: Binding(get: { selection.value }, set: { selection.value = $0 }),
                searchText: .constant(""), pendingSearchAnchor: .constant(nil)
            )
            .frame(width: SettingsWindowMetrics.sidebarColumnWidth)
            Divider()
            Color.clear
        }
        .frame(width: size.width, height: size.height)
        .background { EditDeskBackdrop(frosted: false) }
    }

    /// Parked off every display and never made key: a window in the background.
    private static func mount(_ view: some View, appearance: NSAppearance.Name) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: AppLanguageScope(defaults: .appScoped()) { view })
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderBack(nil)
        return (window, host)
    }

    private static func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    @Test("Setup lists General, Appearance, Display Defaults and Shortcuts first, the rows these tests read")
    func setupGroupOrder() {
        let setup = SettingsNavigation.availableItems(capabilities: .unconfigured).filter { $0.group == .setup }
        #expect(setup.prefix(4).map(\.destination) == [.general, .appearance, .displayDefaults, .shortcuts])
    }

    @Test("Without a navigation container the category rows keep the primary label colour", arguments: [true, false])
    func rowsKeepFullStrengthWithoutANavigationContainer(dark: Bool) async throws {
        let (window, host) = Self.mount(Self.editDeskSidebar(SidebarSelection()), appearance: dark ? .darkAqua : .aqua)
        defer { Self.close(window) }
        await Self.settle(window, for: 1)
        #expect(!window.isKeyWindow, "control: the window is key, so the background-window state is not under test")
        let table = try #require(Self.sidebarTable(in: window))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try ProbeImage(cgImage: #require(bitmap.cgImage), viewWidth: Self.size.width)
        let header = Self.ink(in: image, row: table.convert(table.rect(ofRow: Self.headerRow), to: host))
        let row = Self.ink(in: image, row: table.convert(table.rect(ofRow: Self.displayDefaultsRow), to: host))
        print("SIDEBAR-INK dark=\(dark) scale=\(image.scale) row=\(row.ink) on \(row.background) header=\(header.ink) on \(header.background)")
        #expect(abs(header.ink - header.background) >= 60, "control: no text found in the header row, so the row rects miss the picture")
        if dark {
            #expect(row.ink >= 200, "the category name is grey, not white: \(row.ink) on \(row.background)")
        } else {
            #expect(row.ink <= 60, "the category name is grey, not black: \(row.ink) on \(row.background)")
        }
    }

    @Test("Selecting a category row sets the sidebar's selection to that category")
    func selectingARowSetsItsCategory() async throws {
        let selection = SidebarSelection()
        let (window, _) = Self.mount(Self.editDeskSidebar(selection), appearance: .darkAqua)
        defer { Self.close(window) }
        await Self.settle(window, for: 1)
        let table = try #require(Self.sidebarTable(in: window))
        Self.select(row: Self.shortcutsRow, of: table)
        await Self.settle(window, for: 0.5)
        #expect(selection.value == .shortcuts, "selecting the Shortcuts row left the selection at \(String(describing: selection.value))")
    }
}
#endif
