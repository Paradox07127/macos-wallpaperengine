import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// The glass backing must not add layout footprint to the navigation control.
@Suite("GlassSegmentedPicker shells")
struct GlassSegmentedPickerShellTests {

    @MainActor
    @Test("The glass backing costs the pill no width or height")
    func glassBackingAddsNoFootprint() {
        let picker = Self.probePicker().fixedSize()
        // SCREENS S1's geometry, rebuilt by hand: item height 26 with 14pt each side,
        // 2pt between items, 3pt around the row.
        let reference = HStack(spacing: 2) {
            ForEach(Self.probeTitles, id: \.self) { title in
                Text(verbatim: title).frame(height: 26).padding(.horizontal, 14)
            }
        }
        .padding(3)
        .fixedSize()

        let measured = NSHostingView(rootView: picker).fittingSize
        let expected = NSHostingView(rootView: reference).fittingSize
        #expect(measured.width > 0)
        #expect(
            abs(measured.width - expected.width) < 0.5 && abs(measured.height - expected.height) < 0.5,
            Comment(rawValue: "pill measures \(measured), the unbacked row measures \(expected)")
        )
    }

    @MainActor
    @Test("The detail shell is as tall as the toolbar groups beside it")
    func detailShellMatchesToolbarHeight() {
        let picker = GlassSegmentedPicker(
            selection: .constant("square.grid.2x2"),
            values: ["square.grid.2x2", "list.bullet"],
            shell: .detail,
            label: { symbol, _ in Image(systemName: symbol) }
        )
        .fixedSize()
        let measured = NSHostingView(rootView: picker).fittingSize
        #expect(
            abs(measured.height - GlassToolbarMetrics.height) < 0.5,
            Comment(rawValue: "detail picker measures \(measured.height)pt, toolbar groups \(GlassToolbarMetrics.height)pt")
        )
    }

    @MainActor
    @Test("Each icon segment reads as the name its caller passed")
    func iconSegmentsReadAsTheirNames() {
        let names = ["square.grid.2x2": "Wallpaper", "list.bullet": "Overlays"]
        let picker = GlassSegmentedPicker(
            selection: .constant("square.grid.2x2"),
            values: ["square.grid.2x2", "list.bullet"],
            shell: .detail,
            segmentName: { Text(verbatim: names[$0] ?? "") },
            label: { symbol, _ in Image(systemName: symbol) }
        )
        #expect(Self.buttonLabels(in: picker) == ["Wallpaper", "Overlays"])
    }

    @MainActor
    @Test("Each titled segment reads as its title")
    func titledSegmentsReadAsTheirTitles() {
        let picker = GlassSegmentedPicker(selection: .constant(1), values: [1, 2], shell: .flat) { value in
            value == 1 ? "Small" : "Large"
        }
        #expect(Self.buttonLabels(in: picker) == ["Small", "Large"])
    }

    // MARK: Probe

    /// The AX labels of the buttons SwiftUI hands to assistive technology, in tree order.
    @MainActor
    private static func buttonLabels(in view: some View) -> [String] {
        // SwiftUI builds no AX nodes until an assistive client asks for them; this is what VoiceOver sets.
        let enhancedUI = "AXEnhancedUserInterface"
        let setAttribute = Selector(("accessibilitySetValue:forAttribute:"))
        NSApplication.shared.perform(setAttribute, with: NSNumber(value: true), with: enhancedUI)
        defer { NSApplication.shared.perform(setAttribute, with: NSNumber(value: false), with: enhancedUI) }
        let host = NSHostingView(rootView: view.fixedSize())
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: host.fittingSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        var labels: [String] = []
        func walk(_ element: Any) {
            let object = element as AnyObject
            if object.accessibilityRole?() == .button {
                labels.append(object.accessibilityLabel?() ?? "")
            }
            for child in object.accessibilityChildren?() ?? [] {
                walk(child)
            }
        }
        walk(host)
        return labels
    }

    private static let probeTitles = ["AAAA", "BBBB"]

    @MainActor
    private static func probePicker() -> some View {
        GlassSegmentedPicker(
            selection: .constant(probeTitles[0]),
            values: probeTitles,
            shell: .editDesk
        ) { title, _ in
            Text(verbatim: title)
        }
    }
}
