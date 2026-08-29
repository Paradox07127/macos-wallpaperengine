import AppKit
import Foundation
import Testing
@testable import LiveWallpaper

@Suite("App appearance preference")
struct AppAppearanceTests {

    private func scratchDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        UserDefaults(suiteName: name)!
    }

    @Test("System means no override, which is the only way to keep tracking macOS")
    func systemMapsToNoOverride() {
        #expect(AppAppearance.system.appearanceName == nil)
        #expect(AppAppearance.light.appearanceName == .aqua)
        #expect(AppAppearance.dark.appearanceName == .darkAqua)
    }

    @Test("An unset or unrecognized stored value reads as system, never as a pinned mode")
    func unknownStoredValueFallsBackToSystem() {
        let defaults = scratchDefaults()
        #expect(AppAppearance.stored(in: defaults) == .system)

        defaults.set("sepia", forKey: AppAppearance.defaultsKey)
        #expect(AppAppearance.stored(in: defaults) == .system)

        defaults.set(AppAppearance.dark.rawValue, forKey: AppAppearance.defaultsKey)
        #expect(AppAppearance.stored(in: defaults) == .dark)
    }

    @MainActor
    @Test("Applying pins the application appearance, and system clears it")
    func applyingSetsAndClearsTheOverride() {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }

        AppAppearance.dark.apply(to: application)
        #expect(application.appearance?.name == .darkAqua)

        AppAppearance.light.apply(to: application)
        #expect(application.appearance?.name == .aqua)

        AppAppearance.system.apply(to: application)
        #expect(application.appearance == nil)
    }
}
