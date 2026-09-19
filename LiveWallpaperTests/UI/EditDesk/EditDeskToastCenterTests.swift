import Foundation
@testable import LiveWallpaper
import Testing

private final class TestClock: @unchecked Sendable { // single `Date`, guarded by `lock`
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        current = start
    }

    func read() -> Date {
        lock.withLock { current }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

@MainActor
@Suite("EditDeskToastCenter")
struct EditDeskToastCenterTests {
    @Test("A posted toast is visible")
    func postIsVisible() {
        let center = EditDeskToastCenter()
        center.post("Applied", style: .success)
        #expect(center.toasts.count == 1)
        #expect(center.toasts.first?.text == "Applied")
    }

    @Test("A third post evicts the oldest, keeping at most two visible")
    func thirdPostEvictsOldest() {
        let center = EditDeskToastCenter()
        center.post("First", style: .info)
        center.post("Second", style: .info)
        center.post("Third", style: .info)
        #expect(center.toasts.map(\.text) == ["Second", "Third"])
    }

    @Test("A toast expires 1.8s after it was posted, driven by an injected clock")
    func expiryAfterDuration() {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let center = EditDeskToastCenter(now: clock.read)
        center.post("Applied", style: .success)

        clock.advance(1.7)
        center.reap(at: clock.read())
        #expect(center.toasts.count == 1, "Evicted before its 1.8s were up")

        clock.advance(0.1)
        center.reap(at: clock.read())
        #expect(center.toasts.isEmpty, "Still visible past its 1.8s duration")
    }

    #if !LITE_BUILD
    @Test("A Workshop event is mirrored once per token, not once per observation")
    func workshopEventMirroredOncePerToken() {
        let center = EditDeskToastCenter()
        let event = WorkshopToastEvent(
            token: 1,
            headline: "Applied",
            title: "Aurora",
            message: "Applied to Main Display",
            isSuccess: true
        )

        center.mirror(event)
        center.mirror(event)
        #expect(center.toasts.count == 1, "The same token was mirrored twice")

        let nextEvent = WorkshopToastEvent(
            token: 2,
            headline: "Applied",
            title: "Nightfall",
            message: "Applied to Main Display",
            isSuccess: true
        )
        center.mirror(nextEvent)
        #expect(center.toasts.count == 2, "A new token was not mirrored")
    }
    #endif
}
