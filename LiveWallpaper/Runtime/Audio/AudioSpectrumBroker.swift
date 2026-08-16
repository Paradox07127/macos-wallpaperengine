import Dispatch
import os

/// Pull-driven analysis source consulted by `snapshot()`; nil means the cached
/// frame is still current (no new samples, or inside the analyzer's cadence cap).
protocol AudioSpectrumAnalyzing: AnyObject, Sendable {
    func analyzeIfDue(nowNanos: UInt64) -> AudioSpectrumFrame?
}

/// Latest-spectrum cache for consumers; `snapshot()` pulls fresh analysis on demand.
final class AudioSpectrumBroker: Sendable {
    private struct State {
        var left: [Float]
        var right: [Float]
        var timestampNanos: UInt64
        var analyzer: (any AudioSpectrumAnalyzing)?
    }

    private let lock = OSAllocatedUnfairLock(
        initialState: State(
            left: [Float](repeating: 0, count: AudioSpectrumFrame.binCount),
            right: [Float](repeating: 0, count: AudioSpectrumFrame.binCount),
            timestampNanos: 0,
            analyzer: nil
        )
    )

    /// Capture service attaches its processor while running; nil detaches.
    func attachAnalyzer(_ analyzer: (any AudioSpectrumAnalyzing)?) {
        lock.withLock { $0.analyzer = analyzer }
    }

    func snapshot() -> AudioSpectrumFrame {
        lock.withLock { state in
            // Analysis runs on the pulling consumer's thread; concurrent
            // snapshots dedupe on this lock plus the analyzer's generation +
            // cadence check (later callers get the freshly cached frame).
            if let fresh = state.analyzer?.analyzeIfDue(nowNanos: DispatchTime.now().uptimeNanoseconds) {
                Self.copyChannel(fresh.left, into: &state.left)
                Self.copyChannel(fresh.right, into: &state.right)
                state.timestampNanos = fresh.timestampNanos
            }
            // Sanitizing copy-out so returned frame owns independent buffers (no COW).
            return AudioSpectrumFrame(
                left: state.left,
                right: state.right,
                timestampNanos: state.timestampNanos
            )
        }
    }

    func resetToSilence() {
        lock.withLock { state in
            for index in state.left.indices { state.left[index] = 0 }
            for index in state.right.indices { state.right[index] = 0 }
            state.timestampNanos = 0
        }
    }

    private static func copyChannel(_ source: [Float], into target: inout [Float]) {
        for index in target.indices {
            let value = index < source.count ? source[index] : 0
            target[index] = AudioSpectrumFrame.clamp(value)
        }
    }
}
