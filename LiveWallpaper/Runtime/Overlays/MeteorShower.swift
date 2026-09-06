import AppKit
import QuartzCore

/// Shooting stars, flown one sprite at a time rather than emitted.
///
/// A meteor's light rises before it falls: it comes in faint, brightens as it ablates,
/// and dies away. Every particle library models that as an alpha envelope over the
/// particle's own lifetime — Wallpaper Engine's Alpha Fade operator takes a fade-in and
/// a fade-out time as fractions of lifetime, and this repo's own `WPEParticleSystem`
/// implements the same envelope. `CAEmitterCell` cannot: it offers `alphaSpeed`, a single
/// straight line, so an emitted particle can only ever get dimmer. Working around that
/// with a sub-cell train ran into two more macOS 27 defects — a cell carrying sub-cells
/// has its whole sprite box filled in by the compositor, and sub-cells emit at most once
/// per frame, which beads the train at speed.
///
/// So a meteor is what a sprite library ships: one pre-rendered streak on its own layer,
/// flown down a straight path with a keyframed `opacity` envelope. Meteors are rare (about
/// one a second at most), so a handful of layers costs far less than an emitter would.
@MainActor
final class MeteorShower {
    /// Everything about one flight, decided up front. Pure, so the geometry and the
    /// light curve can be checked without putting anything on screen.
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

    /// Radians from vertical, positive towards the right of the screen. Shallow enough
    /// to read as "across the sky" rather than "falling", and fixed rather than
    /// wind-driven: meteors come in on their own path, and one shared angle is what
    /// reads as a radiant shower rather than as noise.
    static let slant: CGFloat = 1.0

    /// The alpha envelope, as fractions of the flight. Rise fast, hold, fall slowly —
    /// the shape of a real meteor's light curve, and the shape `CAEmitterCell` cannot
    /// express. Starting and ending at zero is what makes one arrive and leave rather
    /// than switch on and off.
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

    /// Freezes what is in flight and stops launching more. Same `speed`/`timeOffset`
    /// dance the emitter uses, so a resumed meteor picks up where it stopped instead
    /// of jumping forward by however long the wallpaper was suspended.
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

    /// A flight across `bounds`, entering above the top edge and burning out before it
    /// would reach the bottom. `roll` supplies the randomness so the geometry can be
    /// exercised with fixed values.
    static func flight(in bounds: CGRect, roll: (ClosedRange<CGFloat>) -> CGFloat) -> Flight {
        let speed = roll(620 ... 980)
        let duration = Double(roll(1.5 ... 2.4))
        let distance = speed * CGFloat(duration)
        // Streak length is the motion blur of one exposure, as it is for rain.
        let length = speed * 0.15
        let width = roll(2.6 ... 4.4)

        let heading = CGVector(dx: sin(slant), dy: -cos(slant))
        // Far enough above the frame that the whole sprite is outside it at birth: the
        // envelope fades a meteor in, and a sprite already astride the edge would show
        // that fade happening in plain view instead of out of sight.
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

    private func launch() {
        guard !isSuspended, host != nil else { return }
        let flight = Self.flight(in: bounds) { range in CGFloat.random(in: range) }
        guard let sprite = Self.sprite(for: flight) else { return }

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
        meteor.add(group, forKey: "flight")

        // The layer is spent once the envelope reaches zero. Removal rides the same
        // clock as the flight, so a suspended meteor is not swept away mid-air.
        let deadline = DispatchTime.now() + flight.duration + 0.1
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak meteor, weak self] in
            guard let self, !self.isSuspended else { return }
            meteor?.removeFromSuperlayer()
        }
    }

    // MARK: - Sprite

    /// Sprites are cached by their drawn size: a shower reuses a handful of shapes, and
    /// rasterising a fresh gradient per meteor would be the only real cost here.
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
    var debugLiveMeteorCount: Int {
        container.sublayers?.count ?? 0
    }

    var debugIsScheduling: Bool {
        timer != nil
    }

    /// Launches one meteor immediately, so a test does not have to wait out a random gap.
    func debugLaunchNow() {
        launch()
    }
    #endif
}
