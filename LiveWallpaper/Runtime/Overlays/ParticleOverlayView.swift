import AppKit
import LiveWallpaperCore
import QuartzCore

/// Why the particle layer is paused. Reasons stack — the layer runs only while the set is
/// empty — so the runtime's resume after a wake cannot also lift a Reduce Motion pause,
/// and the two can be raised and dropped in either order.
struct ParticleSuspensionReasons: OptionSet {
    let rawValue: Int

    /// The wallpaper runtime's own gate: display asleep, other windows covering it, etc.
    static let runtime = ParticleSuspensionReasons(rawValue: 1 << 0)
    /// System Settings > Accessibility > Display > Reduce motion.
    static let reduceMotion = ParticleSuspensionReasons(rawValue: 1 << 1)
}

final class ParticleOverlayView: NSView {

    // MARK: - State

    private var currentEffect: ParticleEffect = .none

    private var activeEmitter: CAEmitterLayer?
    private var meteorShower: MeteorShower?
    private(set) var suspensionReasons: ParticleSuspensionReasons = []
    var isSuspended: Bool {
        !suspensionReasons.isEmpty
    }

    // MARK: - Layer Hosting

    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.backgroundColor = NSColor.clear.cgColor
        return layer
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// How far the falling particles lean, in radians from vertical, and which
    /// way. Positive leans to the right of the screen.
    private var tiltRadians: CGFloat = 0
    /// Lean the live emitter was last built for.
    private var appliedTilt: CGFloat = 0

    func setEffect(_ effect: ParticleEffect, density: CGFloat = 1.0, tiltRadians: CGFloat = 0) {
        self.tiltRadians = tiltRadians
        if effect == currentEffect {
            updateDensity(density)
            applyTilt()
            return
        }

        currentEffect = effect

        if let oldEmitter = activeEmitter {
            oldEmitter.birthRate = 0
            oldEmitter.removeFromSuperlayer()
            activeEmitter = nil
        }
        meteorShower?.detach()
        meteorShower = nil

        guard effect != .none else { return }

        if effect == .meteors, let hostLayer = layer {
            let shower = MeteorShower()
            shower.attach(to: hostLayer, bounds: bounds, density: density)
            shower.setSuspended(isSuspended)
            meteorShower = shower
            return
        }

        let emitter = CAEmitterLayer()
        emitter.emitterMode = .surface
        emitter.backgroundColor = NSColor.clear.cgColor
        emitter.frame = bounds

        let preset = preset(for: effect, tilt: tiltRadians)
        emitter.emitterCells = preset.cells
        emitter.emitterShape = preset.shape
        emitter.renderMode = preset.renderMode
        emitter.emitterPosition = preset.position(bounds)
        emitter.emitterSize = preset.size(bounds)
        emitter.birthRate = Float(max(0.05, density))

        layer?.addSublayer(emitter)
        activeEmitter = emitter
        appliedTilt = tiltRadians
        applySuspensionState(to: emitter)
    }

    func updateDensity(_ density: CGFloat) {
        activeEmitter?.birthRate = Float(max(0.05, density))
        meteorShower?.updateDensity(density)
    }

    /// Rebuilds for a new lean, not a rotation: rotating swings the emission line off the
    /// top, leaving a dry wedge down one side (measured: 0.45 rad left rain covering only
    /// the left ~60%). Lean lives in the cells' heading and streak texture instead.
    /// Weather refreshes hourly (cheap to rebuild); the guard skips no-op updates.
    private func applyTilt() {
        guard let emitter = activeEmitter, currentEffect.leansIntoWind else { return }
        guard abs(appliedTilt - tiltRadians) > 0.01 else { return }
        appliedTilt = tiltRadians
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.emitterCells = preset(for: currentEffect, tilt: tiltRadians).cells
        emitter.emitterSize = preset(for: currentEffect, tilt: tiltRadians).size(bounds)
        CATransaction.commit()
    }

