import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Monitor widget chrome")
struct MonitorWidgetChromeTests {
    private static let widgetDirectory = "LiveWallpaper/Monitor/Widgets"

    /// Header glyphs that are a reading rather than an identity (battery level, interface
    /// type): deliberately not the kind map's icon, so the single-source rule lets them past.
    private static let stateDrivenHeaderGlyphs = ["powerSymbol", "headerSymbol"]

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

    // MARK: - Every tile header carries one

    @Test("Every board tile's WidgetContainer passes a header glyph")
    func everyHeaderCarriesAnIcon() throws {
        var scanned = 0
        for file in try Self.widgetSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for range in source.ranges(of: "WidgetContainer(") {
                scanned += 1
                // Argument order is label, systemImage, cellHeight …, so the
                // slice before `cellHeight:` is exactly where it would appear.
                let tail = source[range.upperBound...]
                let head = tail.range(of: "cellHeight:").map { String(tail[..<$0.lowerBound]) } ?? String(tail.prefix(400))
                #expect(
                    head.contains("systemImage:"),
                    Comment(rawValue: "\(file.lastPathComponent) builds a WidgetContainer with no systemImage: \(head.prefix(120))")
                )
            }
        }
        // Non-vacuity: a scan that found no call sites would pass silently.
        #expect(scanned >= 10, Comment(rawValue: "Only \(scanned) WidgetContainer call sites found; the scan is misconfigured"))
    }

    @Test("Header glyphs come from the shared kind map, not from per-widget literals")
    func headerIconsComeFromTheKindMap() throws {
        var scanned = 0
        for file in try Self.widgetSources() {
            let source = try String(contentsOf: file, encoding: .utf8)
            for range in source.ranges(of: "systemImage:") {
                scanned += 1
                let value = source[range.upperBound...]
                    .prefix(while: { $0 != "," && $0 != ")" && $0 != "\n" })
                    .trimmingCharacters(in: .whitespaces)
                // The one place the label names a parameter instead of an
                // argument: ProcessesWidgetView's `columnHeader(_:systemImage:…)`.
                if value == "String" {
                    continue
                }
                let fromMap = value.hasPrefix("WidgetFactory.icon(")
                let stateDriven = Self.stateDrivenHeaderGlyphs.contains(value)
                #expect(
                    fromMap || stateDriven,
                    Comment(rawValue: "\(file.lastPathComponent) passes systemImage: \(value) — route it through WidgetFactory.icon(_:)")
                )
            }
        }
        #expect(scanned >= 10, Comment(rawValue: "Only \(scanned) systemImage: arguments found; the scan is misconfigured"))
    }

    // MARK: - Gauge column alignment

    /// CPU and GPU size their gauge column from different places on purpose: GPU uses a
    /// literal, CPU must use `Self.gaugeSide(…)`, which also reserves the widest composition
    /// legend so the row stops reflowing as the reading crosses 10% or 100%.
    @Test("CPU and GPU pin their arc gauge to the same leading edge")
    func gaugeColumnsAreLeadingAligned() throws {
        let sites: [(file: String, declaration: String, literalWidth: Bool)] = [
            ("CPUWidgetView.swift", "private func mediumBody(cellHeight: CGFloat) -> some View {", false),
            ("CPUWidgetView.swift", "private func largeBody(cellHeight: CGFloat) -> some View {", false),
            ("GPUWidgetView.swift", "private var mediumBody: some View {", true),
            ("GPUWidgetView.swift", "private var largeBody: some View {", true),
        ]
        for site in sites {
            let source = try RepositoryRoot.source("\(Self.widgetDirectory)/\(site.file)")
            let body = try #require(
                Self.body(after: site.declaration, in: source),
                Comment(rawValue: "\(site.file) no longer declares \(site.declaration)")
            )
            let frame = try #require(
                Self.gaugeWidthFrame(in: body),
                Comment(rawValue: "\(site.file) \(site.declaration): no frame constrains the gauge column's width, so it floats with the ring")
            )
            #expect(
                frame.contains("alignment: .leading"),
                Comment(rawValue: "\(site.file) \(site.declaration): \(frame) fixes a width without a leading alignment, which re-centres the ring")
            )
            if site.literalWidth {
                #expect(
                    !frame.contains("gaugeSide"),
                    Comment(rawValue: "\(site.file) \(site.declaration) is the control group and should still size its own column")
                )
            } else {
                #expect(
                    frame.contains("Self.gaugeSide("),
                    Comment(rawValue: "\(site.file) \(site.declaration): \(frame) hardcodes the gauge column, which strands whatever the ring does not use")
                )
            }
        }
    }

    // MARK: - Scanning helpers

    /// Board tiles only: `Components/` holds shared pieces and preview scaffolding.
    private static func widgetSources() throws -> [URL] {
        let directory = RepositoryRoot.url(widgetDirectory)
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        #expect(!files.isEmpty, Comment(rawValue: "No widget sources under \(widgetDirectory)"))
        return files
    }

    private static func body(after declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            if source[index] == "{" {
                depth += 1
            }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[start.upperBound ..< index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// The first `.frame(...)` after the gauge that constrains WIDTH, flattened to one line.
    /// Not simply the first frame: CPU caps the ring's height on one call and pins the
    /// column's width on the next.
    private static func gaugeWidthFrame(in body: String) -> String? {
        guard let gauge = body.range(of: "ArcGauge(") else { return nil }
        var cursor = gauge.upperBound
        while let open = body.range(of: ".frame(", range: cursor ..< body.endIndex) {
            var depth = 1
            var index = open.upperBound
            while index < body.endIndex, depth > 0 {
                if body[index] == "(" {
                    depth += 1
                }
                if body[index] == ")" {
                    depth -= 1
                }
                index = body.index(after: index)
            }
            let call = body[open.lowerBound ..< index]
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            if call.contains("width:") {
                return call
            }
            cursor = index
        }
        return nil
    }
}
