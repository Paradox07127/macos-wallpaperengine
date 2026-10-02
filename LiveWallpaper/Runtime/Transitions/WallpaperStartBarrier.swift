import CoreGraphics
import QuartzCore

/// What the displays released together share; nil (see `arrive`) means play the single-display way.
struct WallpaperSpanStart: Equatable {
    /// CACurrentMediaTime() at release.
    let hostTime: CFTimeInterval
    /// Union of the arrived displays' frames, AppKit global points (origin bottom-left).
    let canvas: CGRect
    /// 0..<1, drawn once per release.
    let seed: Float
    /// Each component 0.15...0.85, drawn once per release.
    let origin: SIMD2<Float>
    /// Every arrived frame straddles canvas.midY.
    let sharesGeometry: Bool
}

@MainActor
final class WallpaperStartBarrier {
    private let timeout: Duration
    private let now: () -> CFTimeInterval

    private var attempts: [CGDirectDisplayID: ObjectIdentifier] = [:]
    /// Announced displays that have not joined yet.
    private var expected: Set<CGDirectDisplayID> = []
    private var arrived: [CGDirectDisplayID: CGRect] = [:]
    private var departed: Set<CGDirectDisplayID> = []
    private var waiters: [CheckedContinuation<WallpaperSpanStart?, Never>] = []
    private var timeoutTask: Task<Void, Never>?

    private var isReleased = false
    private var releasedDisplays: Set<CGDirectDisplayID> = []
    private var releasedStart: WallpaperSpanStart?

    init(timeout: Duration = .seconds(1), now: @escaping () -> CFTimeInterval = { CACurrentMediaTime() }) {
        self.timeout = timeout
        self.now = now
    }

    func expect(_ display: CGDirectDisplayID) {
        guard attempts[display] == nil else { return }
        expected.insert(display)
    }

    func abandon(_ display: CGDirectDisplayID) {
        guard expected.remove(display) != nil else { return }
        releaseIfSettled()
    }

    /// A new attempt supersedes the display's previous one.
    func join(_ display: CGDirectDisplayID, attempt: ObjectIdentifier) {
        attempts[display] = attempt
        expected.remove(display)
        arrived.removeValue(forKey: display)
        departed.remove(display)
    }

    func leave(_ display: CGDirectDisplayID, attempt: ObjectIdentifier) {
        guard attempts[display] == attempt else { return }
        departed.insert(display)
        releaseIfSettled()
    }

    /// Waits, without honouring cancellation, until every member has arrived or left, or `timeout` after the first arrival.
    func arrive(_ display: CGDirectDisplayID, attempt: ObjectIdentifier, frame: CGRect) async -> WallpaperSpanStart? {
        guard !isReleased, attempts[display] == attempt else { return nil }
        arrived[display] = frame
        if timeoutTask == nil {
            timeoutTask = Task { @MainActor [weak self, timeout] in
                try? await Task.sleep(for: timeout)
                self?.release()
            }
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            releaseIfSettled()
        }
    }

    func start(for display: CGDirectDisplayID) -> WallpaperSpanStart? {
        releasedDisplays.contains(display) ? releasedStart : nil
    }

    private func releaseIfSettled() {
        let members = expected.union(attempts.keys)
        let settled = members.allSatisfy { arrived[$0] != nil || departed.contains($0) }
        if !arrived.isEmpty, settled {
            release()
        }
    }

    private func release() {
        guard !isReleased else { return }
        isReleased = true
        timeoutTask?.cancel()
        timeoutTask = nil

        if arrived.count >= 2 {
            let canvas = arrived.values.reduce(CGRect.null) { $0.union($1) }
            releasedDisplays = Set(arrived.keys)
            releasedStart = WallpaperSpanStart(
                hostTime: now(),
                canvas: canvas,
                seed: .random(in: 0 ..< 1),
                origin: SIMD2(.random(in: 0.15 ... 0.85), .random(in: 0.15 ... 0.85)),
                sharesGeometry: arrived.values.allSatisfy { $0.minY < canvas.midY && canvas.midY < $0.maxY }
            )
        }

        let released = waiters
        waiters = []
        for waiter in released {
            waiter.resume(returning: releasedStart)
        }
    }
}