    /// Suspend emitter; resume adjusts beginTime so the pause does not fast-forward.
    /// Only the last reason to be dropped restarts it.
    func setSuspended(_ suspended: Bool, for reason: ParticleSuspensionReasons = .runtime) {
        let wasSuspended = isSuspended
        if suspended {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
        guard wasSuspended != isSuspended else { return }
        if let activeEmitter {
            applySuspensionState(to: activeEmitter)
        }
        meteorShower?.setSuspended(isSuspended)
    }

    private func applySuspensionState(to emitter: CAEmitterLayer) {
        if isSuspended {
            let pausedTime = emitter.convertTime(CACurrentMediaTime(), from: nil)
            emitter.speed = 0
            emitter.timeOffset = pausedTime
            emitter.isHidden = true
        } else {
            let pausedTime = emitter.timeOffset
            emitter.speed = 1
            emitter.timeOffset = 0
            emitter.beginTime = 0
            let elapsedPause = emitter.convertTime(CACurrentMediaTime(), from: nil) - pausedTime
            emitter.beginTime = elapsedPause
            emitter.isHidden = false
        }
    }

    #if DEBUG
    var debugEmitterState: (
        isHidden: Bool, speed: Float, birthRate: Float, beginTime: CFTimeInterval
    )? {
        activeEmitter.map { ($0.isHidden, $0.speed, $0.birthRate, $0.beginTime) }
    }

    /// The cells a preset would build, so a test can fly them itself.
    func debugCells(for effect: ParticleEffect, tilt: CGFloat) -> [CAEmitterCell] {
        preset(for: effect, tilt: tilt).cells
    }
    #endif

    // MARK: - Layout

    override func layout() {
        super.layout()
        meteorShower?.updateBounds(bounds)
        guard let emitter = activeEmitter, currentEffect != .none else { return }
        emitter.frame = bounds
        let preset = preset(for: currentEffect, tilt: tiltRadians)
        emitter.emitterPosition = preset.position(bounds)
        emitter.emitterSize = preset.size(bounds)
    }

    // MARK: - Effect Presets

    private struct EmitterPreset {
        let cells: [CAEmitterCell]
        let shape: CAEmitterLayerEmitterShape
        let renderMode: CAEmitterLayerRenderMode
        let position: (CGRect) -> CGPoint
        let size: (CGRect) -> CGSize

        /// Emitter height for the band presets. Not `.line`: on macOS 27 (26A5425a) a
        /// `.line` emitter launches every particle 90° off its `emissionLongitude` —
        /// measured 2026-09-05 by tracking dots, `-π/2` came out moving left, not down —
        /// while `.point` and `.rectangle` honour the angle. Rain fell sideways with
        /// its streaks still drawn vertical, which is the "streaks cross their own
        /// path" report. A 1 pt rectangle is the same line to the eye.
        static let bandThickness: CGFloat = 1
    }

    private func preset(for effect: ParticleEffect, tilt: CGFloat) -> EmitterPreset {
        switch effect {
        case .none: Self.emptyPreset
        case .snow: Self.snowPreset(tilt: tilt)
        case .rain: Self.rainPreset(tilt: tilt)
        case .bokeh: Self.bokehPreset
        case .fireflies: Self.firefliesPreset
        case .dust: Self.dustPreset
        case .stars: Self.starsPreset
        case .fallingLeaves: Self.leavesPreset(tilt: tilt)
        case .sakura: Self.sakuraPreset(tilt: tilt)
        case .mist: Self.mistPreset
        case .embers: Self.embersPreset
        case .bubbles: Self.bubblesPreset
        // Flown by `MeteorShower` on its own layer, not emitted.
        case .meteors: Self.emptyPreset
        }
    }

    private static let emptyPreset = EmitterPreset(
        cells: [],
        shape: .point,
        renderMode: .unordered,
        position: { _ in .zero },
        size: { _ in .zero }
    )

    // MARK: - Depth

    /// One slice of a particle field at relative distance `z` (1 = nearest). Perspective,
    /// applied to every visible quantity at once: size, speed and sideways drift shrink by
    /// 1/z, brightness a little faster (a far mote is sub-pixel and behind more air), and
    /// the count per screen area grows — the small far ones are the many. Fields list their
    /// bands near → far; tests read that order.
    private struct DepthBand {
        let z: CGFloat
        /// Births per second at density 1.
        let birthRate: Float

        func scaled(_ near: CGFloat) -> CGFloat {
            near / z
        }

        func alpha(_ near: CGFloat, falloff: CGFloat = 0.5) -> CGFloat {
            near / pow(z, falloff)
        }

        /// Long enough to cross `travel` points, but capped: a far flake at 17 pt/s would
        /// otherwise live a minute and a half, and the alive count is birthRate × lifetime.
        func lifetime(speed: CGFloat, travel: CGFloat = 1500, cap: Float = 40) -> Float {
            min(Float(travel / max(speed, 1)), cap)
        }

        /// Fade for a band whose capped life ends mid-screen, so it dissolves instead of
        /// popping; zero when it reaches the bottom anyway.
        func fade(alpha: CGFloat, speed: CGFloat, lifetime: Float, travel: CGFloat = 1500) -> Float {
            speed * CGFloat(lifetime) >= travel ? 0 : -Float(alpha) / lifetime
        }
    }

    /// Sideways flutter of a falling field, `near` pt/s² at the nearest band, pushed the way
    /// the wind blows: over a long fall a constant push to the right overpowers any leftward
    /// heading the wind gave at birth, so an easterly still ended with everything going east.
    private static func flutterDrift(tilt: CGFloat, near: CGFloat, band: DepthBand) -> CGFloat {
        (tilt < 0 ? -1 : 1) * band.scaled(near)
    }

    /// How a petal or leaf spins, rad/s. Calm air turns it either way at up to `calm`; wind
    /// adds a roll proportional to the lean — a few turns a second at the 30° cap — biased
    /// in the wind's direction, with enough spread that some still tumble the other way.
    private static func applyTumble(to cell: CAEmitterCell, tilt: CGFloat, calm: CGFloat) {
        let wind = abs(tilt) * 8
        cell.spin = (tilt < 0 ? -1 : 1) * wind
        cell.spinRange = calm * 2 + wind
    }

    // MARK: - Snow

    private static func snowPreset(tilt: CGFloat) -> EmitterPreset {
        let field = [
            DepthBand(z: 1.0, birthRate: 6), DepthBand(z: 1.45, birthRate: 10),
            DepthBand(z: 2.1, birthRate: 14), DepthBand(z: 3.0, birthRate: 18),
        ]
        let cells = field.map { band -> CAEmitterCell in
            let cell = CAEmitterCell()
            let speed = band.scaled(60)
            let alpha = band.alpha(0.85)
            cell.contents = ParticleTextures.softCircle(
                radius: max(band.scaled(7), 1.5), color: NSColor.white.cgColor
            )
            cell.birthRate = band.birthRate
            cell.lifetime = band.lifetime(speed: speed)
            cell.lifetimeRange = cell.lifetime * 0.25
            cell.velocity = speed
            cell.velocityRange = speed * 0.3
            // A flake is round, so only its heading moves with the wind —
            // there is no shape to point the other way.
            cell.emissionLongitude = -.pi / 2 + tilt
            // Wide on purpose: snowflakes flutter and tumble on the way down
            // — the behaviour that separates snow from rain at a glance — and
            // a narrow cone made them fall like slow rain.
            cell.emissionRange = .pi / 4
            cell.scale = 1
            cell.scaleRange = 0.25
            cell.alphaRange = Float(alpha * 0.3)
            cell.alphaSpeed = band.fade(alpha: alpha, speed: speed, lifetime: cell.lifetime)
            cell.xAcceleration = flutterDrift(tilt: tilt, near: 10, band: band)
            cell.yAcceleration = -band.scaled(15)
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            // Snow leans much further than rain for the same wind, so its line
            // has to reach further past the upwind edge.
            size: { CGSize(width: $0.width * 2.4, height: EmitterPreset.bandThickness) }
        )
    }

    // MARK: - Rain

    /// One rain field seen in depth, not a few unrelated sheets.
    ///
    /// Every band shares ONE lean. Drops of every size in one patch of sky fall in the same
    /// direction (Garg & Nayar, CVPR 2004 §3.1: "within a local region, drops fall more or less
    /// in the same direction"), and perspective keeps a straight path's on-screen angle the same
    /// at every distance. The old preset gave each layer `atan(wind / itsOwnSpeed)` — the
    /// world-space drift of a *smaller* drop, applied to a *farther* one — so the small far drops
    /// slanted ~17° steeper than the big near ones, and the field drifted one way while the
    /// streaks the eye picks out pointed another.
    ///
    /// Streak length is speed × one exposure — the motion blur of a drop already at terminal
    /// velocity — so it follows the band's speed rather than being picked per band.
    private static func rainPreset(tilt: CGFloat) -> EmitterPreset {
        let cells = Rain.field.map { band -> CAEmitterCell in
            let cell = CAEmitterCell()
            let speed = band.scaled(Rain.nearSpeed)
            let alpha = band.alpha(Rain.nearAlpha, falloff: 0.7)
            cell.contents = ParticleTextures.streak(
                length: speed * Rain.exposure, width: max(band.scaled(Rain.nearWidth), 1),
                color: NSColor.white.withAlphaComponent(alpha).cgColor,
                tilt: tilt
            )
            cell.birthRate = band.birthRate
            // `lifetimeRange` is a fifth of this, so even the shortest life covers `travel`.
            cell.lifetime = Float(Rain.travel / speed / 0.8)
            cell.lifetimeRange = cell.lifetime * 0.2
            cell.velocity = speed
            cell.velocityRange = speed * 0.15
            cell.emissionLongitude = -.pi / 2 + tilt
            // Zero spread: the streak's angle is baked into its bitmap, so any heading a drop
            // takes that the bitmap did not is a drop drawn pointing off its own path.
            cell.emissionRange = 0
            cell.scale = 1
            cell.scaleRange = 0.15
            cell.alphaRange = 0.2
            // No gravity: a drop is already at terminal velocity, so its path is a straight
            // line. Accelerating it swung the heading from 0.5 rad at birth to 0.10 rad at
            // death (measured) while the streak bitmap stayed at 0.5 — the drop spent most of
            // its life drawn pointing 20° away from where it was actually going.
            cell.yAcceleration = 0
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            // Much wider than the screen: leaning rain enters from off the
            // upwind edge, and a screen-width line leaves that side dry.
            size: { CGSize(width: $0.width * 2.4, height: EmitterPreset.bandThickness) }
        )
    }

    private enum Rain {
        /// On-screen fall speed of the nearest band, pt/s. A big drop's terminal velocity is
        /// 6–9 m/s (Atlas et al. 1973: v = 9.65 − 10.3·e^(−0.6·D), D in mm), and this is that
        /// speed at the distance where a 2 mm drop is about three points wide.
        static let nearSpeed: CGFloat = 640
        static let nearWidth: CGFloat = 2.8
        static let nearAlpha: CGFloat = 0.8
        /// Streak = speed × one exposure. 1/25 s, on the long side of a video shutter: the eye
        /// integrates longer than a camera does, and short streaks read as confetti.
        static let exposure: CGFloat = 0.04
        /// Fall a drop must survive before it may die — the tallest display in points (6K at
        /// 2x is 1692) — so no drop pops out of existence mid-screen.
        static let travel: CGFloat = 1800

        static let field = [
            DepthBand(z: 1.0, birthRate: 22), DepthBand(z: 1.4, birthRate: 32),
            DepthBand(z: 1.9, birthRate: 42), DepthBand(z: 2.6, birthRate: 50),
            DepthBand(z: 3.5, birthRate: 56),
        ]
    }

    // MARK: - Mist

    /// Fog, as a handful of very large, very faint, very slow sprites — deliberately
    /// not a full-screen noise shader, which is a per-pixel cost paid every frame
    /// forever while this layer is up for hours. Apple lists fog among
    /// `CAEmitterLayer`'s own use cases, for "a slowly drifting translucent veil" (as
    /// opposed to fog that weaves between objects and self-shadows) — big soft
    /// billboards are the cheap way there. Very few particles on purpose: each sprite
    /// covers a large area, so the look comes from overlap rather than count; three
    /// sizes at three speeds keep it from reading as one sliding sheet.
    private static let mistPreset: EmitterPreset = {
        let makeBank = {
            (radius: CGFloat, velocity: CGFloat, birthRate: Float, alpha: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(
                radius: radius, color: NSColor.white.cgColor
            )
            cell.birthRate = birthRate
            cell.lifetime = 26
            cell.lifetimeRange = 8
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.6
            cell.emissionLongitude = 0          // drifts sideways, does not fall
            cell.emissionRange = .pi / 10
            cell.scale = 1
            cell.scaleRange = 0.45
            cell.alphaRange = Float(alpha * 0.4)
            // Fades in and out rather than popping: a hard-edged cloud of fog
            // appearing at the screen edge is the tell that it is sprites.
            cell.alphaSpeed = -Float(alpha) / 26
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        let broad = makeBank(190, 7, 0.5, 0.11)
        let mid = makeBank(130, 11, 0.8, 0.09)
        let wisps = makeBank(80, 16, 1.2, 0.07)

        return EmitterPreset(
            cells: [broad, mid, wisps],
            shape: .rectangle,
            renderMode: .unordered,
            // Born across the whole frame, not along an edge: fog is already
            // everywhere when you walk into it.
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width * 1.2, height: $0.height) }
        )
    }()

    // MARK: - Embers

    /// Sparks lifting off an unseen fire below the screen. The colour ramp is the
    /// whole effect: a spark leaves the fire yellow-hot and cools through orange to
    /// dull red before going out — green and blue driven down over its life while red
    /// is held; a spark that keeps its birth colour the whole way up reads as
    /// confetti. Buoyancy, not gravity: hot gas is still rising when the spark
    /// reaches the top, so the acceleration points the same way as the velocity.
    private static let embersPreset: EmitterPreset = {
        let field = [
            DepthBand(z: 1.0, birthRate: 5), DepthBand(z: 1.4, birthRate: 8),
            DepthBand(z: 1.9, birthRate: 12), DepthBand(z: 2.6, birthRate: 15),
        ]
        let cells = field.enumerated().map { index, band -> CAEmitterCell in
            let cell = CAEmitterCell()
            let speed = band.scaled(75)
            let alpha = band.alpha(0.9)
            // Every band climbs the same ~500 pt before it burns out.
            let life = Float(500 / speed)
            cell.contents = ParticleTextures.softCircle(
                radius: max(band.scaled(3.8), 1.2), color: NSColor.white.cgColor
            )
            cell.birthRate = band.birthRate
            cell.lifetime = life
            cell.lifetimeRange = life * 0.4
            cell.velocity = speed
            cell.velocityRange = speed * 0.5
            cell.emissionLongitude = .pi / 2 // straight up
            cell.emissionRange = .pi / 7
            cell.scale = 1
            cell.scaleRange = 0.6
            cell.scaleSpeed = -0.5 / CGFloat(life)
            cell.alphaRange = 0.35
            cell.alphaSpeed = -Float(alpha) / life
            cell.yAcceleration = band.scaled(14)
            // Alternate bands drift opposite ways so the column as a whole wavers.
            cell.xAcceleration = (index.isMultiple(of: 2) ? 1 : -1) * band.scaled(5)
            cell.color = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.42, alpha: alpha).cgColor
            // Cools to a deep red over the spark's life.
            cell.greenSpeed = -0.5 / life
            cell.blueSpeed = -0.4 / life
            return cell
        }

        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.minY) },
            size: { CGSize(width: $0.width * 1.1, height: EmitterPreset.bandThickness) }
        )
    }()

    // MARK: - Bubbles

    /// Rising bubbles, as seen from inside the water. Bigger bubbles rise faster — the
    /// real relation, and what sells the depth: large near ones climb past small far
    /// ones. `CAEmitterCell` can't make a particle wander, so the sideways wobble is
    /// faked across bands instead of within one — alternate bands drift in opposite
    /// directions, so the field as a whole meanders though no single bubble does.
    private static let bubblesPreset: EmitterPreset = {
        let field = [
            DepthBand(z: 1.0, birthRate: 2), DepthBand(z: 1.4, birthRate: 3),
            DepthBand(z: 1.9, birthRate: 5), DepthBand(z: 2.6, birthRate: 6),
        ]
        let cells = field.enumerated().map { index, band -> CAEmitterCell in
            let cell = CAEmitterCell()
            let speed = band.scaled(48)
            let alpha = band.alpha(0.5)
            cell.contents = ParticleTextures.bubble(radius: band.scaled(16), color: NSColor.white.cgColor)
            cell.birthRate = band.birthRate
            cell.lifetime = band.lifetime(speed: speed)
            cell.lifetimeRange = cell.lifetime * 0.25
            cell.velocity = speed
            cell.velocityRange = speed * 0.35
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 12
            cell.scale = 1
            cell.scaleRange = 0.35
            cell.alphaRange = Float(alpha * 0.4)
            cell.alphaSpeed = band.fade(alpha: alpha, speed: speed, lifetime: cell.lifetime)
            cell.spin = 0.2
            cell.spinRange = 0.6
            cell.xAcceleration = (index.isMultiple(of: 2) ? 1.6 : -1.2) * band.scaled(1)
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.minY) },
            size: { CGSize(width: $0.width, height: EmitterPreset.bandThickness) }
        )
    }()

    // MARK: - Meteors
    //
    // Not an emitter preset: see `MeteorShower`. A shooting star needs to brighten
    // before it fades, and `CAEmitterCell` only offers a straight-line `alphaSpeed`.

    // MARK: - Bokeh

    private static let bokehPreset: EmitterPreset = {
        let palette: [CGColor] = [
            NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.70, alpha: 0.85).cgColor,
            NSColor(calibratedRed: 0.70, green: 0.88, blue: 1.00, alpha: 0.85).cgColor,
            NSColor(calibratedRed: 1.00, green: 0.75, blue: 0.90, alpha: 0.85).cgColor,
            NSColor(calibratedRed: 0.85, green: 1.00, blue: 0.85, alpha: 0.85).cgColor,
        ]
        let cells = palette.map { color -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: 32, color: color)
            cell.birthRate = 0.9
            cell.lifetime = 9
            cell.lifetimeRange = 3
            cell.velocity = 6
            cell.velocityRange = 8
            cell.emissionRange = .pi * 2
            cell.scale = 1.0
            cell.scaleRange = 0.6
            cell.scaleSpeed = 0.04
            cell.alphaRange = 0.2
            cell.alphaSpeed = -0.09
            cell.yAcceleration = 3
            cell.color = color
            return cell
        }
        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

    // MARK: - Fireflies

    private static let firefliesPreset: EmitterPreset = {
        let glowColor = NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.55, alpha: 1).cgColor
        let cell = CAEmitterCell()
        cell.contents = ParticleTextures.softCircle(radius: 14, color: glowColor)
        cell.birthRate = 30
        cell.lifetime = 8
        cell.lifetimeRange = 3
        cell.velocity = 18
        cell.velocityRange = 22
        cell.emissionRange = .pi * 2
        cell.scale = 1.0
        cell.scaleRange = 0.4
        cell.alphaRange = 0.6
        cell.alphaSpeed = -0.12
        cell.yAcceleration = 2
        cell.color = glowColor
        return EmitterPreset(
            cells: [cell],
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

    // MARK: - Falling Leaves

    /// Autumn leaves in depth. One cell per band with the colour *ranges* spanning
    /// orange, gold and brown — one cell per colour made colour the depth cue.
    private static func leavesPreset(tilt: CGFloat) -> EmitterPreset {
        let field = [
            DepthBand(z: 1.0, birthRate: 3), DepthBand(z: 1.4, birthRate: 5),
            DepthBand(z: 1.9, birthRate: 7), DepthBand(z: 2.6, birthRate: 9),
        ]
        let cells = field.map { band -> CAEmitterCell in
            let cell = CAEmitterCell()
            let speed = band.scaled(60)
            let alpha = band.alpha(0.95)
            cell.contents = ParticleTextures.leaf(
                width: band.scaled(22), height: band.scaled(14), color: NSColor.white.cgColor
            )
            cell.birthRate = band.birthRate
            cell.lifetime = band.lifetime(speed: speed)
            cell.lifetimeRange = cell.lifetime * 0.3
            cell.velocity = speed
            cell.velocityRange = speed * 0.5
            cell.emissionLongitude = -.pi / 2 + tilt
            cell.emissionRange = .pi / 4
            cell.scale = 1
            cell.scaleRange = 0.3
            cell.alphaRange = 0.3
            cell.alphaSpeed = band.fade(alpha: alpha, speed: speed, lifetime: cell.lifetime)
            applyTumble(to: cell, tilt: tilt, calm: 1.5)
            cell.xAcceleration = flutterDrift(tilt: tilt, near: 20, band: band)
            cell.yAcceleration = -band.scaled(10)
            cell.color = NSColor(calibratedRed: 0.8, green: 0.5, blue: 0.12, alpha: alpha).cgColor
            cell.redRange = 0.15
            cell.greenRange = 0.22
            cell.blueRange = 0.06
            return cell
        }

        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            size: { CGSize(width: $0.width * 2.4, height: EmitterPreset.bandThickness) }
        )
    }

    // MARK: - Sakura

    /// Cherry petals in depth: the near ones are big, quick and bright, the far ones a pale
    /// drift of many. They lean with the wind like the snow and tumble harder in it.
    private static func sakuraPreset(tilt: CGFloat) -> EmitterPreset {
        let field = [
            DepthBand(z: 1.0, birthRate: 3), DepthBand(z: 1.4, birthRate: 5),
            DepthBand(z: 1.9, birthRate: 7), DepthBand(z: 2.6, birthRate: 8),
        ]
        let cells = field.map { band -> CAEmitterCell in
            let cell = CAEmitterCell()
            let speed = band.scaled(70)
            let alpha = band.alpha(0.9)
            cell.contents = ParticleTextures.sakuraPetal(
                width: band.scaled(24), height: band.scaled(20), color: NSColor.white.cgColor
            )
            cell.birthRate = band.birthRate
            cell.lifetime = band.lifetime(speed: speed)
            cell.lifetimeRange = cell.lifetime * 0.3
            cell.velocity = speed
            cell.velocityRange = speed * 0.4
            cell.emissionLongitude = -.pi / 2 + tilt
            cell.emissionRange = .pi / 4
            cell.scale = 1
            cell.scaleRange = 0.25
            cell.alphaRange = Float(alpha * 0.3)
            cell.alphaSpeed = band.fade(alpha: alpha, speed: speed, lifetime: cell.lifetime)
            applyTumble(to: cell, tilt: tilt, calm: 1.0)
            cell.xAcceleration = flutterDrift(tilt: tilt, near: 25, band: band)
            cell.yAcceleration = -band.scaled(12)
            cell.color = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.82, alpha: alpha).cgColor
            cell.redRange = 0.1
            cell.greenRange = 0.1
            cell.blueRange = 0.1
            return cell
        }

        return EmitterPreset(
            cells: cells,
            shape: .rectangle,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            size: { CGSize(width: $0.width * 2.4, height: EmitterPreset.bandThickness) }
        )
    }

    // MARK: - Dust
    // Sun-shaft motes: tiny warm specks drifting in all directions with a very slow
    // lift. Three depth layers (near/mid/far) so it reads as volumetric rather than
    // a flat sprite sheet.

    private static let dustPreset: EmitterPreset = {
        let warmColor = NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.78, alpha: 1.0).cgColor
        let createLayer = { (radius: CGFloat, scale: CGFloat, birthRate: Float, alpha: Float, velocity: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: radius, color: warmColor)
            cell.birthRate = birthRate
            cell.lifetime = 18
            cell.lifetimeRange = 6
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.6
            cell.emissionRange = .pi * 2
            cell.scale = scale
            cell.scaleRange = scale * 0.5
            cell.alphaRange = Float(alpha * 0.4)
            cell.alphaSpeed = -0.02
            cell.yAcceleration = -1.5
            cell.xAcceleration = 0.5
            cell.color = warmColor.copy(alpha: CGFloat(alpha)) ?? warmColor
            return cell
        }

        let near = createLayer(3.0, 1.3, 4, 0.7, 8)
        let mid  = createLayer(2.0, 0.9, 10, 0.5, 6)
        let far  = createLayer(1.4, 0.5, 18, 0.3, 4)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

    // MARK: - Stars
    // Nearly stationary points with strong alpha-pulse so the field reads as a slow
    // twinkle. Cool palette (white-blue) sits well against night wallpapers without
    // forcing a specific color theme.

    private static let starsPreset: EmitterPreset = {
        let warmWhite = NSColor(calibratedRed: 1.0, green: 0.98, blue: 0.92, alpha: 1.0).cgColor
        let coolBlue = NSColor(calibratedRed: 0.85, green: 0.92, blue: 1.0, alpha: 1.0).cgColor

        let createLayer = { (radius: CGFloat, scale: CGFloat, birthRate: Float, color: CGColor) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: radius, color: color)
            cell.birthRate = birthRate
            cell.lifetime = 10
            cell.lifetimeRange = 4
            cell.velocity = 0
            cell.velocityRange = 0.5
            cell.emissionRange = .pi * 2
            cell.scale = scale
            cell.scaleRange = scale * 0.4
            cell.alphaRange = 0.45
            cell.alphaSpeed = -0.15
            cell.color = color
            return cell
        }

        let bright = createLayer(3.5, 1.2, 6, warmWhite)
        let mid    = createLayer(2.5, 0.8, 12, coolBlue)
        let faint  = createLayer(1.5, 0.5, 20, coolBlue)

        return EmitterPreset(
            cells: [bright, mid, faint],
            shape: .rectangle,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.midY) },
            size: { CGSize(width: $0.width, height: $0.height) }
        )
    }()

}

