import AppKit
import LiveWallpaperCore
import QuartzCore

final class ParticleOverlayView: NSView {

    // MARK: - State

    private var currentEffect: ParticleEffect = .none

    private var activeEmitter: CAEmitterLayer?
    private(set) var isSuspended = false

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

        guard effect != .none else { return }

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
    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if let activeEmitter {
            applySuspensionState(to: activeEmitter)
        }
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
    var debugEmitterState: (isHidden: Bool, speed: Float, birthRate: Float)? {
        activeEmitter.map { ($0.isHidden, $0.speed, $0.birthRate) }
    }

    /// The cells a preset would build, so a test can fly them itself.
    func debugCells(for effect: ParticleEffect, tilt: CGFloat) -> [CAEmitterCell] {
        preset(for: effect, tilt: tilt).cells
    }
    #endif

    // MARK: - Layout

    override func layout() {
        super.layout()
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
    }

    private func preset(for effect: ParticleEffect, tilt: CGFloat) -> EmitterPreset {
        switch effect {
        case .none:          return Self.emptyPreset
        case .snow:          return Self.snowPreset(tilt: tilt)
        case .rain:          return Self.rainPreset(tilt: tilt)
        case .bokeh:         return Self.bokehPreset
        case .fireflies:     return Self.firefliesPreset
        case .dust:          return Self.dustPreset
        case .stars:         return Self.starsPreset
        case .fallingLeaves: return Self.leavesPreset
        case .sakura:        return Self.sakuraPreset
        case .mist:          return Self.mistPreset
        case .embers:        return Self.embersPreset
        case .bubbles:       return Self.bubblesPreset
        case .meteors:       return Self.meteorsPreset
        }
    }

    private static let emptyPreset = EmitterPreset(
        cells: [],
        shape: .point,
        renderMode: .unordered,
        position: { _ in .zero },
        size: { _ in .zero }
    )

    // MARK: - Snow

    private static func snowPreset(tilt: CGFloat) -> EmitterPreset {
        let createLayer = { (scale: CGFloat, velocity: CGFloat, birthRate: Float, alpha: Float, radius: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(radius: radius, color: NSColor.white.cgColor)
            cell.birthRate = birthRate
            cell.lifetime = 15
            cell.lifetimeRange = 5
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.3
            // A flake is round, so only its heading moves with the wind —
            // there is no shape to point the other way.
            cell.emissionLongitude = -.pi / 2 + tilt
            // Wide on purpose: snowflakes flutter and tumble on the way down
            // — the behaviour that separates snow from rain at a glance — and
            // a narrow cone made them fall like slow rain.
            cell.emissionRange = .pi / 4
            cell.scale = scale
            cell.scaleRange = scale * 0.3
            cell.alphaRange = alpha * 0.3
            cell.xAcceleration = 10 * scale
            cell.yAcceleration = -15 * scale
            cell.color = NSColor(white: 1, alpha: CGFloat(alpha)).cgColor
            return cell
        }

        let near = createLayer(1.2, 50, 10, 0.6, 6.0)
        let mid = createLayer(0.6, 30, 30, 0.8, 3.0)
        let far = createLayer(0.3, 15, 60, 0.4, 2.0)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            // Snow leans much further than rain for the same wind, so its line
            // has to reach further past the upwind edge.
            size: { CGSize(width: $0.width * 2.4, height: 0) }
        )
    }

    // MARK: - Rain

