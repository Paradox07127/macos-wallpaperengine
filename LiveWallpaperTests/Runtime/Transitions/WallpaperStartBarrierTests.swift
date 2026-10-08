import CoreGraphics
@testable import LiveWallpaper
import QuartzCore
import Testing

private enum FirstAttempt {}
private enum SecondAttempt {}
private let first = ObjectIdentifier(FirstAttempt.self)
private let second = ObjectIdentifier(SecondAttempt.self)

private let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
private let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
private let farRight = CGRect(x: 3840, y: 0, width: 1920, height: 1080)

@MainActor
private final class PendingArrival {
    private(set) var isFinished = false
    private var task: Task<WallpaperSpanStart?, Never>?

    init(
        _ barrier: WallpaperStartBarrier,
        _ display: CGDirectDisplayID,
        attempt: ObjectIdentifier,
        frame: @autoclosure @escaping @MainActor () -> CGRect?
    ) {
        task = Task { @MainActor in
            let start = await barrier.arrive(display, attempt: attempt, frame: frame())
            self.isFinished = true
            return start
        }
    }

    var value: WallpaperSpanStart? {
        get async { await task!.value }
    }
}

/// A display's live frame; nil once it is unplugged.
@MainActor
private final class LiveFrame {
    var frame: CGRect?

    init(_ frame: CGRect) {
        self.frame = frame
    }
}

@MainActor
private func settle() async {
    for _ in 0 ..< 20 {
        await Task.yield()
    }
}

