import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Edit Desk screen presentation")
struct ScreenPresentationTests {
    @Test("Badge text for each display kind")
    func badgeTextForEachKind() {
        #expect(ScreenPresentation.badgeText(kind: .macBookPro, diagonalInches: 16, refreshRate: 120) == "MACBOOK PRO · 16″ · 120 Hz")
        #expect(ScreenPresentation.badgeText(kind: .macBookAir, diagonalInches: 13, refreshRate: 60) == "MACBOOK AIR · 13″ · 60 Hz")
        #expect(ScreenPresentation.badgeText(kind: .builtinOther, diagonalInches: 24, refreshRate: 60) == "BUILT-IN · 24″ · 60 Hz")
        #expect(ScreenPresentation.badgeText(kind: .studioDisplay, diagonalInches: 27, refreshRate: 60) == "STUDIO DISPLAY · 27″ · 60 Hz")
        #expect(ScreenPresentation.badgeText(kind: .proDisplayXDR, diagonalInches: 32, refreshRate: 60) == "PRO DISPLAY XDR · 32″ · 60 Hz")
        #expect(ScreenPresentation.badgeText(kind: .external, diagonalInches: 32, refreshRate: 240) == "EXTERNAL · 32″ · 240 Hz")
    }

    @Test("Nil diagonal omits the inch segment")
    func nilDiagonalOmitsInchSegment() {
        #expect(ScreenPresentation.badgeText(kind: .external, diagonalInches: nil, refreshRate: 240) == "EXTERNAL · 240 Hz")
    }

    @Test("Diagonal inches round to the nearest integer")
    func diagonalRoundsToNearestInteger() {
        #expect(ScreenPresentation.badgeText(kind: .macBookPro, diagonalInches: 15.6, refreshRate: 120) == "MACBOOK PRO · 16″ · 120 Hz")
    }

