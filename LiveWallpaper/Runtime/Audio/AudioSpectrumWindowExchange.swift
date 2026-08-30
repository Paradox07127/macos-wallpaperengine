import os

/// SPSC hand-off of the newest analysis window. The producer (audio IO thread) owns the
/// history ring and staging window; the sealed window lives inside the lock, and the consumer
/// copies it out while holding that lock, so no sample slot is ever reachable from both sides
/// — a stalled consumer misses whole generations rather than reading a window assembled from
/// two of them. @unchecked Sendable: `ringLeft`/`ringRight`/`stageLeft`/`stageRight`/
/// `producedSamples` are touched only by the producer inside `publish`; everything both sides
/// reach lives inside `sealed`'s unfair lock.
final class AudioSpectrumWindowExchange: @unchecked Sendable {
    /// Where a sealed window sits in the stream: it covers
    /// `(totalSamples - windowSize)..<totalSamples`.
    struct Cursor: Equatable, Sendable {
        var totalSamples: Int
        var timestampNanos: UInt64
    }

    /// The sealed buffers live inside the lock's state so "sealed samples are only
    /// touched under the lock" is structural rather than a convention.
    private struct Sealed {
        var left: UnsafeMutableBufferPointer<Float>
        var right: UnsafeMutableBufferPointer<Float>
        var cursor: Cursor
    }

    let windowSize: Int
    /// Retained history, and the staleness bound the consumer applies to a window it has
    /// already taken. Four windows: the hand-off itself needs one, the other three keep
    /// the hop clamp and drop thresholds the spectrum was tuned against unchanged.
    let historyCapacity: Int

    private let historyMask: Int
    private let ringLeft: UnsafeMutableBufferPointer<Float>
    private let ringRight: UnsafeMutableBufferPointer<Float>
    private var stageLeft: UnsafeMutableBufferPointer<Float>
    private var stageRight: UnsafeMutableBufferPointer<Float>
    private var producedSamples = 0
    private let sealed: OSAllocatedUnfairLock<Sealed>

    #if DEBUG
    /// Test seam: runs while the consumer holds the lock, between the two channel
    /// copies, so a test can let the producer run for real during a copy.
    var midCopyHookForTesting: (() -> Void)?
    #endif

    init(windowSize: Int) {
        precondition(windowSize > 0 && windowSize & (windowSize - 1) == 0)
        let capacity = windowSize * 4
        self.windowSize = windowSize
        self.historyCapacity = capacity
        self.historyMask = capacity - 1

        self.ringLeft = Self.makeZeroedBuffer(capacity)
        self.ringRight = Self.makeZeroedBuffer(capacity)
        self.stageLeft = Self.makeZeroedBuffer(windowSize)
        self.stageRight = Self.makeZeroedBuffer(windowSize)
        self.sealed = OSAllocatedUnfairLock(
            uncheckedState: Sealed(
                left: Self.makeZeroedBuffer(windowSize),
                right: Self.makeZeroedBuffer(windowSize),
                cursor: Cursor(totalSamples: 0, timestampNanos: 0)
            )
        )
    }

    deinit {
        ringLeft.deallocate()
        ringRight.deallocate()
        // Staging and sealed swap places on every hand-off, so releasing both sides
        // releases the same four buffers whichever way the last swap landed.
        stageLeft.deallocate()
        stageRight.deallocate()
        sealed.withLockUnchecked { state in
            state.left.deallocate()
            state.right.deallocate()
        }
    }

    private static func makeZeroedBuffer(_ count: Int) -> UnsafeMutableBufferPointer<Float> {
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        buffer.initialize(repeating: 0)
        return buffer
    }

    // MARK: - Producer (audio IO thread)

    /// Append the callback's samples to the ring, re-seal the newest window, and hand it over.
    /// Bounded and allocation-free: `frameCount` ring writes plus one `windowSize` block copy
    /// per channel. Non-blocking: the hand-off takes the lock only if free; a miss just defers
    /// publication by one callback — samples stay in the ring, so the next seal still carries them.
    func publish(left: [Float], right: [Float], timestampNanos: UInt64) {
        let frameCount = max(left.count, right.count)
        guard frameCount > 0 else { return }
        // Oversized batch (never from the HAL): only the freshest historyCapacity fit.
        let dropped = max(frameCount - historyCapacity, 0)
        appendToRing(
            ringLeft,
            samples: left,
            from: dropped,
            count: frameCount - dropped,
            at: producedSamples + dropped
        )
        appendToRing(
            ringRight,
            samples: right,
            from: dropped,
            count: frameCount - dropped,
            at: producedSamples + dropped
        )
        producedSamples += frameCount

        stageNewestWindow(from: ringLeft, into: stageLeft)
        stageNewestWindow(from: ringRight, into: stageRight)

        let cursor = Cursor(totalSamples: producedSamples, timestampNanos: timestampNanos)
        _ = sealed.withLockIfAvailableUnchecked { state in
            swap(&state.left, &self.stageLeft)
            swap(&state.right, &self.stageRight)
            state.cursor = cursor
        }
    }

    /// Shorter channel zero-pads (the HAL always delivers matched counts). Non-finite
    /// samples are zeroed here so staging stays a plain block move; the consumer used to
    /// sanitize once per analyzed window instead.
    private func appendToRing(
        _ ring: UnsafeMutableBufferPointer<Float>,
        samples: [Float],
        from sourceStart: Int,
        count: Int,
        at ringStart: Int
    ) {
        for offset in 0..<count {
            let sourceIndex = sourceStart + offset
            let sample = sourceIndex < samples.count ? samples[sourceIndex] : 0
            ring[(ringStart + offset) & historyMask] = sample.isFinite ? sample : 0
        }
    }

    /// Ring → contiguous staging window (the last `windowSize` samples), as at most two
    /// block copies. Before the first full window the wrapped start lands on slots the
    /// producer has not reached yet, which still hold their initial zeros — the same
    /// left-padding the consumer used to synthesize.
    private func stageNewestWindow(
        from ring: UnsafeMutableBufferPointer<Float>,
        into stage: UnsafeMutableBufferPointer<Float>
    ) {
        let start = (producedSamples - windowSize) & historyMask
        let head = min(windowSize, historyCapacity - start)
        stage.baseAddress!.update(from: ring.baseAddress! + start, count: head)
        if head < windowSize {
            (stage.baseAddress! + head).update(from: ring.baseAddress!, count: windowSize - head)
        }
    }

    // MARK: - Consumer

    /// The producer's published position, without taking the window.
    func publishedCursor() -> Cursor {
        sealed.withLockUnchecked { $0.cursor }
    }

    /// Copy the sealed window into `left`/`right` and return the cursor it was sealed at.
    /// The copy runs under the lock, so the producer can only miss a hand-off while it
    /// runs — it can never write into the window being copied.
    func copySealedWindow(into left: inout [Float], and right: inout [Float]) -> Cursor {
        sealed.withLockUnchecked { state in
            Self.copyOut(state.left, into: &left)
            #if DEBUG
            midCopyHookForTesting?()
            #endif
            Self.copyOut(state.right, into: &right)
            return state.cursor
        }
    }

    private static func copyOut(
        _ source: UnsafeMutableBufferPointer<Float>,
        into target: inout [Float]
    ) {
        target.withUnsafeMutableBufferPointer { buffer in
            guard let destination = buffer.baseAddress, let origin = source.baseAddress else { return }
            destination.update(from: origin, count: min(buffer.count, source.count))
        }
    }
}
