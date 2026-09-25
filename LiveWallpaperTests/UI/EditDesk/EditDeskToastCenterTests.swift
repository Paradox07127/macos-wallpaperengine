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

    @Test("A failure stays past 1.8s until it is dismissed")
    func failureStaysUntilDismissed() {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let center = EditDeskToastCenter(now: clock.read)
        let id = center.post("Couldn't apply", style: .failure)

        clock.advance(60)
        center.reap(at: clock.read())
        #expect(center.toasts.map(\.id) == [id], "A failure was reaped before the user closed it")

        center.dismiss(id)
        #expect(center.toasts.isEmpty)
    }

    @Test("A new Undo toast replaces only the older Undo toast, lasts 8s and holds while hovered; others keep 1.8s")
    func undoToastReplacesTheOlderOneAndHoldsWhileHovered() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1000))
        let center = EditDeskToastCenter(now: clock.read)
        center.post("Left span mode", style: .info)
        center.post("Applied to 1", style: .success, undoStepID: UUID())
        let newest = UUID()
        center.post("Applied to 2", style: .success, undoStepID: newest)
        #expect(center.toasts.map(\.text) == ["Left span mode", "Applied to 2"])

        clock.advance(2)
        center.reap(at: clock.read())
        #expect(center.toasts.map(\.undoStepID) == [newest], "the plain toast should go at 1.8s and the Undo toast stay")

        let undo = try #require(center.toasts.first)
        center.setHovering(true, for: undo.id)
        clock.advance(10)
        center.reap(at: clock.read())
        #expect(center.toasts.count == 1, "reaped while the pointer rested on it")

        center.setHovering(false, for: undo.id)
        clock.advance(5)
        center.reap(at: clock.read())
        #expect(center.toasts.count == 1, "the hovered time counted towards its 8s")
        clock.advance(2)
        center.reap(at: clock.read())
        #expect(center.toasts.isEmpty)
    }

    @Test("A newer toast for the same display replaces that display's failure")
    func newerToastForTheSameDisplayReplacesItsFailure() {
        let center = EditDeskToastCenter()
        center.post("Applied to 2", style: .success, screenID: 2)
        center.post("Failed on 1", style: .failure, screenID: 1)
        center.post("Applied to 1", style: .success, screenID: 1)
        #expect(center.toasts.map(\.text) == ["Applied to 2", "Applied to 1"])
    }
}