@Suite("Wallpaper start barrier")
@MainActor
struct WallpaperStartBarrierTests {
    @Test("Two joined displays wait for each other and share one payload", .timeLimit(.minutes(1)))
    func twoDisplaysShareOnePayload() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30), now: { 42 })
        barrier.join(1, attempt: first)
        barrier.join(2, attempt: first)

        let one = PendingArrival(barrier, 1, attempt: first, frame: left)
        await settle()
        #expect(!one.isFinished)

        let two = await barrier.arrive(2, attempt: first, frame: right)
        let start = await one.value
        #expect(start != nil)
        #expect(start == two)
        #expect(start?.hostTime == 42)
        #expect(start?.canvas == left.union(right))
        if let start {
            #expect((0 ..< 1).contains(start.seed))
            #expect((0.15 ... 0.85).contains(start.origin.x))
            #expect((0.15 ... 0.85).contains(start.origin.y))
        }
    }

    @Test("One arrival plus one leave releases with nothing to share", .timeLimit(.minutes(1)))
    func leaveReleasesSingleArrival() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        barrier.join(1, attempt: first)
        barrier.join(2, attempt: first)

        let one = PendingArrival(barrier, 1, attempt: first, frame: left)
        await settle()
        #expect(!one.isFinished)

        barrier.leave(2, attempt: first)
        #expect(await one.value == nil)
    }

    @Test("Two of three arrive and the third leaves: the two share a payload", .timeLimit(.minutes(1)))
    func twoOfThreeArriveThirdLeaves() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        for display: CGDirectDisplayID in [1, 2, 3] {
            barrier.join(display, attempt: first)
        }

        let one = PendingArrival(barrier, 1, attempt: first, frame: left)
        let two = PendingArrival(barrier, 2, attempt: first, frame: right)
        await settle()
        #expect(!one.isFinished)

        barrier.leave(3, attempt: first)
        let startOne = await one.value
        let startTwo = await two.value
        #expect(startOne != nil)
        #expect(startOne == startTwo)
        #expect(startOne?.canvas == left.union(right))
    }

    @Test("A superseded attempt cannot leave or arrive", .timeLimit(.minutes(1)))
    func supersededAttemptIsIgnored() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        barrier.join(1, attempt: first)
        barrier.join(2, attempt: first)
        barrier.join(1, attempt: second)

        let two = PendingArrival(barrier, 2, attempt: first, frame: right)
        await settle()
        barrier.leave(1, attempt: first)
        await settle()
        #expect(!two.isFinished)

        let elapsed = await ContinuousClock().measure {
            #expect(await barrier.arrive(1, attempt: first, frame: left) == nil)
        }
        #expect(elapsed < .seconds(10))
        #expect(!two.isFinished)

        barrier.leave(1, attempt: second)
        #expect(await two.value == nil)
    }

    @Test("The timeout releases the arrived displays; a later arrival gets nil", .timeLimit(.minutes(1)))
    func timeoutReleasesArrivedDisplays() async {
        let barrier = WallpaperStartBarrier(timeout: .milliseconds(50))
        for display: CGDirectDisplayID in [1, 2, 3] {
            barrier.join(display, attempt: first)
        }

        async let one = barrier.arrive(1, attempt: first, frame: left)
        async let two = barrier.arrive(2, attempt: first, frame: right)
        let (startOne, startTwo) = await (one, two)
        #expect(startOne != nil)
        #expect(startOne == startTwo)

        #expect(await barrier.arrive(3, attempt: first, frame: farRight) == nil)
        #expect(barrier.start(for: 3) == nil)
    }

    @Test("An expected display holds the release until it is abandoned", .timeLimit(.minutes(1)))
    func expectedDisplayHoldsUntilAbandoned() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        barrier.join(1, attempt: first)
        barrier.join(2, attempt: first)
        barrier.expect(3)

        let one = PendingArrival(barrier, 1, attempt: first, frame: left)
        let two = PendingArrival(barrier, 2, attempt: first, frame: right)
        await settle()
        #expect(!one.isFinished)
        #expect(!two.isFinished)

        barrier.abandon(3)
        let startOne = await one.value
        #expect(startOne != nil)
        #expect(await two.value == startOne)
    }

    @Test("A single member is released at once with nothing to share", .timeLimit(.minutes(1)))
    func singleMemberGetsNil() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        barrier.join(1, attempt: first)

        let elapsed = await ContinuousClock().measure {
            #expect(await barrier.arrive(1, attempt: first, frame: left) == nil)
        }
        #expect(elapsed < .seconds(10))
    }

    @Test(
        "Displays share geometry only when every frame straddles the canvas midline",
        .timeLimit(.minutes(1)),
        arguments: [
            (right, true),
            (CGRect(x: 0, y: 1080, width: 1920, height: 1080), false),
            (CGRect(x: 1920, y: 400, width: 1920, height: 1080), true),
            (CGRect(x: 1920, y: 1000, width: 800, height: 600), false),
        ]
    )
    func sharesGeometry(other: CGRect, shares: Bool) async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        barrier.join(1, attempt: first)
        barrier.join(2, attempt: first)

        async let one = barrier.arrive(1, attempt: first, frame: left)
        async let two = barrier.arrive(2, attempt: first, frame: other)
        let (start, _) = await (one, two)
        #expect(start?.sharesGeometry == shares)
    }

    @Test("start(for:) answers only for displays released together", .timeLimit(.minutes(1)))
    func startForReleasedDisplaysOnly() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        for display: CGDirectDisplayID in [1, 2, 3, 4] {
            barrier.join(display, attempt: first)
        }

        let one = PendingArrival(barrier, 1, attempt: first, frame: left)
        let two = PendingArrival(barrier, 2, attempt: first, frame: right)
        await settle()
        #expect(barrier.start(for: 1) == nil)

        barrier.leave(3, attempt: first)
        barrier.leave(4, attempt: first)
        let start = await one.value
        _ = await two.value
        #expect(start != nil)
        #expect(barrier.start(for: 1) == start)
        #expect(barrier.start(for: 2) == start)
        #expect(barrier.start(for: 3) == nil)

        #expect(await barrier.arrive(4, attempt: first, frame: farRight) == nil)
        #expect(barrier.start(for: 4) == nil)
    }

    @Test("A display moved after release gives every display the moved canvas and the release's draw", .timeLimit(.minutes(1)))
    func movedDisplayRecomputesCanvas() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30), now: { 42 })
        barrier.join(1, attempt: first)
        barrier.join(2, attempt: first)
        let liveTwo = LiveFrame(right)

        let one = PendingArrival(barrier, 1, attempt: first, frame: left)
        await settle()
        let released = await barrier.arrive(2, attempt: first, frame: liveTwo.frame)
        #expect(await one.value == released)
        #expect(barrier.start(for: 1) == released)
        #expect(barrier.start(for: 2) == released)

        let moved = CGRect(x: 1920, y: 1080, width: 1920, height: 1080)
        liveTwo.frame = moved
        let startOne = barrier.start(for: 1)
        #expect(startOne?.canvas == left.union(moved))
        #expect(startOne?.sharesGeometry == false)
        #expect(barrier.start(for: 2) == startOne)
        #expect(startOne?.hostTime == released?.hostTime)
        #expect(startOne?.seed == released?.seed)
        #expect(startOne?.origin == released?.origin)
    }

    @Test("An unplugged display drops out of the span; one display left plays alone", .timeLimit(.minutes(1)))
    func unpluggedDisplayDropsOut() async {
        let barrier = WallpaperStartBarrier(timeout: .seconds(30))
        for display: CGDirectDisplayID in [1, 2, 3] {
            barrier.join(display, attempt: first)
        }
        let liveTwo = LiveFrame(right)
        let liveThree = LiveFrame(farRight)

        let one = PendingArrival(barrier, 1, attempt: first, frame: left)
        let two = PendingArrival(barrier, 2, attempt: first, frame: liveTwo.frame)
        await settle()
        let released = await barrier.arrive(3, attempt: first, frame: liveThree.frame)
        _ = await (one.value, two.value)
        #expect(released?.canvas == left.union(farRight))

        liveThree.frame = nil
        #expect(barrier.start(for: 3) == nil)
        #expect(barrier.start(for: 1)?.canvas == left.union(right))
        #expect(barrier.start(for: 2) == barrier.start(for: 1))

        liveTwo.frame = nil
        #expect(barrier.start(for: 1) == nil)
    }

    @Test("A manual entry inside a manual group reuses it")
    func manualActionReusesManualGroup() {
        let outer = WallpaperSwitchGroup(pace: .manual)
        WallpaperSwitchGroup.$current.withValue(outer) {
            #expect(WallpaperSwitchGroup.forManualAction() === outer)
        }
    }

    @Test("A manual entry inside an automatic group starts its own manual group")
    func manualActionLeavesAutomaticGroup() {
        let outer = WallpaperSwitchGroup(pace: .automatic)
        WallpaperSwitchGroup.$current.withValue(outer) {
            let group = WallpaperSwitchGroup.forManualAction()
            #expect(group !== outer)
            #expect(group.pace == .manual)
        }
    }

    @Test("A manual entry with no enclosing group starts a manual group")
    func manualActionWithoutGroup() {
        #expect(WallpaperSwitchGroup.current == nil)
        let group = WallpaperSwitchGroup.forManualAction()
        #expect(group.pace == .manual)
        #expect(group !== WallpaperSwitchGroup.forManualAction())
    }
}
