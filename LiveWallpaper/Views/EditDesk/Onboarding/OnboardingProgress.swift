import Foundation
import Observation

@MainActor @Observable
final class OnboardingProgress {
    enum Page: String, CaseIterable { case home, library, workshop, configuration, overlay, settings }

    static let storageKey = "loomscreen.ui.editDesk.onboarding.v1"
    static let legacyKey = "Onboarding.Completed"
    private static let pagesAddedAfter080: Set<Page> = [.configuration, .settings]

    var visiblePages: [Page] {
        Self.pages(workshopAvailable: workshopAvailable)
    }

    private(set) var hasPresentedTour = false
    private(set) var completed: Set<Page>
    private(set) var dismissed: Set<Page>
    @ObservationIgnored private let workshopAvailable: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults, legacyDefaults: UserDefaults, workshopAvailable: Bool) {
        self.defaults = defaults
        self.workshopAvailable = workshopAvailable
        if let snapshot = defaults.dictionary(forKey: Self.storageKey) {
            completed = Self.pages(in: snapshot, key: "completed")
            dismissed = Self.pages(in: snapshot, key: "dismissed")
            hasPresentedTour = snapshot["hasPresentedTour"] as? Bool ?? !completed.union(dismissed).isEmpty
            // Only records written by 0.8.0 or earlier lack hasPresentedTour; a tour they finished stays finished despite the added pages.
            if snapshot["hasPresentedTour"] == nil,
               visiblePages.filter({ !Self.pagesAddedAfter080.contains($0) }).allSatisfy(handled.contains) {
                dismissed.formUnion(Self.pagesAddedAfter080)
                persist()
            }
        } else {
            completed = legacyDefaults.bool(forKey: Self.legacyKey) ? Set(Page.allCases) : []
            dismissed = []
            persist()
        }
    }

    var handled: Set<Page> {
        completed.union(dismissed)
    }

    var isFinished: Bool {
        visiblePages.allSatisfy(handled.contains)
    }

    var currentPage: Page? {
        visiblePages.first { !handled.contains($0) }
    }

    func markTourPresented() {
        hasPresentedTour = true
        persist()
    }

    func record(_ page: Page) {
        completed.insert(page)
        dismissed.remove(page)
        persist()
    }

    func dismissRemaining() {
        dismissed.formUnion(visiblePages.filter { !completed.contains($0) })
        persist()
    }

    func reset() {
        hasPresentedTour = false
        completed.removeAll()
        dismissed.removeAll()
        persist()
    }

    private static func pages(workshopAvailable: Bool) -> [Page] {
        Page.allCases.filter { workshopAvailable || $0 != .workshop }
    }

    private static func pages(in snapshot: [String: Any], key: String) -> Set<Page> {
        Set((snapshot[key] as? [String] ?? []).compactMap(Page.init(rawValue:)))
    }

    private func persist() {
        let snapshot: [String: Any] = [
            "completed": Page.allCases.filter(completed.contains).map(\.rawValue),
            "dismissed": Page.allCases.filter(dismissed.contains).map(\.rawValue),
            "migratedFromLegacy": true,
            "hasPresentedTour": hasPresentedTour,
        ]
        defaults.set(snapshot, forKey: Self.storageKey)
    }
}
