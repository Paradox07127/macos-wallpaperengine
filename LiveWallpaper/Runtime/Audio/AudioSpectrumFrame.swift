import Foundation

/// Stereo 64-bin spectrum frame; public init guarantees finite 0...1 and fixed lengths.
struct AudioSpectrumFrame: Equatable, Sendable {
    static let binCount = 64

    static let silence = AudioSpectrumFrame(
        validatedLeft: [Float](repeating: 0, count: binCount),
        validatedRight: [Float](repeating: 0, count: binCount),
        timestampNanos: 0
    )

    let left: [Float]
    let right: [Float]
    let timestampNanos: UInt64

    /// Sanitizing init (off hot path): exactly binCount finite 0...1 values.
    init(left: [Float], right: [Float], timestampNanos: UInt64) {
        self.left = Self.normalizedBins(left)
        self.right = Self.normalizedBins(right)
        self.timestampNanos = timestampNanos
    }

    /// Fast-path init for already-valid processor output (no sanitizing copy).
    init(validatedLeft: [Float], validatedRight: [Float], timestampNanos: UInt64) {
        self.left = validatedLeft
        self.right = validatedRight
        self.timestampNanos = timestampNanos
    }

    static func normalizedBins(_ bins: [Float]) -> [Float] {
        normalizedBins(bins, count: binCount)
    }

    static func normalizedBins(_ bins: [Float], count: Int) -> [Float] {
        let resolvedCount = max(0, count)
        guard resolvedCount > 0 else { return [] }

        var normalized: [Float] = []
        normalized.reserveCapacity(resolvedCount)

        for value in bins.prefix(resolvedCount) {
            normalized.append(clamp(value))
        }

        if normalized.count < resolvedCount {
            normalized.append(contentsOf: repeatElement(0, count: resolvedCount - normalized.count))
        }

        return normalized
    }

    /// Non-finite → 0; finite clamped to 0...1.
    static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
