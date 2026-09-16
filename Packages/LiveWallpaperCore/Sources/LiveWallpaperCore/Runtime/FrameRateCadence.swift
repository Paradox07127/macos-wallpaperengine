import Foundation

/// Selects display ticks against a cumulative clock, so fractional refresh ratios
/// preserve the average content rate without queuing catch-up frames.
public struct FrameRateCadence: Sendable {
    private var nextDeadline: Double?
    private var previousTimestamp: Double?
    private var previousFPS: Int?

    public init() {}

    public mutating func reset() {
        nextDeadline = nil
        previousTimestamp = nil
        previousFPS = nil
    }

    public mutating func shouldRender(at timestamp: Double, framesPerSecond: Int) -> Bool {
        guard timestamp.isFinite else { return false }
        let fps = max(1, framesPerSecond)
        let interval = 1 / Double(fps)
        if previousFPS != fps || previousTimestamp.map({ timestamp < $0 }) == true {
            reset()
        }
        previousFPS = fps
        previousTimestamp = timestamp
        guard let deadline = nextDeadline else {
            nextDeadline = timestamp + interval
            return true
        }
        // Only compensate floating-point noise, not half a refresh period.
        let epsilon = 0.000_001
        guard timestamp + epsilon >= deadline else { return false }
        let elapsedIntervals = max(1, floor((timestamp - deadline + epsilon) / interval) + 1)
        nextDeadline = deadline + elapsedIntervals * interval
        return true
    }

    /// Exact divisors can sleep between frames. Other rates use every display tick
    /// to distribute the shorter and longer presentation intervals as evenly as possible.
    public static func driverFramesPerSecond(target: Int, display: Int) -> Int {
        let refresh = max(1, display)
        let target = min(max(1, target), refresh)
        return refresh.isMultiple(of: target) ? target : refresh
    }
}