// MARK: - Reduce Motion

/// The system "Reduce motion" switch, watched rather than polled: AppKit posts
/// `accessibilityDisplayOptionsDidChangeNotification` whenever one of those switches moves.
/// Owners `start()` it while they have something moving and `stop()` it when they do not.
@MainActor
final class ReduceMotionWatcher {
    /// Test seam — a test process cannot flip the real Accessibility switch. Writing it does
    /// not re-evaluate anything by itself; the next notification, or the owner's next read of
    /// `isReduced`, is what applies it.
    var override: Bool?

    var isReduced: Bool {
        override ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var isWatching: Bool {
        token != nil
    }

    /// `nonisolated(unsafe)`: written only from MainActor code, but `deinit` runs anywhere
    /// and is the fail-safe for an owner that was dropped without calling `stop()`.
    private nonisolated(unsafe) var token: NSObjectProtocol?
    private let onChange: @MainActor (Bool) -> Void

    init(onChange: @escaping @MainActor (Bool) -> Void) {
        self.onChange = onChange
    }

    deinit {
        if let token {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    func start() {
        guard token == nil else { return }
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // `queue: nil` means the block runs on the posting thread. AppKit posts this one
            // on the main thread; `assumeIsolated` asserts that rather than assuming it.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onChange(self.isReduced)
            }
        }
    }

    func stop() {
        guard let token else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(token)
        self.token = nil
    }
}

// MARK: - Particle Texture Factory
//
// CAEmitterCell needs CGImage textures; CGBitmapContext is reliable here.

/// Shared with `MeteorShower`, which flies one of these sprites on its own layer.
enum ParticleTextures {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        return CGContext(
            data: nil,
            width: max(width, 1),
            height: max(height, 1),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    /// A vertical raindrop streak: soft at both ends, brightest along its spine,
    /// drawn once and cached like every other texture here. Rain is drawn stretched
    /// rather than round because that is what a raindrop looks like to anything with
    /// an exposure time — a drop falling at 6–9 m/s crosses far more than its own
    /// diameter while the eye (or a 1/30 s shutter) integrates it; round dots read as
    /// falling confetti. Real-time renderers do the same with velocity-stretched
    /// billboards; `CAEmitterCell` has no per-particle stretch, so the stretch is
    /// baked into the texture and the whole cell rotated to match the wind instead.
    static func streak(
        length: CGFloat, width: CGFloat, color: CGColor, tilt: CGFloat = 0
    ) -> CGImage? {
        // Drawn leaning rather than rotated at the layer: rotating the emitter
        // swings its emission line off the top of the screen and leaves a dry
        // wedge down one side. The canvas grows to fit the rotated streak.
        let span = abs(length * sin(tilt)) + abs(width * cos(tilt))
        let w = max(Int(ceil(max(span, width))), 2)
        let h = max(Int(ceil(abs(length * cos(tilt)) + abs(width * sin(tilt)))), 4)
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        if tilt != 0 {
            ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            ctx.rotate(by: tilt)
            ctx.translateBy(x: -width / 2, y: -length / 2)
        }
        guard let opaque = color.copy(alpha: 1.0), let clear = color.copy(alpha: 0.0),
              let along = CGGradient(
                colorsSpace: colorSpace,
                colors: [clear, opaque, opaque, clear] as CFArray,
                // The long fade sits on the trailing end and the leading end is cut
                // short — what a motion-blurred drop looks like, and the only cue for
                // which way it is going; it used to be the other way round, so the
                // streak trailed off ahead of the drop.
                locations: [0.0, 0.55, 0.9, 1.0]
              )
        else { return nil }

        // The streak narrows toward its tail, not a parallel bar: Garg & Nayar's streak
        // model (Columbia CAVE, TOG 2006), and games following it, draw a drop as an
        // uneven capsule (width held, blur thinning behind) — a constant-width bar is
        // what most makes rain read as scratches on the screen.
        let taper = CGMutablePath()
        let tailInset = width * 0.35
        taper.move(to: CGPoint(x: 0, y: 0))
        taper.addLine(to: CGPoint(x: width, y: 0))
        taper.addLine(to: CGPoint(x: width - tailInset, y: length))
        taper.addLine(to: CGPoint(x: tailInset, y: length))
        taper.closeSubpath()
        ctx.addPath(taper)
        ctx.clip()

        // Taper across the width so the edges do not alias into hard bars. Normalised to
        // the brightest column: a one- or two-column streak has no centre column, and
        // unnormalised it came out at a quarter of its colour — the far rain bands were
        // all but invisible (measured: peak 21/255 against a lit threshold of 24).
        let steps = max(Int(ceil(width)), 2)
        let edges = stride(from: 0, to: steps, by: 1).map { column -> CGFloat in
            let t = (CGFloat(column) + 0.5) / CGFloat(steps)
            return 1 - abs(t * 2 - 1)
        }
        let peak = edges.max() ?? 1
        for (column, edge) in edges.enumerated() {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: CGFloat(column), y: 0, width: 1, height: length))
            ctx.setAlpha((edge / peak) * (edge / peak))
            ctx.drawLinearGradient(
                along,
                start: CGPoint(x: 0, y: length),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    static func softCircle(radius: CGFloat, color: CGColor) -> CGImage? {
        let diameter = max(Int(ceil(radius * 2)), 2)
        guard let ctx = makeContext(width: diameter, height: diameter) else { return nil }

        let center = CGPoint(x: CGFloat(diameter) / 2, y: CGFloat(diameter) / 2)
        let endRadius = CGFloat(diameter) / 2

        guard let opaqueColor = color.copy(alpha: 1.0),
              let transparent = color.copy(alpha: 0.0),
              let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [opaqueColor, transparent] as CFArray,
                locations: [0.0, 1.0]
              )
        else { return nil }

        ctx.drawRadialGradient(
            gradient,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: endRadius,
            options: []
        )

        return ctx.makeImage()
    }

    static func sakuraPetal(width: CGFloat, height: CGFloat, color: CGColor) -> CGImage? {
        let w = max(Int(ceil(width)), 2)
        let h = max(Int(ceil(height)), 2)
        guard let ctx = makeContext(width: w, height: h) else { return nil }

        let widthF = CGFloat(w)
        let heightF = CGFloat(h)

        // Base at the bottom, sides bulging, and the notch a cherry petal has at
        // its tip — the earlier symmetric lozenge read as a pink blob.
        let path = CGMutablePath()
        let midX = widthF / 2
        path.move(to: CGPoint(x: midX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: widthF * 0.82, y: heightF * 0.96),
            control: CGPoint(x: widthF * 1.18, y: heightF * 0.42)
        )
        path.addQuadCurve(
            to: CGPoint(x: midX, y: heightF * 0.78),
            control: CGPoint(x: widthF * 0.66, y: heightF * 0.98)
        )
        path.addQuadCurve(
            to: CGPoint(x: widthF * 0.18, y: heightF * 0.96),
            control: CGPoint(x: widthF * 0.34, y: heightF * 0.98)
        )
        path.addQuadCurve(
            to: CGPoint(x: midX, y: 0),
            control: CGPoint(x: -widthF * 0.18, y: heightF * 0.42)
        )
        path.closeSubpath()

        ctx.addPath(path)
        ctx.clip()

        guard let lightColor = color.copy(alpha: 1.0),
              let edgeColor = color.copy(alpha: 0.55),
              let gradient = CGGradient(
                colorsSpace: colorSpace,
                colors: [lightColor, edgeColor] as CFArray,
                locations: [0.0, 1.0]
              )
        else {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: widthF, height: heightF))
            return ctx.makeImage()
        }

