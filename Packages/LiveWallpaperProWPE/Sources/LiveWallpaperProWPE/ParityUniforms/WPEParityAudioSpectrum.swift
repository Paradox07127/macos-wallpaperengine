public struct WPEParityAudioSpectrum: Sendable {
    private var peaks = [Float](repeating: 0, count: 16)
    private var smoothed = [Float](repeating: 0, count: 128)
    private var limited = [Float](repeating: 0, count: 128)
    private var output = [Float](repeating: 0, count: 128)

    public var left64: [Float] {
        Array(output.prefix(64))
    }

    public var right64: [Float] {
        Array(output.suffix(64))
    }

    /// The 64 left then 64 right published bins.
    public var bins: [Float] {
        output
    }

    public init() {}

    /// Provider bins are linear, dimensionless magnitudes in [0, +∞), not dB or clamped to 1; dt is seconds.
    /// `silence` denotes an absent Mac provider: publish zero while retaining normalization histories.
    /// A present provider with quiet bins follows the separate native threshold/peak-update path below.
    public mutating func advance(left: [Float], right: [Float], dt: Float, silence: Bool) {
        precondition(left.count == 64 && right.count == 64)
        precondition(dt.isFinite && dt >= 0)
        if silence {
            output = [Float](repeating: 0, count: 128)
            return
        }
        func bin(_ index: Int) -> Float { index < 64 ? left[index] : right[index - 64] }
        let maximum = max(left.reduce(Float(0), max), right.reduce(Float(0), max))
        let floor = 0.333 * maximum
        let quiet = maximum < 1e-4 // DAT_1404925fc, compared strictly at 140111c8c.

        // WPE 0x14011167a: sixteen peaks over eight contiguous bins each, left then right.
        if peaks[0] <= 1e-4, !quiet {
            peaks = [Float](repeating: 1, count: 16)
        }
        for group in peaks.indices {
            let start = group * 8
            let target = max(floor, (start ..< (start + 8)).reduce(Float(0)) { max($0, bin($1)) })
            let delta = target - peaks[group]
            if abs(delta) <= 1e-4 {
                peaks[group] = target
            } else {
                let step = min(abs(delta), min(1, dt))
                peaks[group] += step * (delta > 0 ? 1 : -0.5)
            }
        }

        // A present quiet provider updates peaks, then clears published bins without changing either history.
        if quiet {
            output = [Float](repeating: 0, count: 128)
            return
        }
        let smoothing = min(1, 20 * dt)
        let rateLimit = min(1, 40 * dt)
        for index in output.indices {
            let normalized = bin(index) / max(peaks[index / 8], 0.001)
            smoothed[index] += (normalized - smoothed[index]) * smoothing
            let delta = smoothed[index] - limited[index]
            limited[index] += max(-rateLimit, min(rateLimit, delta))
        }
        output = limited
    }

    public func uniforms() -> [String: WPECBufferValue] {
        var values: [String: WPECBufferValue] = [:]
        for (channel, bands64) in [("Left", left64), ("Right", right64)] {
            let bands32 = Self.pool(bands64)
            let bands16 = Self.pool(bands32)
            for (count, bands) in [(16, bands16), (32, bands32), (64, bands64)] {
                values["g_AudioSpectrum\(count)\(channel)"] = .array(
                    stride(from: 0, to: count, by: 4).map {
                        .vector(Array(bands[$0 ..< ($0 + 4)]))
                    }
                )
            }
        }
        return values
    }

    private static func pool(_ bands: [Float]) -> [Float] {
        stride(from: 0, to: bands.count, by: 2).map { max(bands[$0], bands[$0 + 1]) }
    }
}
