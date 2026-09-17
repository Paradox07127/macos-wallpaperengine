import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Cover capture generations")
@MainActor
struct CoverCaptureGenerationsTests {
    @Test("A claimed token is never reissued to a later capture")
    func tokensStayMonotonic() {
        CoverCaptureGenerations.resetForTesting()
        let id = UUID()
        let first = CoverCaptureGenerations.begin(id)
        let second = CoverCaptureGenerations.begin(id)
        #expect(!CoverCaptureGenerations.claim(first, for: id))
        #expect(CoverCaptureGenerations.claim(second, for: id))

        // The claim used to delete the entry, so the next capture restarted at 1 and the
        // still-in-flight first capture could claim it.
        let third = CoverCaptureGenerations.begin(id)
        #expect(third == second + 1)
        #expect(!CoverCaptureGenerations.claim(first, for: id), "an ABA token let a stale capture overwrite the newest cover")
        #expect(CoverCaptureGenerations.claim(third, for: id))
    }
}
