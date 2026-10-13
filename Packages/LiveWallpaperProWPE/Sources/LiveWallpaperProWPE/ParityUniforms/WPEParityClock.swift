/// WPE's frame clock (140110630.c:645-724, 14017fa70.c:213-223).
public struct WPEParityClock: Sendable {
    public static let minimumStep: Float = 1e-4
    public static let maximumStep: Float = 0.25
    public static let wrapTime: Float = 432_000
    /// DAT_140492620.
    public static let rampSnap: Float = 0.01

    public private(set) var frametime: Float = 0
    public private(set) var time: Double = 0
    public private(set) var pauseRamp: Float = 1

    public init() {}

    public static func rate(percent: Float) -> Float {
        max(percent / 100, 0.1)
    }

    public static func daytime(hour: Int, minute: Int, second: Int, millisecond: Int) -> Float {
        Float(Double(hour) / 24 + Double(minute) / 1440 + Double(second) / 86400
            + Double(millisecond) / 86_400_000)
    }

    /// Returns false when the paused ramp has reached 0; WPE skips the frame and the clock holds.
    @discardableResult
    public mutating func advance(elapsed: Double, ratePercent: Float, paused: Bool) -> Bool {
        let step = Self.clampStep(Float(elapsed))
        let target: Float = paused ? 0 : 1
        if abs(pauseRamp - target) >= Self.rampSnap {
            pauseRamp += (target - pauseRamp) * min(1, step * 6)
        } else {
            pauseRamp = target
        }
        if paused, pauseRamp <= 0 {
            // [I] WPE skips the frame and uploads no g_Frametime; a held clock advances nothing.
            frametime = 0
            return false
        }
        frametime = Self.clampStep(Self.rate(percent: ratePercent) * pauseRamp * step)
        time = Double(Float(time) + frametime)
        if Float(time) > Self.wrapTime {
            time = 0
        }
        return true
    }

    public var timeUniform: Float {
        Float(time)
    }

    private static func clampStep(_ value: Float) -> Float {
        min(max(value, minimumStep), maximumStep)
    }
}
