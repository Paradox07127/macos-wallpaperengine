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

    /// Rebuilds the emitter for a new lean.
    ///
    /// Not a layer rotation: rotating the emitter swings its emission line off
    /// the top of the screen and leaves a dry wedge down one side (measured —
    /// at 0.45 rad the rain covered only the left ~60%). The lean lives in the
    /// cells' heading and in the streak texture instead, so the line stays
    /// where it is. Weather refreshes hourly, so rebuilding is cheap; the guard
    /// keeps a no-op update from restarting the field for nothing.
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

    /// Three depth layers rather than one flat sheet.
    ///
    /// Speeds follow the measured terminal velocities: drizzle-sized drops fall
    /// around 2 m/s and the biggest stable drops around 9 m/s, so the near
    /// layer runs roughly twice the far layer's speed rather than some
    /// arbitrary spread. Far particles are smaller, slower, fainter and shorter
    /// — which is what depth looks like — and they are also the cheapest, so
    /// the layer that carries the most particles is the one that costs least.
    private static func rainPreset(tilt: CGFloat) -> EmitterPreset {
        let makeLayer = {
            (scale: CGFloat, velocity: CGFloat, birthRate: Float,
             alpha: CGFloat, length: CGFloat, width: CGFloat) -> CAEmitterCell in
            let cell = CAEmitterCell()
            cell.contents = ParticleTextures.streak(
                length: length, width: width,
                color: NSColor.white.withAlphaComponent(alpha).cgColor,
                tilt: tilt
            )
            cell.birthRate = birthRate
            cell.lifetime = 4
            cell.lifetimeRange = 1
            cell.velocity = velocity
            cell.velocityRange = velocity * 0.18
            // Travel direction matches the lean baked into the texture, so a
            // drop always points the way it is going.
            cell.emissionLongitude = -.pi / 2 + tilt
            cell.emissionRange = .pi / 90      // rain falls in lines, not cones
            cell.scale = scale
            cell.scaleRange = scale * 0.25
            cell.alphaRange = 0.2
            cell.yAcceleration = -160
            cell.color = NSColor(white: 1, alpha: alpha).cgColor
            return cell
        }

        // near, mid, far — the far layer is the densest and the dimmest.
        let near = makeLayer(1.15, 300, 55, 0.75, 26, 2.4)
        let mid = makeLayer(0.8, 230, 95, 0.5, 18, 2.0)
        let far = makeLayer(0.5, 165, 130, 0.3, 12, 1.6)

        return EmitterPreset(
            cells: [near, mid, far],
            shape: .line,
            renderMode: .unordered,
            position: { CGPoint(x: $0.midX, y: $0.maxY) },
            // Much wider than the screen: leaning rain enters from off the
            // upwind edge, and a screen-width line leaves that side dry.
            size: { CGSize(width: $0.width * 2.4, height: 0) }
        )
    }

    // MARK: - Mist

    /// Fog, as a handful of very large, very faint, very slow sprites.
    ///
    /// Deliberately not a full-screen noise shader: that is a per-pixel cost
    /// paid every frame forever, and this layer is up for hours. Apple lists
    /// fog among `CAEmitterLayer`'s own use cases, and for "a slowly drifting
    /// translucent veil" — as opposed to fog that has to weave between objects
    /// and self-shadow — big soft billboards are the cheap way to get there.
    ///
    /// Very few particles on purpose: each sprite covers a large area, so the
    /// look comes from overlap rather than from count. Three sizes at three
    /// speeds keep it from reading as one sliding sheet.
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
    //
    // Sun-shaft motes: tiny warm specks drifting in all directions with a
    // very slow lift. Three depth layers (near / mid / far) so it reads as
    // volumetric rather than a flat sprite sheet.

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
    //
    // Nearly stationary points with strong alpha-pulse so the field reads
    // as a slow twinkle. Cool palette (white-blue) sits well against night
    // wallpapers without forcing a specific color theme.

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

    /// A vertical raindrop streak: soft at both ends, brightest along its
    /// spine, drawn once and cached like every other texture here.
    ///
    /// Rain is drawn stretched rather than round because that is what a
    /// raindrop looks like to anything with an exposure time — a drop falling
    /// at 6–9 m/s crosses far more than its own diameter while the eye (or a
    /// 1/30 s shutter) integrates it. Round dots read as falling confetti.
    /// Real-time renderers do the same thing with velocity-stretched
    /// billboards; `CAEmitterCell` has no per-particle stretch, so the stretch
    /// is baked into the texture and the whole cell is rotated to match the
    /// wind instead.
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
                // Fades in fast and trails out slowly: the tail is the part of
                // the streak the eye reads as "this was moving downwards".
                locations: [0.0, 0.25, 0.7, 1.0]
              )
        else { return nil }

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
