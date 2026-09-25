import AppKit
@testable import LiveWallpaperCore
import SwiftUI
import Testing

/// SCREENS.md S6's colour column, measured against the running app in
/// `.notes/evidence/ui/editdesk/s6-fidelity-2026-09-19.md` §B.
@Suite("Edit Desk detail tokens")
struct EditDeskDetailTokenTests {
    /// Resolves a token under one appearance; nil when the colour will not convert to sRGB.
    private static func resolved(_ color: Color, _ name: NSAppearance.Name) -> NSColor? {
        var value: NSColor?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            value = NSColor(color).usingColorSpace(.sRGB)
        }
        return value
    }

    private static func channels(_ color: Color, _ name: NSAppearance.Name) throws -> (Int, Int, Int, Double) {
        let ns = try #require(resolved(color, name))
        return (
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded()),
            Double(ns.alphaComponent)
        )
    }

    @Test("The three dark text greys carry the design's blue cast")
    func darkTextGreysAreBlueTinted() throws {
        let expected: [(String, Color, (Int, Int, Int))] = [
            ("textPrimary", DesignTokens.EditDesk.Colors.textPrimary, (232, 232, 236)),
            ("textSecondary", DesignTokens.EditDesk.Colors.textSecondary, (154, 154, 163)),
            ("textTertiary", DesignTokens.EditDesk.Colors.textTertiary, (138, 138, 147)),
        ]
        for (name, color, want) in expected {
            let (r, g, b, _) = try Self.channels(color, .darkAqua)
            #expect((r, g, b) == want, "\(name) is \(r),\(g),\(b) — expected \(want)")
        }
    }

    @Test("Stroke and fill opacities match the design")
    func strokeOpacitiesMatchDesign() throws {
        let expected: [(String, Color, Double)] = [
            ("fillNavPill", DesignTokens.EditDesk.Colors.fillNavPill, 0.05),
            ("strokeRegular", DesignTokens.EditDesk.Colors.strokeRegular, 0.08),
            ("strokePanel", DesignTokens.EditDesk.Colors.strokePanel, 0.12),
            ("strokeShell", DesignTokens.EditDesk.Colors.strokeShell, 0.25),
        ]
        for (name, color, want) in expected {
            let (_, _, _, alpha) = try Self.channels(color, .darkAqua)
            #expect(abs(alpha - want) < 0.001, "\(name) is \(alpha) — expected \(want)")
        }
    }
}
