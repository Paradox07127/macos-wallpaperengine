#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Workshop mature reveal owner")
@MainActor
struct MatureRevealStateTests {
    @Test("Nothing is revealed until the user asks for it")
    func startsHidden() {
        let state = MatureRevealState()
        #expect(state.isRevealed(42) == false)
    }

    @Test("A reveal is keyed by item, so it survives paging and leaves its neighbours blurred")
    func revealIsPerItem() {
        let state = MatureRevealState()
        state.reveal(42)
        #expect(state.isRevealed(42))
        #expect(state.isRevealed(43) == false)
        state.reveal(43)
        #expect(state.isRevealed(42))
        #expect(state.isRevealed(43))
    }

    @Test("Revealing the same item twice is not an error and does not unreveal it")
    func revealIsIdempotent() {
        let state = MatureRevealState()
        state.reveal(42)
        state.reveal(42)
        #expect(state.isRevealed(42))
    }

    @Test("Clearing drops every reveal at once")
    func clearResetsEverything() {
        let state = MatureRevealState()
        state.reveal(42)
        state.reveal(43)
        state.clear()
        #expect(state.isRevealed(42) == false)
        #expect(state.isRevealed(43) == false)
    }
}
#endif
