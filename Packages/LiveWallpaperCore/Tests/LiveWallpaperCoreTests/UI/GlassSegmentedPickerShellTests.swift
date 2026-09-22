import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// WP 7B: the Edit Desk nav pill's shell is native Liquid Glass and its selected item is one
/// token-filled capsule that slides between segments. `.glass` and `.flat` are pinned here so
/// the change cannot leak into the other two hosts.
@Suite("GlassSegmentedPicker shells")
struct GlassSegmentedPickerShellTests {
    private static func source(_ relativePath: String) throws -> String {
        // Tests/LiveWallpaperCoreTests/UI/<this file> — the package root is four levels up.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func pickerSource() throws -> String {
        try source("Sources/LiveWallpaperCore/UI/Components/GlassSegmentedPicker.swift")
    }

    /// One `case .<name>:` body, cut at the next case or the switch's own closing brace —
    /// reading to the end of the file would let an unrelated helper satisfy the assertions.
    private static func shellCase(_ name: String, in source: String) throws -> String {
        let lines = source.components(separatedBy: "\n")
        let header = try #require(
            lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "case .\(name):" },
            Comment(rawValue: "no `case .\(name):` in the shell switch")
        )
        let body = lines[(header + 1)...].prefix {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("case .") && trimmed != "}"
        }
        #expect(!body.isEmpty, Comment(rawValue: "`case .\(name):` has an empty body"))
        return body.joined(separator: "\n")
    }

    @Test("The editDesk shell is backed by native glass, not the hand-painted pill fill")
    func editDeskShellIsGlass() throws {
        let source = try Self.pickerSource()
        let editDesk = try Self.shellCase("editDesk", in: source)
        #expect(editDesk.contains("adaptiveGlassSurface(.capsule, interactive: true)"))
        #expect(!editDesk.contains("Capsule()"), "a hand-drawn capsule under the glass is a second backing")
        #expect(!source.contains("fillNavPill"), "the painted pill fill is what the glass replaces")
        #expect(
            !source.contains("strokeRegular"),
            "adaptiveGlassSurface draws the interactive outline itself; a second one is two hairlines"
        )
    }

    @Test("The glass and flat shells are untouched")
    func otherShellsAreUnchanged() throws {
        let source = try Self.pickerSource()
        let glass = try Self.shellCase("glass", in: source)
        #expect(glass.contains("row.adaptiveGlassSurface(.capsule, interactive: true)"))
        let flat = try Self.shellCase("flat", in: source)
        #expect(flat.contains("row.background(Capsule().fill(Color.gray.opacity(0.18)))"))
        #expect(source.contains("Color.accentColor.opacity(0.35)"), "the non-editDesk selected fill is unchanged")
    }

    @Test("The selected item is one sliding capsule and the pill carries no second glass layer")
    func selectionSlidesOnASingleSource() throws {
        let source = try Self.pickerSource()
        #expect(
            source.components(separatedBy: "matchedGeometryEffect(").count - 1 == 1,
            "a sliding indicator has exactly one geometry source"
        )
        #expect(source.contains("@Namespace"))
        #expect(source.contains("DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))"))
        for banned in ["glassEffectID(", "glassEffectUnion(", "GlassEffect", "AdaptiveGlassContainer", "drawingGroup("] {
            #expect(!source.contains(banned), Comment(rawValue: "\(banned) adds a second glass or raster layer"))
        }
    }

    /// `\.accessibilityReduceTransparency` is get-only, so the setting cannot be forced into a
    /// rendered probe; this walks the chain the pill now hands the job to instead.
    @Test("Reduce Transparency leaves the pill an opaque backing, not a translucent one")
    func reduceTransparencyBackingIsOpaque() throws {
        let picker = try Self.pickerSource()
        #expect(
            !picker.contains("reduceTransparency"),
            "the shell must not grow a second fallback branch beside adaptiveGlassSurface's"
        )
        let adaptive = try Self.source("Sources/LiveWallpaperCore/UI/Components/AdaptiveGlass.swift")
        let surface = try #require(adaptive.range(of: "private struct AdaptiveGlassSurfaceModifier"))
        let body = String(adaptive[surface.lowerBound...])
        #expect(body.contains("if reduceTransparency {"))
        #expect(body.contains("shape.fill(Color(nsColor: .windowBackgroundColor))"))

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var alpha: CGFloat = -1
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                alpha = NSColor.windowBackgroundColor.usingColorSpace(.sRGB)?.alphaComponent ?? -1
            }
            #expect(alpha == 1, Comment(rawValue: "windowBackgroundColor is \(alpha) under \(appearance.rawValue)"))
        }
    }

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

    // MARK: Probe

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