        ctx.drawRadialGradient(
            gradient,
            startCenter: CGPoint(x: widthF * 0.5, y: heightF * 0.6),
            startRadius: 0,
            endCenter: CGPoint(x: widthF * 0.5, y: heightF * 0.5),
            endRadius: max(widthF, heightF),
            options: []
        )
        return ctx.makeImage()
    }

    /// A bubble: a bright rim, a nearly empty middle, and one small specular
    /// highlight. Drawn hollow because that is what makes it read as a shell
    /// of water rather than as a ball — a filled disc is a snowflake.
    static func bubble(radius: CGFloat, color: CGColor) -> CGImage? {
        let diameter = max(Int(ceil(radius * 2)), 4)
        guard let ctx = makeContext(width: diameter, height: diameter) else { return nil }
        let side = CGFloat(diameter)
        let center = CGPoint(x: side / 2, y: side / 2)

        guard let rim = color.copy(alpha: 1.0),
              let faint = color.copy(alpha: 0.14),
              let clear = color.copy(alpha: 0.0),
              let shell = CGGradient(
                colorsSpace: colorSpace,
                colors: [clear, faint, faint, rim, clear] as CFArray,
                // Empty core, a faint wash of internal reflection, then the
                // rim right at the edge.
                locations: [0.0, 0.35, 0.72, 0.93, 1.0]
              )
        else { return nil }

        ctx.drawRadialGradient(
            shell,
            startCenter: center, startRadius: 0,
            endCenter: center, endRadius: side / 2,
            options: []
        )

        // Specular dot, up and to the left, where a single light source puts it.
        let highlight = CGPoint(x: side * 0.33, y: side * 0.7)
        if let hot = color.copy(alpha: 0.85),
           let gone = color.copy(alpha: 0.0),
           let spark = CGGradient(
            colorsSpace: colorSpace, colors: [hot, gone] as CFArray, locations: [0.0, 1.0]
           ) {
            ctx.drawRadialGradient(
                spark,
                startCenter: highlight, startRadius: 0,
                endCenter: highlight, endRadius: side * 0.16,
                options: []
            )
        }
        return ctx.makeImage()
    }

