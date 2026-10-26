@testable import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Empty state clearing action")
@MainActor
struct EmptyStateClearingActionTests {
    @Test("The clear button names what is narrowing the results")
    func titleMatchesWhatIsActive() {
        #expect(EmptyStateButtonAction.clearing(search: true, filters: true) {}?.title
            == LocalizedStringKey("Clear search and filters"))
        #expect(EmptyStateButtonAction.clearing(search: true, filters: false) {}?.title
            == LocalizedStringKey("Clear search"))
        #expect(EmptyStateButtonAction.clearing(search: false, filters: true) {}?.title
            == LocalizedStringKey("Clear filters"))
        #expect(EmptyStateButtonAction.clearing(search: false, filters: false) {} == nil)
    }
}
