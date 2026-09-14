import AppKit
import QuartzCore

/// `CAEmitterCell` only offers a straight-line `alphaSpeed`, so a meteor is one pre-rendered streak with a keyframed opacity envelope rather than an emitted particle.
@MainActor
final class MeteorShower {
    struct Flight: Equatable {
        var start: CGPoint
        var end: CGPoint
        var duration: Double
        /// Streak length and width of the sprite, in points.
        var length: CGFloat
        var width: CGFloat
        /// Peak opacity, before the envelope scales it.
        var brightness: CGFloat
    }

    /// Radians from vertical, positive towards the right of the screen. Fixed rather than wind-driven.
    static let slant: CGFloat = 1.0

    /// Alpha envelope as fractions of the flight. Starting and ending at zero is what makes one arrive and leave rather than switch on and off.
    static let opacityKeyTimes: [Double] = [0, 0.13, 0.5, 1]
    static let opacityValues: [Double] = [0, 1, 0.82, 0]

    /// Mean flights per second at density 1.
    private static let baseRate: Double = 0.75

    private weak var host: CALayer?
    private let container = CALayer()
    private var bounds: CGRect = .zero
    private var density: CGFloat = 1
    private var isSuspended = false
    /// Retained so `deinit` can stop it: the timer is scheduled on the main run loop,
    /// which is the only place it fires, but deinit may run anywhere.
    private nonisolated(unsafe) var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    // MARK: - Lifecycle

    func attach(to host: CALayer, bounds: CGRect, density: CGFloat) {
        self.host = host
        self.bounds = bounds
        self.density = density
        container.frame = bounds
        container.backgroundColor = NSColor.clear.cgColor
        // Meteors reach past both edges, and a clipped one would end mid-sky.
        container.masksToBounds = false
        host.addSublayer(container)
        scheduleNext()
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        container.removeAllAnimations()
        container.sublayers?.forEach { $0.removeFromSuperlayer() }
        container.removeFromSuperlayer()
        host = nil
    }

    func updateBounds(_ bounds: CGRect) {
        guard bounds != self.bounds else { return }
        self.bounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        CATransaction.commit()
    }

    func updateDensity(_ density: CGFloat) {
        self.density = density
    }

    /// Same `speed`/`timeOffset` dance the emitter uses, so a resumed meteor picks up where it stopped instead of jumping forward.
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if suspended {
            timer?.invalidate()
            timer = nil
            let paused = container.convertTime(CACurrentMediaTime(), from: nil)
            container.speed = 0
            container.timeOffset = paused
            container.isHidden = true
        } else {
            let paused = container.timeOffset
            container.speed = 1
            container.timeOffset = 0
            container.beginTime = 0
            container.beginTime = container.convertTime(CACurrentMediaTime(), from: nil) - paused
            container.isHidden = false
            scheduleNext()
        }
    }

    // MARK: - Scheduling

    /// Gaps between meteors are drawn from an exponential distribution, so they arrive
    /// at random rather than on a beat — a metronome is the tell that a shower is fake.
    static func nextGap(density: CGFloat, uniform: Double) -> Double {
        let rate = max(baseRate * Double(max(density, 0.05)), 0.02)
        let sample = -log(max(uniform, 1e-6)) / rate
        return min(max(sample, 0.2), 12)
    }

    private func scheduleNext() {
        timer?.invalidate()
        guard !isSuspended, host != nil else { return }
        let gap = Self.nextGap(density: density, uniform: Double.random(in: 0 ..< 1))
        timer = Timer.scheduledTimer(withTimeInterval: gap, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.launch()
                self.scheduleNext()
            }
        }
    }

    // MARK: - One flight

    static func flight(in bounds: CGRect, roll: (ClosedRange<CGFloat>) -> CGFloat) -> Flight {
        let speed = roll(620 ... 980)
        let duration = Double(roll(1.5 ... 2.4))
        let distance = speed * CGFloat(duration)
        // Streak length is the motion blur of one exposure, as it is for rain.
        let length = speed * 0.15
        let width = roll(2.6 ... 4.4)

        let heading = CGVector(dx: sin(slant), dy: -cos(slant))
        // Far enough above the frame that the whole sprite is outside it at birth: otherwise the fade-in happens in plain view.
        let entry = length
        let start = CGPoint(
            x: bounds.minX + roll(-0.35 ... 0.95) * bounds.width - heading.dx * entry,
            y: bounds.maxY + entry
        )
        return Flight(
            start: start,
            end: CGPoint(x: start.x + heading.dx * distance, y: start.y + heading.dy * distance),
            duration: duration,
            length: length,
            width: width,
            brightness: roll(0.55 ... 1.0)
        )
    }

    @discardableResult
    private func launch() -> CALayer? {
        guard !isSuspended, host != nil else { return nil }
        let flight = Self.flight(in: bounds) { range in CGFloat.random(in: range) }
        guard let sprite = Self.sprite(for: flight) else { return nil }

        let meteor = CALayer()
        meteor.contents = sprite
        meteor.bounds = CGRect(x: 0, y: 0, width: CGFloat(sprite.width), height: CGFloat(sprite.height))
        meteor.position = flight.start
        meteor.opacity = 0
        meteor.isGeometryFlipped = false
        container.addSublayer(meteor)

        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(point: flight.start)
        travel.toValue = NSValue(point: flight.end)
        travel.timingFunction = CAMediaTimingFunction(name: .linear)

        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = Self.opacityValues.map { $0 * Double(flight.brightness) }
        glow.keyTimes = Self.opacityKeyTimes.map(NSNumber.init(value:))
        glow.calculationMode = .linear

        let group = CAAnimationGroup()
        group.animations = [travel, glow]
        group.duration = flight.duration
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        // Removal rides the layer's own clock: a wall-clock `asyncAfter` would skip while suspended and never come back.
        group.delegate = FlightEnd(meteor: meteor)
        meteor.add(group, forKey: "flight")
        return meteor
    }

    /// The animation retains its delegate and the layer its animation, so the
    /// layer is held weakly here or the three would keep each other alive.
    private final class FlightEnd: NSObject, CAAnimationDelegate {
        private weak var meteor: CALayer?

        init(meteor: CALayer) {
            self.meteor = meteor
        }

        func animationDidStop(_: CAAnimation, finished _: Bool) {
            meteor?.removeFromSuperlayer()
        }
    }

    // MARK: - Sprite

    private static var spriteCache: [String: CGImage] = [:]

    private static func sprite(for flight: Flight) -> CGImage? {
        let length = (flight.length / 8).rounded() * 8
        let width = (flight.width / 0.4).rounded() * 0.4
        let key = "\(length)x\(width)"
        if let cached = spriteCache[key] {
            return cached
        }
        let image = ParticleTextures.comet(
            length: length, width: width,
            color: NSColor(calibratedRed: 0.93, green: 0.96, blue: 1.0, alpha: 1).cgColor,
            tilt: slant
        )
        if let image {
            spriteCache[key] = image
        }
        return image
    }

    #if DEBUG
    func debugLaunchNow() -> CALayer? {
        launch()
    }
    #endif
}
