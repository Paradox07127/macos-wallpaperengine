import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Settings first header alignment")
@MainActor
struct SettingsFirstHeaderAlignmentTests {
    private final class Measured {
        var header: CGRect = .zero
    }

    @Test("The first section title of a settings page sits level with the sidebar search field")
    func firstHeaderIsLevelWithSearchField() async throws {
        let measured = Measured()
        let page = HStack(spacing: 0) {
            SettingsSidebar(selection: .constant(.general), searchText: .constant(""), pendingSearchAnchor: .constant(nil))
                .frame(width: SettingsWindowMetrics.sidebarColumnWidth)
            Divider()
            Form {
                Section {
                    Text(verbatim: "Row")
                } header: {
                    SettingsSearchSectionHeader("Language", anchor: .generalLanguage)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { measured.header = $0 }
                }
            }
            .settingsFormChrome()
        }
        let host = NSHostingView(rootView: page)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.contentView = host
        for _ in 0 ..< 20 {
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        let field = try #require(Self.firstTextField(in: host), "the sidebar search field has no text field")
        let fieldFrame = host.convert(field.bounds, from: field)
        #expect(host.isFlipped)
        #expect(measured.header != .zero, "the section header was never laid out")
        #expect(
            abs(measured.header.midY - fieldFrame.midY) <= 1,
            "the first section title is centred at \(measured.header.midY)pt, the search field at \(fieldFrame.midY)pt"
        )
    }

    private static func firstTextField(in view: NSView) -> NSTextField? {
        for subview in view.subviews {
            if let field = subview as? NSTextField, field.isEditable {
                return field
            }
            if let found = firstTextField(in: subview) {
                return found
            }
        }
        return nil
    }
}
