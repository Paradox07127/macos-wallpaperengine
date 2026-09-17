import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Library drop tickets")
@MainActor
struct LibraryDropTicketsTests {
    @Test("A newer drop on the same display supersedes the older ticket; other displays are untouched")
    func newerDropSupersedes() {
        let tickets = LibraryDropTickets()
        let first = tickets.begin(screenID: 1)
        let other = tickets.begin(screenID: 2)
        #expect(tickets.isCurrent(first))
        let second = tickets.begin(screenID: 1)
        #expect(!tickets.isCurrent(first), "a drop whose locate finished late applied over the newer drop")
        #expect(tickets.isCurrent(second))
        #expect(tickets.isCurrent(other))
        tickets.invalidate(screenID: 1)
        #expect(!tickets.isCurrent(second))
    }
}