    /// Three depth layers, not one flat sheet. Speeds follow measured terminal
    /// velocities (drizzle ~3 m/s, biggest stable drops ~9 m/s), so the near layer
    /// runs ~2x the far layer's speed, not an arbitrary spread. Far particles are
    /// smaller/slower/fainter/shorter (what depth looks like) and cheapest, so the
    /// layer with the most particles costs least — counts mirror that (small drops
    /// vastly outnumber large, the Marshall–Palmer shape), which is why the far layer
    /// is densest.
    private static func rainPreset(tilt: CGFloat) -> EmitterPreset {
        // Lean per drop is `atan(wind / itsOwnFallSpeed)`: a slow small drop leans much
        // further than a fast large one in the same wind. `tilt` is worked out for the
        // middle layer; each layer re-derives its own from its own speed, else the whole
        // field slants in lockstep — the sprite-sheet tell.
        let reference: CGFloat = 460
        let leanFor: (CGFloat) -> CGFloat = { speed in
            guard tilt != 0, speed > 0 else { return 0 }
            return atan(tan(tilt) * reference / speed)
        }
        // Streak length is the motion blur of one exposure, so it is
        // proportional to speed rather than picked per layer.
        let exposure: CGFloat = 0.0433

        let makeLayer = {
            (scale: CGFloat, velocity: CGFloat, birthRate: Float,
             alpha: CGFloat, width: CGFloat) -> CAEmitterCell in
            let lean = leanFor(velocity)
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.streak(
                length: velocity * exposure, width: width,
                color: NSColor.white.withAlphaComponent(alpha).cgColor,
                tilt: lean
            )
            cell.birthRate = birthRate
            cell.lifetime = 4
            cell.lifetimeRange = 1
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.18
            // Travel direction matches the lean baked into the texture, so a
            // drop always points the way it is going.
            cell.emissionLongitude = -.pi / 2 + lean
            cell.emissionRange = .pi / 90      // rain falls in lines, not cones
            cell.scale = scale
            cell.scaleRange = scale * 0.25
            cell.alphaRange = 0.2
            // No gravity: a drop is already at terminal velocity, so its path is a straight
            // line. Accelerating it swung the heading from 0.5 rad at birth to 0.10 rad at
            // death (measured) while the streak bitmap stayed at 0.5 — the drop spent most of
            // its life drawn pointing 20° away from where it was actually going.
            cell.yAcceleration = 0
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        // near, mid, far — the far layer is the densest and the dimmest.
        // Speeds are what the old cells averaged once gravity had had its say,
        // so removing the acceleration did not turn the rain into drizzle.
        let near = makeLayer(1.15, 600, 55, 0.75, 2.4)
        let mid = makeLayer(0.8, reference, 95, 0.5, 2.0)
        let far = makeLayer(0.5, 330, 130, 0.3, 1.6)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            // Much wider than the screen: leaning rain enters from off the
            // upwind edge, and a screen-width line leaves that side dry. The
            // slowest layer leans furthest, so this is sized for that one.
            size: { CGSize(width: $0.width * 2.4, height: 0) }
        )
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
        let makeLayer = {
            (scale: CGFloat, velocity: CGFloat, birthRate: Float,
             radius: CGFloat, life: Float, drift: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.softCircle(
                radius: radius, color: NSColor.white.cgColor
            )
            cell.birthRate = birthRate
            cell.lifetime = life
            cell.lifetimeRange = life * 0.4
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.5
            cell.emissionLongitude = .pi / 2          // straight up
            cell.emissionRange = .pi / 7
            cell.scale = scale
            cell.scaleRange = scale * 0.6
            cell.scaleSpeed = -scale / CGFloat(life) * 0.5
            cell.alphaRange = 0.35
            cell.alphaSpeed = -1.0 / life
            cell.yAcceleration = 14
            cell.xAcceleration = drift
            cell.color = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.42, alpha: 0.9).cgColor
            // Cools to a deep red over the spark's life.
            cell.greenSpeed = -0.5 / life
            cell.blueSpeed = -0.4 / life
            return cell
        }

        let near = makeLayer(1.3, 70, 6, 3.5, 7, 6)
        let mid = makeLayer(0.8, 52, 14, 2.5, 9, -4)
        let far = makeLayer(0.45, 36, 26, 1.8, 11, 3)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .additive,
            position: { CGPoint(x: $0.midX, y: $0.minY) },
            size: { CGSize(width: $0.width * 1.1, height: 0) }
        )
    }()

    // MARK: - Bubbles

    /// Rising bubbles, as seen from inside the water. Bigger bubbles rise faster —
    /// the real relation, and what sells the depth: large near ones climb past small
    /// far ones. `CAEmitterCell` can't make a particle wander, so the sideways wobble
    /// is faked across banks instead of within one — the two halves drift in opposite
    /// directions, so the field as a whole meanders though no single bubble does.
    private static let bubblesPreset: EmitterPreset = {
        let makeLayer = {
            (scale: CGFloat, velocity: CGFloat, birthRate: Float,
             radius: CGFloat, alpha: CGFloat, drift: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.bubble(radius: radius, color: NSColor.white.cgColor)
            cell.birthRate = birthRate
            cell.lifetime = 22
            cell.lifetimeRange = 6
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.35
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 12
            cell.scale = scale
            cell.scaleRange = scale * 0.45
            cell.alphaRange = Float(alpha * 0.4)
            cell.spin = 0.2
            cell.spinRange = 0.6
            cell.xAcceleration = drift
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        let near = makeLayer(1.25, 46, 3, 15, 0.5, 1.6)
        let mid = makeLayer(0.75, 32, 7, 11, 0.38, -1.2)
        let far = makeLayer(0.4, 21, 14, 8, 0.26, 0.9)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.minY) },
            size: { CGSize(width: $0.width, height: 0) }
        )
    }()

    // MARK: - Meteors

    /// A sparse shower of shooting stars across the upper sky. Deliberately rare and
    /// fast: a meteor always on screen is a streak of rain. The slant is fixed rather
    /// than wind-driven — meteors come in on their own path, and the whole field
    /// sharing one angle is what reads as a radiant shower rather than noise.
    private static let meteorsPreset: EmitterPreset = {
        // Shallow enough to read as "across the sky" rather than "falling".
        let slant: CGFloat = 1.0
        let makeLayer = {
            (scale: CGFloat, velocity: CGFloat, birthRate: Float,
             length: CGFloat, width: CGFloat, alpha: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.comet(
                length: length, width: width,
                color: NSColor(calibratedRed: 0.92, green: 0.96, blue: 1.0, alpha: alpha).cgColor,
                tilt: slant
            )
            cell.birthRate = birthRate
            cell.lifetime = 2.2
            cell.lifetimeRange = 0.6
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.2
            cell.emissionLongitude = -.pi / 2 + slant
            cell.emissionRange = .pi / 60
            cell.scale = scale
            cell.scaleRange = scale * 0.3
            cell.alphaRange = 0.25
            // Burns out rather than blinking off at the end of its life.
            cell.alphaSpeed = -Float(alpha) / 2.2
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        let bright = makeLayer(1.1, 900, 0.5, 200, 3.0, 0.9)
        let faint = makeLayer(0.6, 700, 1.1, 150, 2.2, 0.5)

        return EmitterPreset(
            cells: [bright, faint],
            shape: .line,
            renderMode: .additive,
            // Along the top, reaching well past the upwind edge so the slant
            // does not leave one corner empty.
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            size: { CGSize(width: $0.width * 3.0, height: 0) }
        )
    }()

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

    private static let leavesPreset: EmitterPreset = {
        let palette: [CGColor] = [
            NSColor(calibratedRed: 0.85, green: 0.4, blue: 0.1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.9, green: 0.7, blue: 0.1, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.6, green: 0.3, blue: 0.1, alpha: 1).cgColor
        ]
        
        var cells: [CAEmitterCell] = []
        for (i, color) in palette.enumerated() {
            let scaleMultiplier = CGFloat(1.0 - Float(i) * 0.25)
            
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.leaf(width: 14, height: 9, color: NSColor.white.cgColor)
            cell.birthRate = 8 * Float(i + 1)
            cell.lifetime = 16
            cell.lifetimeRange = 8
            cell.velocity = 35 * scaleMultiplier
            cell.velocityRange = 20 * scaleMultiplier
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 4
            cell.scale = 1.2 * scaleMultiplier
            cell.scaleRange = 0.4 * scaleMultiplier
            cell.alphaRange = 0.3
            cell.spin = 1.5
            cell.spinRange = 2.0
            cell.xAcceleration = 20 * scaleMultiplier
            cell.yAcceleration = -10 * scaleMultiplier
            cell.color = color
            
            cells.append(cell)
        }

        return EmitterPreset(
            cells: cells,
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX - $0.width * 0.2, y: $0.maxY) },
            size: { CGSize(width: $0.width * 1.5, height: 0) }
        )
    }()

    // MARK: - Sakura

    private static let sakuraPreset: EmitterPreset = {
        let baseColor = NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.82, alpha: 1.0).cgColor
        
        let createLayer = { (scale: CGFloat, velocity: CGFloat, birthRate: Float, alpha: Float, sizeOffset: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.sakuraPetal(width: 16 + sizeOffset, height: 14 + sizeOffset, color: NSColor.white.cgColor)
            cell.birthRate = birthRate
            cell.lifetime = 15
            cell.lifetimeRange = 5
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.4
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 4
            cell.scale = scale
            cell.scaleRange = scale * 0.3
            cell.alphaRange = alpha * 0.3
            cell.spin = 1.0
            cell.spinRange = 2.0
            cell.xAcceleration = 25 * scale
            cell.yAcceleration = -12 * scale
            cell.color = baseColor.copy(alpha: CGFloat(alpha)) ?? baseColor
            
            cell.redRange = 0.1
            cell.greenRange = 0.1
            cell.blueRange = 0.1
            
            return cell
        }

        let near = createLayer(1.4, 55, 6, 0.7, 4.0)
        let mid = createLayer(0.9, 40, 15, 0.9, 0.0)
        let far = createLayer(0.5, 25, 30, 0.5, -4.0)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX - $0.width * 0.3, y: $0.maxY) },
            size: { CGSize(width: $0.width * 1.6, height: 0) }
        )
    }()

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

