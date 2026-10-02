import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
struct WallpaperOpeningSettingTests {
    private func scratchDefaults(variant: String = "", function: String = #function) throws -> (UserDefaults, String) {
        let suite = try TestScratch.defaultsSuite(prefix: "WallpaperOpeningSettingTests\(variant)", function: function)
        return (suite.defaults, suite.name)
    }

    @Test("An unset or unknown value reads as Loom Line")
    func defaultIsLoom() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(WallpaperOpeningChoice.defaultChoice == .loom)
        #expect(WallpaperOpeningChoice.stored(in: defaults) == .loom)
        defaults.set("curtain-call", forKey: WallpaperOpeningChoice.defaultsKey)
        #expect(WallpaperOpeningChoice.stored(in: defaults) == .loom)
    }

    @Test("Every choice round-trips through the stored key", arguments: WallpaperOpeningChoice.allCases)
    func choicePersists(choice: WallpaperOpeningChoice) throws {
        let (defaults, name) = try scratchDefaults(variant: ".\(choice.rawValue)")
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(choice.rawValue, forKey: WallpaperOpeningChoice.defaultsKey)
        #expect(WallpaperOpeningChoice.stored(in: defaults) == choice)
    }

    @Test("Settings search finds the row in Chinese and English", arguments: ["开场动画", "Opening animation", "opening"])
    func searchFindsTheRow(query: String) {
        let result = SettingsNavigation.filteredResults(matching: query, capabilities: .pro)
            .first { $0.destination == .general }
        #expect(result?.anchor == .generalWallpaper, "`\(query)` lands on \(result?.anchor?.rawValue ?? "nothing")")
    }

    @Test("Off resolves to no opening and each fixed choice to its own effect")
    func fixedChoicesResolve() {
        var generator = SystemRandomNumberGenerator()
        #expect(WallpaperOpeningEffect.resolve(.off, using: &generator) == nil)
        #expect(WallpaperOpeningEffect.resolve(.loom, using: &generator) == .loom)
        #expect(WallpaperOpeningEffect.resolve(.frame, using: &generator) == .frame)
        #expect(WallpaperOpeningEffect.resolve(.dawn, using: &generator) == .dawn)
    }

    @Test("Random reaches every opening effect")
    func randomCoversEveryEffect() {
        var generator = SystemRandomNumberGenerator()
        var seen = Set<WallpaperOpeningEffect>()
        for _ in 0 ..< 200 {
            if let effect = WallpaperOpeningEffect.resolve(.random, using: &generator) {
                seen.insert(effect)
            }
        }
        #expect(seen == Set(WallpaperOpeningEffect.allCases), "random only produced \(seen)")
    }

    @Test("Only Loom Line holds the new wallpaper on its first frame")
    func onlyLoomHoldsTheNewWallpaper() {
        #expect(WallpaperOpeningEffect.allCases.filter(\.holdsNewWallpaper) == [.loom])
    }
}
