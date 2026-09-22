import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Onboarding progress")
struct OnboardingProgressTests {
    @Test("Fresh progress filters Workshop and renumbers the visible steps", arguments: [false, true])
    func fresh(workshopAvailable: Bool) throws {
        let stores = try Stores()
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: workshopAvailable)
        #expect(progress.completed.isEmpty)
        #expect(progress.dismissed.isEmpty)
        #expect(progress.currentPage == .home)
        #expect(!progress.isFinished)
        #expect(progress.visiblePages == (workshopAvailable ? [.home, .library, .workshop, .overlay] : [.home, .library, .overlay]))
        #expect(progress.stepNumber(of: .overlay) == (workshopAvailable ? 4 : 3))
        #expect(stores.defaults.dictionary(forKey: OnboardingProgress.storageKey)?["migratedFromLegacy"] as? Bool == true)
    }

    @Test("Legacy true, false and missing are checked once", arguments: [true, false, nil] as [Bool?])
    func migration(legacy: Bool?) throws {
        let stores = try Stores()
        defer { stores.remove() }
        if let legacy {
            stores.legacy.set(legacy, forKey: OnboardingProgress.legacyKey)
        }
        #expect(stores.isHandled() == (legacy == true))
        #expect(stores.defaults.object(forKey: OnboardingProgress.storageKey) == nil)
        let progress = stores.progress()
        #expect(progress.completed == (legacy == true ? Set(OnboardingProgress.Page.allCases) : []))
        #expect(progress.isFinished == (legacy == true))
        #expect(stores.isHandled() == progress.isFinished)
        let snapshot = try #require(stores.defaults.dictionary(forKey: OnboardingProgress.storageKey))
        #expect(Set(snapshot.keys) == ["completed", "dismissed", "migratedFromLegacy"])
        #expect(snapshot["migratedFromLegacy"] as? Bool == true)
        #expect(stores.legacy.object(forKey: OnboardingProgress.legacyKey) as? Bool == legacy)
    }

    @Test("Reset survives recreation even when legacy remains true")
    func resetAfterMigration() throws {
        let stores = try Stores()
        defer { stores.remove() }
        stores.legacy.set(true, forKey: OnboardingProgress.legacyKey)
        #expect(stores.isHandled())
        let progress = stores.progress()
        progress.reset()
        #expect(!stores.isHandled())
        let reloaded = stores.progress()
        #expect(reloaded.completed.isEmpty && reloaded.dismissed.isEmpty)
        #expect(reloaded.currentPage == .home)
        #expect(stores.defaults.dictionary(forKey: OnboardingProgress.storageKey)?["migratedFromLegacy"] as? Bool == true)
        #expect(stores.legacy.bool(forKey: OnboardingProgress.legacyKey))
    }

    @Test("A later legacy flag does not overwrite an existing fresh record")
    func legacyChangesAfterMigration() throws {
        let stores = try Stores()
        defer { stores.remove() }
        _ = stores.progress()
        stores.legacy.set(true, forKey: OnboardingProgress.legacyKey)
        #expect(!stores.isHandled())
        #expect(stores.progress().completed.isEmpty)
    }

    @Test("Recorded and dismissed pages jointly finish the tour", arguments: [false, true])
    func handling(workshopAvailable: Bool) throws {
        let stores = try Stores()
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: workshopAvailable)
        progress.dismiss(.home)
        #expect(progress.handled == [.home])
        #expect(progress.completed.isEmpty)
        #expect(progress.currentPage == .library)
        progress.record(.home)
        progress.record(.home)
        #expect(progress.completed == [.home])
        #expect(progress.dismissed.isEmpty)
        for page in progress.visiblePages where page != .home {
            progress.dismiss(page)
        }
        #expect(progress.isFinished)
        #expect(progress.currentPage == nil)
        #expect(stores.isHandled(workshopAvailable: workshopAvailable))
        let reloaded = stores.progress(workshopAvailable: workshopAvailable)
        #expect(reloaded.completed == progress.completed)
        #expect(reloaded.dismissed == progress.dismissed)
        progress.reset()
        #expect(progress.handled.isEmpty)
        #expect(!stores.isHandled(workshopAvailable: workshopAvailable))
    }

    @Test("Static startup check uses the visible pages in the saved record")
    func liteAndProAgreement() throws {
        let stores = try Stores()
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: false)
        for page in progress.visiblePages {
            progress.record(page)
        }
        #expect(stores.isHandled(workshopAvailable: false))
        #expect(!stores.isHandled(workshopAvailable: true))
        #expect(stores.progress(workshopAvailable: true).currentPage == .workshop)
    }

    @MainActor
    private struct Stores {
        let name = "OnboardingProgressTests.\(UUID())"
        let legacyName = "OnboardingProgressTests.legacy.\(UUID())"
        let defaults: UserDefaults
        let legacy: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            legacy = try #require(UserDefaults(suiteName: legacyName))
        }

        func progress(workshopAvailable: Bool = true) -> OnboardingProgress {
            OnboardingProgress(defaults: defaults, legacyDefaults: legacy, workshopAvailable: workshopAvailable)
        }

        func isHandled(workshopAvailable: Bool = true) -> Bool {
            OnboardingProgress.isHandled(defaults: defaults, legacyDefaults: legacy, workshopAvailable: workshopAvailable)
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            legacy.removePersistentDomain(forName: legacyName)
        }
    }
}
