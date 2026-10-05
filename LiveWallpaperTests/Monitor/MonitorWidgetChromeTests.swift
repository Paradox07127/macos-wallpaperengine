import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Monitor widget chrome")
struct MonitorWidgetChromeTests {
    // MARK: - The kind → symbol map

    @Test("Every widget kind's header glyph resolves to a real SF Symbol")
    func iconMapResolves() {
        for kind in MonitorWidgetKind.allCases {
            let name = WidgetFactory.icon(kind)
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                Comment(rawValue: "\(kind.rawValue) maps to \"\(name)\", which this system has no SF Symbol for")
            )
        }
    }

    /// Control group: without it the probe above passes on any string.
    @Test("The symbol probe rejects names that are not SF Symbols")
    func iconProbeDiscriminates() {
        #expect(NSImage(systemSymbolName: "trackpad", accessibilityDescription: nil) == nil)
        #expect(NSImage(systemSymbolName: "no.such.symbol.for.this.test", accessibilityDescription: nil) == nil)
    }

    // MARK: - Gauge column alignment

}
