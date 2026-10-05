import Foundation
import Testing

/// The background fallback must honour the accessibility display settings.
@Suite("Edit Desk canvas accessibility fallback — source contract")
struct EditDeskCanvasOwnershipTests {
    private static let canvasOwner = "LiveWallpaper/Views/EditDesk/Shell/EditDeskBackdrop.swift"

    @Test("The canvas falls back to the flat fill under Reduce Transparency and Increase Contrast")
    func theCanvasFallsBackForAccessibility() throws {
        let backdrop = try RepositoryRoot.source(Self.canvasOwner)
        #expect(backdrop.contains("accessibilityReduceTransparency"))
        #expect(backdrop.contains("colorSchemeContrast"))
        #expect(backdrop.contains("if frosted, !reduceTransparency, contrast != .increased"), "the blur is not gated on both settings")
    }
}
