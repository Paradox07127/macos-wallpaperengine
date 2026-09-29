import Foundation
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Onboarding progress")
struct OnboardingProgressTests {
    @Test("Fresh progress filters Workshop from the visible pages", arguments: [false, true])
    func fresh(workshopAvailable: Bool) throws {
        let stores = try Stores(variant: ".\(workshopAvailable)")
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: workshopAvailable)
        #expect(progress.completed.isEmpty)
        #expect(progress.dismissed.isEmpty)
        #expect(progress.currentPage == .home)
        #expect(!progress.isFinished)
        #expect(progress.visiblePages == (workshopAvailable ? [.home, .library, .workshop, .configuration, .overlay, .settings] : [.home, .library, .configuration, .overlay, .settings]))
        #expect(stores.defaults.dictionary(forKey: OnboardingProgress.storageKey)?["migratedFromLegacy"] as? Bool == true)
    }

    @Test("Legacy true, false and missing are checked once", arguments: [true, false, nil] as [Bool?])
    func migration(legacy: Bool?) throws {
        let stores = try Stores(variant: ".\(String(describing: legacy))")
        defer { stores.remove() }
        if let legacy {
            stores.legacy.set(legacy, forKey: OnboardingProgress.legacyKey)
        }
        #expect(stores.defaults.object(forKey: OnboardingProgress.storageKey) == nil)
        let progress = stores.progress()
        #expect(progress.completed == (legacy == true ? Set(OnboardingProgress.Page.allCases) : []))
        #expect(progress.isFinished == (legacy == true))
        let snapshot = try #require(stores.defaults.dictionary(forKey: OnboardingProgress.storageKey))
        #expect(Set(snapshot.keys) == ["completed", "dismissed", "migratedFromLegacy", "hasPresentedTour"])
        #expect(snapshot["migratedFromLegacy"] as? Bool == true)
        #expect(stores.legacy.object(forKey: OnboardingProgress.legacyKey) as? Bool == legacy)
    }

    @Test("Reset survives recreation even when legacy remains true")
    func resetAfterMigration() throws {
        let stores = try Stores()
        defer { stores.remove() }
        stores.legacy.set(true, forKey: OnboardingProgress.legacyKey)
        let progress = stores.progress()
        progress.reset()
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
        #expect(stores.progress().completed.isEmpty)
    }

    @Test("Recorded and dismissed pages jointly finish the tour", arguments: [false, true])
    func handling(workshopAvailable: Bool) throws {
        let stores = try Stores(variant: ".\(workshopAvailable)")
        defer { stores.remove() }
        stores.defaults.set([
            "completed": [], "dismissed": ["home"], "migratedFromLegacy": true,
        ], forKey: OnboardingProgress.storageKey)
        let progress = stores.progress(workshopAvailable: workshopAvailable)
        #expect(progress.handled == [.home])
        #expect(progress.completed.isEmpty)
        #expect(progress.currentPage == .library)
        progress.record(.home)
        progress.record(.home)
        #expect(progress.completed == [.home])
        #expect(progress.dismissed.isEmpty)
        progress.dismissRemaining()
        #expect(progress.isFinished)
        #expect(progress.currentPage == nil)
        let reloaded = stores.progress(workshopAvailable: workshopAvailable)
        #expect(reloaded.completed == progress.completed)
        #expect(reloaded.dismissed == progress.dismissed)
        progress.reset()
        #expect(progress.handled.isEmpty)
    }

    @Test("Skipping the rest dismisses what is left and keeps what was completed", arguments: [false, true])
    func skippingTheRestFinishesTheTour(workshopAvailable: Bool) throws {
        let stores = try Stores(variant: ".\(workshopAvailable)")
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: workshopAvailable)
        progress.record(.home)
        progress.dismissRemaining()
        #expect(progress.isFinished)
        #expect(progress.completed == [.home])
        let reloaded = stores.progress(workshopAvailable: workshopAvailable)
        #expect(reloaded.completed == progress.completed)
        #expect(reloaded.dismissed == progress.dismissed)
    }

    @Test("Lite and Pro read the same saved record against their own visible pages")
    func liteAndProAgreement() throws {
        let stores = try Stores()
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: false)
        for page in progress.visiblePages {
            progress.record(page)
        }
        #expect(progress.isFinished)
        #expect(!stores.progress(workshopAvailable: true).isFinished)
        #expect(stores.progress(workshopAvailable: true).currentPage == .workshop)
    }

    @Test("Next works without importing or signing in", arguments: [false, true])
    func explicitAdvancement(workshopAvailable: Bool) throws {
        let stores = try Stores(variant: ".\(workshopAvailable)")
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: workshopAvailable)
        #expect(progress.handled.isEmpty)
        #expect(progress.currentPage == .home)
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { workshopAvailable })
        let guide = PageGuideSession()
        guide.startTour(progress: progress, router: router)
        for _ in 0 ..< guide.stepCount {
            guide.next()
        }
        #expect(guide.context == nil)
        #expect(progress.isFinished)
        #expect(stores.progress(workshopAvailable: workshopAvailable).isFinished)
        progress.reset()
    }

    @Test("Resuming starts at the first unfinished page")
    func resumesUnfinishedPage() throws {
        let stores = try Stores()
        defer { stores.remove() }
        let progress = stores.progress()
        progress.record(.home)
        progress.record(.library)
        let guide = PageGuideSession()
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { true })
        guide.startTour(progress: progress, router: router)
        #expect(guide.tourPage == .workshop)
        #expect(router.page == .workshop)
        #expect(guide.stepNumber == PageGuideContext.overview.steps.count + PageGuideContext.library.steps.count + 1)
        #expect(!progress.isFinished)
    }

    @Test("External navigation closes a tour while its own routing preserves it")
    func externalNavigationClosesTour() throws {
        let stores = try Stores()
        defer { stores.remove() }
        let progress = stores.progress()
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { true })
        let guide = PageGuideSession()
        guide.startTour(progress: progress, router: router)
        guide.closeIfOutsideRoute(router)
        #expect(guide.isTour)
        for _ in PageGuideContext.overview.steps {
            guide.next()
        }
        guide.closeIfOutsideRoute(router)
        #expect(guide.tourPage == .library)
        router.openSettings(.general)
        guide.closeIfOutsideRoute(router)
        #expect(guide.context == nil)
        #expect(progress.completed == [.home])
        guide.startTour(progress: progress, router: router, from: .configuration)
        guide.closeIfOutsideRoute(router)
        #expect(guide.isTour)
        router.closeDetail()
        guide.closeIfOutsideRoute(router)
        #expect(guide.context == nil)
    }

    @Test("Closing a guide leaves no step for a pending geometry update")
    func closingClearsCurrentStep() {
        let guide = PageGuideSession()
        #expect(guide.currentStep == nil)
        guide.start(.workshop)
        #expect(guide.currentStep != nil)
        guide.close()
        #expect(guide.currentStep == nil)
        guide.start(.workshop)
        for _ in PageGuideContext.workshop.steps {
            guide.next()
        }
        #expect(guide.currentStep == nil)
    }

    @Test("Every page guide can move back, finish, close and reopen")
    func pageGuides() {
        let session = PageGuideSession()
        for context in PageGuideContext.allCases {
            session.start(context)
            #expect(!context.steps.isEmpty)
            session.next()
            session.back()
            #expect(session.index == 0)
            for _ in context.steps {
                session.next()
            }
            #expect(session.context == nil)
            session.start(context)
            #expect(session.index == 0)
            session.close()
            #expect(session.context == nil)
        }
    }

    @Test("Floating tour routes pages, goes back, preserves unfinished steps and finishes", arguments: [false, true])
    func floatingTour(workshopAvailable: Bool) throws {
        let stores = try Stores(variant: ".\(workshopAvailable)")
        defer { stores.remove() }
        let progress = stores.progress(workshopAvailable: workshopAvailable)
        let router = EditDeskRouter(initialNavigation: nil, initialAddWallpaperRequest: nil, isWorkshopAvailable: { workshopAvailable })
        let guide = PageGuideSession()
        guide.startTour(progress: progress, router: router)
        #expect(guide.tourPage == .home)
        guide.next()
        guide.close()
        #expect(progress.handled.isEmpty)
        #expect(stores.progress(workshopAvailable: workshopAvailable).hasPresentedTour)
        guide.startTour(progress: progress, router: router)
        for _ in guide.steps {
            guide.next()
        }
        #expect(guide.tourPage == .library)
        #expect(router.page == .library)
        guide.back()
        #expect(guide.tourPage == .home)
        #expect(router.page == .home)
        guide.next()
        #expect(guide.tourPage == .library)
        var count = 0
        let total = guide.stepCount
        while guide.context != nil, count < 100 {
            let previous = guide.stepNumber
            #expect(guide.stepCount == total)
            guide.next()
            if guide.context != nil {
                #expect(guide.stepNumber == previous + 1)
            }
            count += 1
        }
        #expect(count < 100)
        #expect(progress.isFinished)
        #expect(router.page == .settings)
        #expect(guide.context == nil)
    }

    @MainActor
    private struct Stores {
        let name: String
        let legacyName: String
        let defaults: UserDefaults
        let legacy: UserDefaults

        /// Parameterized tests pass their argument as `variant`: parallel cases must not share a suite.
        init(variant: String = "", function: String = #function) throws {
            let current = try TestScratch.defaultsSuite(prefix: "OnboardingProgressTests\(variant)", function: function)
            let previous = try TestScratch.defaultsSuite(prefix: "OnboardingProgressTests.legacy\(variant)", function: function)
            (name, defaults) = (current.name, current.defaults)
            (legacyName, legacy) = (previous.name, previous.defaults)
        }

        func progress(workshopAvailable: Bool = true) -> OnboardingProgress {
            OnboardingProgress(defaults: defaults, legacyDefaults: legacy, workshopAvailable: workshopAvailable)
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            legacy.removePersistentDomain(forName: legacyName)
        }
    }
}