    /// A meteor: a hot round head with a long tail behind it. Same lean-baked-into-the-
    /// bitmap trick as ``streak`` — the sprite is flown along its own axis, so the angle
    /// has to be in the pixels — but the brightness runs the other way: a raindrop is a
    /// uniform blur, a meteor is a burning object with a trail, so nearly all the light
    /// is at the leading end and the tail is what is left behind it.
    static func comet(
        length: CGFloat, width: CGFloat, color: CGColor, tilt: CGFloat
    ) -> CGImage? {
        let head = max(width * 2.6, 4)
        // Room for the head glow on every side. Sized to the streak alone, the rotated
        // glow ran off the canvas and the head came out as a hard little square.
        let w = max(Int(ceil(abs(length * sin(tilt)) + abs(width * cos(tilt)) + head * 2)), 8)
        let h = max(Int(ceil(abs(length * cos(tilt)) + abs(width * sin(tilt)) + head * 2)), 8)
        guard let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: tilt)
        ctx.translateBy(x: -width / 2, y: -length / 2)

        guard let opaque = color.copy(alpha: 1.0), let clear = color.copy(alpha: 0.0),
              let tail = CGGradient(
                  colorsSpace: colorSpace,
                  colors: [clear, opaque] as CFArray,
                  locations: [0.0, 1.0]
              )
        else { return nil }

