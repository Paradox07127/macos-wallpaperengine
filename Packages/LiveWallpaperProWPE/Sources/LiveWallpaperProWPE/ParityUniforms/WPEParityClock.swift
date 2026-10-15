/// WPE's frame clock (140110630.c:645-724, 14017fa70.c:213-223).
public struct WPEParityClock: Sendable {
    public static let minimumStep: Float = 1e-4
    public static let maximumStep: Float = 0.25
    public static let wrapTime: Float = 432_000
    /// DAT_140492620.
    public static let rampSnap: Float = 0.01

    public private(set) var frametime: Float = 0
    /// Renderer +0x160: construction seeds 1/30; an ordinary update copies the prior +0x15c publication here.
    public private(set) var previousFrametime: Float = .init(bitPattern: 0x3D08_8889)
    /// Public scene time is the renderer's binary32 publication (+0x140), widened for existing consumers.
    public var time: Double {
        Double(timeUniform)
    }

    /// Renderer +0x148 retains the binary64 sum independently of the published shader/script time.
    private var accumulatedTime: Double = 0
    public private(set) var pauseRamp: Float = 1
    /// Host +0x190 stores this normalized rate. Convert an accepted percent value only at its setter.
    public private(set) var normalizedRate: Float = 1
    /// Main +0x164, published before the frame-step clamp and consumed with that update's frametime.
    public private(set) var sceneScale: Float = 1

    public init() {}

    public static func rate(percent: Float) -> Float {
        max(percent / 100, 0.1)
    }

    /// The finite numeric setter boundary (115280); raw settings type admission belongs to the host.
    public mutating func setRate(percent: Float) {
        normalizedRate = Self.rate(percent: percent)
    }

    public static func daytime(hour: Int, minute: Int, second: Int, millisecond: Int) -> Float {
        Float(Double(hour) / 24 + Double(minute) / 1440 + Double(second) / 86400
            + Double(millisecond) / 86_400_000)
    }

    /// Returns false when the paused ramp has reached 0; WPE skips the frame and the clock holds.
    @discardableResult
    public mutating func advance(elapsed: Double, paused: Bool) -> Bool {
        let step = Self.clampStep(Float(elapsed))
        let target: Float = paused ? 0 : 1
        if abs(pauseRamp - target) >= Self.rampSnap {
            pauseRamp += (target - pauseRamp) * min(1, step * 6)
        } else {
            pauseRamp = target
        }
        if paused, pauseRamp <= 0 {
            // 110630 skips 17fa70 entirely, so both published intervals hold until the next ordinary update.
            return false
        }
        previousFrametime = frametime
        sceneScale = normalizedRate * pauseRamp
        frametime = Self.clampStep(sceneScale * step)
        // 14017fcaf–14017fce5: widen the binary32 step, add/store binary64, then publish binary32.
        accumulatedTime += Double(frametime)
        if timeUniform > Self.wrapTime {
            accumulatedTime = 0
        }
        return true
    }

    /// Compatibility for callers supplying a fresh rate. Product updates use the stored normalized owner.
    @discardableResult
    public mutating func advance(elapsed: Double, ratePercent: Float, paused: Bool) -> Bool {
        setRate(percent: ratePercent)
        return advance(elapsed: elapsed, paused: paused)
    }

    public var timeUniform: Float {
        Float(accumulatedTime)
    }

    private static func clampStep(_ value: Float) -> Float {
        min(max(value, minimumStep), maximumStep)
    }
}