// MARK: - Particle Texture Factory
//
// CAEmitterCell needs CGImage textures; CGBitmapContext is reliable here.

private enum ParticleTextures {

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

        // Taper across the width so the edges do not alias into hard bars.
        let steps = max(Int(ceil(width)), 2)
        for column in 0..<steps {
            let t = (CGFloat(column) + 0.5) / CGFloat(steps)
            let edge = 1 - abs(t * 2 - 1)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: CGFloat(column), y: 0, width: 1, height: length))
            ctx.setAlpha(edge * edge)
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

        let path = CGMutablePath()
        let tipX = widthF / 2
        path.move(to: CGPoint(x: tipX, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: heightF),
            control: CGPoint(x: widthF * 1.15, y: heightF * 0.5)
        )
        path.addQuadCurve(
            to: CGPoint(x: tipX, y: 0),
            control: CGPoint(x: -widthF * 0.15, y: heightF * 0.5)
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
    /// bitmap trick as ``streak`` — rotating the emitter would swing its emission line
    /// off the screen — but the brightness runs the other way: a raindrop is a uniform
    /// blur, a meteor is a burning object with a trail, so nearly all the light is at
    /// the leading end and the tail is what is left behind it.
    static func comet(
        length: CGFloat, width: CGFloat, color: CGColor, tilt: CGFloat
    ) -> CGImage? {
        let head = width * 1.8
        let w = max(Int(ceil(abs(length * sin(tilt)) + head)), 4)
        let h = max(Int(ceil(abs(length * cos(tilt)) + head)), 4)
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

        // Tail: drawn from the trailing end (top of the local box) down to the
        // head, tapered across its width so it does not alias into a bar.
        let steps = max(Int(ceil(width)), 2)
        for column in 0..<steps {
            let t = (CGFloat(column) + 0.5) / CGFloat(steps)
            let edge = 1 - abs(t * 2 - 1)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: CGFloat(column), y: 0, width: 1, height: length))
            ctx.setAlpha(edge * edge)
            ctx.drawLinearGradient(
                tail,
                start: CGPoint(x: 0, y: length),
                end: CGPoint(x: 0, y: 0),
                options: []
            )
            ctx.restoreGState()
        }

        if let core = color.copy(alpha: 1.0), let gone = color.copy(alpha: 0.0),
           let glow = CGGradient(
            colorsSpace: colorSpace, colors: [core, gone] as CFArray, locations: [0.0, 1.0]
           ) {
            let at = CGPoint(x: width / 2, y: 0)
            ctx.drawRadialGradient(
                glow, startCenter: at, startRadius: 0, endCenter: at, endRadius: head,
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