    @Test("A renamed external display shows macOS's own name in the badge, cut to 20 characters")
    func renamedExternalBadgeShowsTheSystemName() {
        #expect(
            ScreenPresentation.badgeText(kind: .external, systemName: "Dell U2720Q", diagonalInches: 27, refreshRate: 60)
                == "DELL U2720Q · 27″ · 60 Hz"
        )
        let long = String(repeating: "ABCDEFGHIJ", count: 3)
        #expect(
            ScreenPresentation.badgeText(kind: .external, systemName: long, diagonalInches: nil, refreshRate: 60)
                == "ABCDEFGHIJABCDEFGHIJ… · 60 Hz"
        )
    }

    @Test("A built-in display keeps its model word, and an external one without a system name keeps EXTERNAL")
    func systemNameLeavesOtherBadgesAlone() {
        #expect(
            ScreenPresentation.badgeText(kind: .macBookPro, systemName: "Built-in Retina Display", diagonalInches: 16, refreshRate: 120)
                == "MACBOOK PRO · 16″ · 120 Hz"
        )
        #expect(ScreenPresentation.badgeText(kind: .external, systemName: nil, diagonalInches: 27, refreshRate: 60) == "EXTERNAL · 27″ · 60 Hz")
    }

    @Test("Built-in classification reads the raw model-identifier prefix when that's all it's given")
    func builtinClassification() {
        #expect(ScreenPresentation.kind(isBuiltin: true, localizedName: "Built-in Retina Display", productName: "MacBookPro18,3") == .macBookPro)
        #expect(ScreenPresentation.kind(isBuiltin: true, localizedName: "Built-in Retina Display", productName: "MacBookAir10,1") == .macBookAir)
        #expect(ScreenPresentation.kind(isBuiltin: true, localizedName: "Built-in Retina Display", productName: "Mac14,7") == .builtinOther)
    }

    /// Apple Silicon model identifiers (Mac14,7, Mac15,12, Mac16,x…) don't carry a
    /// MacBookPro/MacBookAir prefix; only the IORegistry marketing name does.
    @Test("Built-in classification recognizes the Apple Silicon marketing product name")
    func builtinClassificationByMarketingProductName() {
        #expect(ScreenPresentation.kind(isBuiltin: true, localizedName: "Built-in Retina Display", productName: "MacBook Pro") == .macBookPro)
        #expect(ScreenPresentation.kind(isBuiltin: true, localizedName: "Built-in Retina Display", productName: "MacBook Air") == .macBookAir)
        #expect(ScreenPresentation.kind(isBuiltin: true, localizedName: "Built-in Retina Display", productName: "Mac mini") == .builtinOther)
    }

    @Test("Built-in classification falls back to the raw model-identifier prefix when the product name is unavailable")
    func builtinClassificationFallsBackWhenProductNameMissing() {
        #expect(ScreenPresentation.kind(isBuiltin: true, localizedName: "Built-in Retina Display", productName: "MacBookPro16,1") == .macBookPro)
    }

    @Test("External classification reads the localized name, case-insensitively")
    func externalClassification() {
        #expect(ScreenPresentation.kind(isBuiltin: false, localizedName: "Studio Display", productName: "") == .studioDisplay)
        #expect(ScreenPresentation.kind(isBuiltin: false, localizedName: "studio display", productName: "") == .studioDisplay)
        #expect(ScreenPresentation.kind(isBuiltin: false, localizedName: "Pro Display XDR", productName: "") == .proDisplayXDR)
        #expect(ScreenPresentation.kind(isBuiltin: false, localizedName: "PRO DISPLAY XDR", productName: "") == .proDisplayXDR)
        #expect(ScreenPresentation.kind(isBuiltin: false, localizedName: "LG UltraFine", productName: "") == .external)
    }

    @Test("Status text with and without the main display suffix")
    func statusTextMainSuffix() {
        #expect(ScreenPresentation.statusText(pixelSize: CGSize(width: 1920, height: 1080), isMain: false) == "1920×1080")
        let mainLabel = String(localized: "Main", bundle: .appLanguage)
        #expect(ScreenPresentation.statusText(pixelSize: CGSize(width: 1920, height: 1080), isMain: true) == "1920×1080 · \(mainLabel)")
    }

    @MainActor
    @Test("Retina display labels use mode pixels while stage layout keeps points")
    func retinaResolutionDoesNotChangeStageGeometry() throws {
        let nsScreen = PresentationTestScreen()
        // Preserve the unapplied function reference used by DisplayRegistry and fixtures.
        let makeScreen: (NSScreen) -> Screen = Screen.init(nsScreen:)
        #expect(makeScreen(nsScreen).frame == nsScreen.frame)
        var modeReads = 0
        let screen = Screen(nsScreen: nsScreen, displayPixelSize: { id in
            #expect(id == PresentationTestScreen.displayID)
            modeReads += 1
            return CGSize(width: 3840, height: 2160)
        })
        let presentation = ScreenPresentation.presentation(for: screen, refreshRate: 60)
        #expect(presentation.status == "3840×2160")
        #expect(screen.frame == CGRect(x: 0, y: 0, width: 1920, height: 1080))
        #expect(modeReads == 1)
        let model = EditDeskStageModel()
        model.reduceMotion = true
        model.displays = [StageDisplay(
            id: screen.id, fingerprint: screen.displayFingerprint, frame: screen.frame,
            isBuiltin: false, name: screen.name, badgeText: presentation.badge,
            statusText: presentation.status, cover: nil, state: .empty
        )]
        let view = EditDeskStageView(model: model)
        defer { view.detach() }
        view.frame = CGRect(origin: .zero, size: StageGeometry.designWindow)
        view.layoutSubtreeIfNeeded()
        let children = try #require(view.accessibilityChildren() as? [NSAccessibilityElement])
        #expect(children.contains { $0.accessibilityLabel() == "Retina Fixture, 3840×2160" })
        #expect(model.displays[0].frame.size == CGSize(width: 1920, height: 1080))
    }

    @MainActor
    @Test("A refreshed Screen captures mode pixels independently of point frame and backing scale")
    func refreshedModeUsesReportedPixels() {
        // A scaled mode need not be inferred from logical frame times backing scale.
        let screen = Screen(nsScreen: PresentationTestScreen(), displayPixelSize: { _ in
            CGSize(width: 5120, height: 2880)
        })
        #expect(ScreenPresentation.presentation(for: screen, refreshRate: 60).status == "5120×2880")
        #expect(screen.frame.size == CGSize(width: 1920, height: 1080))
    }

    @Test("Missing display mode omits resolution instead of labelling points as pixels")
    func missingModeOmitsResolution() {
        #expect(ScreenPresentation.statusText(pixelSize: nil, isMain: false).isEmpty)
        #expect(ScreenPresentation.statusText(pixelSize: nil, isMain: true)
            == String(localized: "Main", bundle: .appLanguage))
    }

}

private final class PresentationTestScreen: NSScreen {
    static let displayID: CGDirectDisplayID = 0x6D1D_0F01
    override var frame: NSRect {
        NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    override var visibleFrame: NSRect {
        frame
    }

    override var backingScaleFactor: CGFloat {
        2
    }

    override var localizedName: String {
        "Retina Fixture"
    }

    override var deviceDescription: [NSDeviceDescriptionKey: Any] {
        [NSDeviceDescriptionKey("NSScreenNumber"): Self.displayID]
    }
}
