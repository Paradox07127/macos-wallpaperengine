import Foundation
import Observation

@MainActor @Observable
final class OnboardingProgress {
    enum Page: String, CaseIterable { case home, library, workshop, overlay }

    static let storageKey = "loomscreen.ui.editDesk.onboarding.v1"
    static let legacyKey = "Onboarding.Completed"

    var visiblePages: [Page] {
        Self.pages(workshopAvailable: workshopAvailable)
    }

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

    func stepNumber(of page: Page) -> Int {
        visiblePages.firstIndex(of: page).map { $0 + 1 } ?? 0
    }

    func record(_ page: Page) {
        completed.insert(page)
        dismissed.remove(page)
        persist()
    }

    func dismiss(_ page: Page) {
        dismissed.insert(page)
        persist()
    }

    func reset() {
        completed.removeAll()
        dismissed.removeAll()
        persist()
    }

    static func isHandled(defaults: UserDefaults, legacyDefaults: UserDefaults, workshopAvailable: Bool) -> Bool {
        guard let snapshot = defaults.dictionary(forKey: storageKey) else {
            return legacyDefaults.bool(forKey: legacyKey)
        }
        let handled = pages(in: snapshot, key: "completed").union(pages(in: snapshot, key: "dismissed"))
        return pages(workshopAvailable: workshopAvailable).allSatisfy(handled.contains)
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
        ]
        defaults.set(snapshot, forKey: Self.storageKey)
    }
}
