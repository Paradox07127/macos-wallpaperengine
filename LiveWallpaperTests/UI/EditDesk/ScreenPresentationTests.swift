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
        #expect(ScreenPresentation.statusText(pointSize: CGSize(width: 1920, height: 1080), isMain: false) == "1920×1080")
        let mainLabel = String(localized: "Main", bundle: .appLanguage)
        #expect(ScreenPresentation.statusText(pointSize: CGSize(width: 1920, height: 1080), isMain: true) == "1920×1080 · \(mainLabel)")
    }
}
