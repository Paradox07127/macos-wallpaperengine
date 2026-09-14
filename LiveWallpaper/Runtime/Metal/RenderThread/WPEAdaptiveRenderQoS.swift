import Foundation

struct WPEAdaptiveRenderQoS {

    /// The two QoS tiers the thread moves between. `.economy` maps to
    /// `.utility` (E-core eligible); `.high` to `.userInteractive` (P-core).
    enum Level: Equatable {
        case economy
        case high
    }

    // Hysteresis: raise > lower keeps a dead zone (35%–60% of budget) so the level can't flap frame-to-frame.
    private let raiseFraction: Double
    private let lowerFraction: Double
    private let windowSize: Int

    /// Frame budget in seconds (1 / target-fps); a 30fps wallpaper must not be judged against a 60fps budget.
    private var budgetSeconds: Double

    private var samples: [Double]
    private var writeIndex = 0
    private var sampleCount = 0

    /// Frames still owed a forced `.high` after load/reload. Custom shaders are
    /// prewarmed, but first-frame PSO misses still must not be judged on E-cores.
    private var boostFramesRemaining = 0

    /// When false the thread is pinned at `.high` forever: `record` never returns a downgrade.
    let isEnabled: Bool

    private(set) var level: Level

    init(
        isEnabled: Bool,
        budgetSeconds: Double = 1.0 / 60.0,
        raiseFraction: Double = 0.60,
        lowerFraction: Double = 0.35,
        windowSize: Int = 90
    ) {
        self.isEnabled = isEnabled
        self.budgetSeconds = budgetSeconds > 0 ? budgetSeconds : 1.0 / 60.0
        self.raiseFraction = raiseFraction
        self.lowerFraction = lowerFraction
        self.windowSize = max(1, windowSize)
        self.samples = [Double](repeating: 0, count: max(1, windowSize))
        // Disabled ⇒ pinned high. Enabled ⇒ start economy and let the window earn
        // a promotion, so a light scene never spends a frame on the P-cores.
        self.level = isEnabled ? .economy : .high
    }

    mutating func setBudget(seconds: Double) {
        guard seconds > 0 else { return }
        budgetSeconds = seconds
    }

    /// Force `.high` for the next `frames` recorded frames (load/reload warm-up).
    /// Extends, never shortens, an in-flight boost.
    mutating func boost(frames: Int) {
        boostFramesRemaining = max(boostFramesRemaining, max(0, frames))
    }

    mutating func record(frameDuration seconds: Double) -> Level? {
        guard isEnabled else { return nil } // pinned high; nothing to decide
        samples[writeIndex] = max(0, seconds)
        writeIndex = (writeIndex + 1) % windowSize
        sampleCount = min(sampleCount + 1, windowSize)

        if boostFramesRemaining > 0 {
            boostFramesRemaining -= 1
            return promote(to: .high)
        }

        let p95 = percentile95()
        switch level {
        case .economy:
            if p95 > budgetSeconds * raiseFraction { return promote(to: .high) }
        case .high:
            if p95 < budgetSeconds * lowerFraction { return promote(to: .economy) }
        }
        return nil
    }

    private mutating func promote(to newLevel: Level) -> Level? {
        guard level != newLevel else { return nil }
        level = newLevel
        return newLevel
    }

    private func percentile95() -> Double {
        guard sampleCount > 0 else { return 0 }
        let window = sampleCount < windowSize
            ? Array(samples[0..<sampleCount])
            : samples
        let sorted = window.sorted()
        // Nearest-rank: index of the 95th percentile, clamped to the last element.
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    #if DEBUG
    var boostFramesRemainingForTesting: Int { boostFramesRemaining }
    #endif
}