        // Tail: drawn from the trailing end (top of the local box) down to the head, and
        // narrowing towards that end — a parallel bar reads as a scratch on the glass.
        let taper = CGMutablePath()
        let tailInset = width * 0.42
        taper.move(to: CGPoint(x: 0, y: 0))
        taper.addLine(to: CGPoint(x: width, y: 0))
        taper.addLine(to: CGPoint(x: width - tailInset, y: length))
        taper.addLine(to: CGPoint(x: tailInset, y: length))
        taper.closeSubpath()
        ctx.saveGState()
        ctx.addPath(taper)
        ctx.clip()
        let steps = max(Int(ceil(width)), 2)
        let edges = stride(from: 0, to: steps, by: 1).map { column -> CGFloat in
            let t = (CGFloat(column) + 0.5) / CGFloat(steps)
            return 1 - abs(t * 2 - 1)
        }
        let peak = edges.max() ?? 1
        for (column, edge) in edges.enumerated() {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: CGFloat(column), y: 0, width: 1, height: length))
            ctx.setAlpha((edge / peak) * (edge / peak))
            ctx.drawLinearGradient(
                tail,
                start: CGPoint(x: 0, y: length),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // Head: a wide soft halo with a hot core inside it. One gradient alone gave
        // either a dim smudge or a hard dot.
        let at = CGPoint(x: width / 2, y: 0)
        if let halo = color.copy(alpha: 0.45), let gone = color.copy(alpha: 0.0),
           let bloom = CGGradient(
               colorsSpace: colorSpace, colors: [halo, gone] as CFArray, locations: [0.0, 1.0]
           ) {
            ctx.drawRadialGradient(
                bloom, startCenter: at, startRadius: 0, endCenter: at, endRadius: head,
                options: []
            )
        }
        if let core = color.copy(alpha: 1.0), let gone = color.copy(alpha: 0.0),
           let hot = CGGradient(
               colorsSpace: colorSpace, colors: [core, core, gone] as CFArray,
               locations: [0.0, 0.35, 1.0]
           ) {
            ctx.drawRadialGradient(
                hot, startCenter: at, startRadius: 0, endCenter: at, endRadius: head * 0.42,
                options: []
            )
        }
        return ctx.makeImage()
    }

    static func leaf(width: CGFloat, height: CGFloat, color: CGColor) -> CGImage? {
        let w = max(Int(ceil(width)), 2)
        let h = max(Int(ceil(height)), 2)
        guard let ctx = makeContext(width: w, height: h) else { return nil }

        let widthF = CGFloat(w)
        let heightF = CGFloat(h)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: heightF / 2))
        path.addCurve(
            to: CGPoint(x: widthF, y: heightF / 2),
            control1: CGPoint(x: widthF * 0.3, y: heightF),
            control2: CGPoint(x: widthF * 0.7, y: heightF)
        )
        path.addCurve(
            to: CGPoint(x: 0, y: heightF / 2),
            control1: CGPoint(x: widthF * 0.7, y: 0),
            control2: CGPoint(x: widthF * 0.3, y: 0)
        )
        path.closeSubpath()

        ctx.setFillColor(color)
        ctx.addPath(path)
        ctx.fillPath()
        return ctx.makeImage()
    }
}
