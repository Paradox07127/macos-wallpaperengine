import Foundation
import simd

/// One particle object instance simulated in WPE 2.8.42's order (R18): SoA slots sized maxcount, children nested.
/// Not Sendable because every system of a scene shares the scene's `WPEParityMT19937`.
public struct WPEParityParticleSystem {
    /// `instanceoverride` multipliers; color is 0–1 and alpha/color seed each birth (R18 初始化器).
    struct Instance {
        var rate: Float = 1
        var count: Float = 1
        var lifetime: Float = 1
        var size: Float = 1
        var speed: Float = 1
        var alpha: Float = 1
        var color = SIMD3<Float>(repeating: 1)
        var brightness: Float = 1

        init(_ override: WPESceneParticleInstanceOverride? = nil) {
            guard let override else { return }
            // Object update multiplies dt by the instance rate, floored at 0.01 (D/140230650.c:55-64).
            rate = Float(max(override.rate ?? 1, 0.01))
            count = Float(max(override.count ?? 1, 0))
            lifetime = Float(max(override.lifetime ?? 1, 0))
            size = Float(max(override.size ?? 1, 0))
            speed = Float(max(override.speed ?? 1, 0))
            alpha = Float(override.alpha ?? 1)
            color = override.color.map { SIMD3<Float>($0 / 255) } ?? color
            brightness = Float(max(override.brightness ?? 1, 0))
        }
    }

    struct EmitterState {
        var accumulator: Float = 0
        var delayLeft: Float
        var durationLeft: Float
        var disabled = false
        var burstPending: Bool
        var periodOn = true
        var periodLeft: Float = 0
        var emittedThisPeriod = 0
    }

    struct PendingEvent {
        var child: Int
        var position: SIMD3<Float>
    }

    let config: WPEParityParticleConfig
    let instance: Instance
    let material: WPEParityParticleMaterial
    let rng: WPEParityMT19937
    let origin: SIMD3<Float>
    let capacity: Int

    public var renderers: [WPEParityParticleRenderer] {
        config.renderers
    }

    /// Initializers, operators, emitters, renderers and children that were skipped, by name.
    public var diagnostics: [String] {
        config.diagnostics
    }

    public internal(set) var prewarmStep: Float = 0
    public internal(set) var prewarmStepCount = 0
    public internal(set) var liveCount = 0

    /// Slot arrays of length maxcount; a slot is live while `lifetime[slot] != 0`.
    public internal(set) var position: [SIMD3<Float>]
    public internal(set) var velocity: [SIMD3<Float>]
    public internal(set) var rotation: [SIMD3<Float>]
    public internal(set) var angularVelocity: [SIMD3<Float>]
    public internal(set) var color: [SIMD3<Float>]
    public internal(set) var initialColor: [SIMD3<Float>]
    public internal(set) var alpha: [Float]
    public internal(set) var initialAlpha: [Float]
    public internal(set) var size: [Float]
    public internal(set) var initialSize: [Float]
    public internal(set) var age: [Float]
    public internal(set) var lifetime: [Float]
    /// The first U[0,1) drawn at birth; oscillate* and randomframe read it.
    public internal(set) var birthU: [Float]
    public internal(set) var frame: [Float]

    /// `static` children in JSON order.
    public internal(set) var children: [WPEParityParticleSystem] = []
    /// One group per eventspawn / eventdeath child in JSON order; each event adds an instance at the parent particle.
    public internal(set) var eventChildren: [[WPEParityParticleSystem]] = []

    var emitterStates: [EmitterState]
    var childGroup: [Int] = []
    var pendingEvents: [PendingEvent] = []
    var freeHint = 0
    var highWater = 0
    /// Birth-order list for the rope renderer (D/140236cd0.c:82-109).
    var birthNext: [Int32]
    var birthPrevious: [Int32]
    var birthHead: Int32 = -1
    var birthTail: Int32 = -1
    /// Ropetrail history ring per slot, pushed every length/segments seconds (D/1401d2340.c:776-779).
    var trailSegments = 0
    var trailInterval: Float = 0
    var trailTimer: Float = 0
    var trailPoints: [SIMD3<Float>] = []
    var trailCount: [Int32] = []
    var trailHead: [Int32] = []
    var mainBytes: [UInt8] = []
    var ropeBytes: [UInt8] = []
    var ropeTrailBytes: [UInt8] = []

    /// `starttime` prewarms here; children are parsed through `resolveChild(path)`.
    public init(
        json: WPESceneJSONValue,
        instanceOverride: WPESceneParticleInstanceOverride? = nil,
        rng: WPEParityMT19937,
        is3D: Bool = false,
        material: WPEParityParticleMaterial = .init(),
        origin: SIMD3<Float> = .zero,
        resolveChild: (String) -> WPESceneJSONValue? = { _ in nil }
    ) {
        self.init(
            config: WPEParityParticleConfig(json: json, is3D: is3D, resolveChild: resolveChild),
            instance: Instance(instanceOverride), rng: rng, material: material, origin: origin
        )
    }

    init(
        config: WPEParityParticleConfig, instance: Instance, rng: WPEParityMT19937,
        material: WPEParityParticleMaterial, origin: SIMD3<Float>
    ) {
        self.config = config
        self.instance = instance
        self.rng = rng
        self.material = material
        self.origin = origin
        let capacity = Int((Float(config.maxCount) * instance.count).rounded())
        self.capacity = capacity
        position = Array(repeating: .zero, count: capacity)
        velocity = position
        rotation = position
        angularVelocity = position
        color = position
        initialColor = position
        alpha = Array(repeating: 0, count: capacity)
        initialAlpha = alpha
        size = alpha
        initialSize = alpha
        age = alpha
        lifetime = alpha
        birthU = alpha
        frame = alpha
        birthNext = Array(repeating: -1, count: capacity)
        birthPrevious = birthNext
        emitterStates = config.emitters.map { emitter in
            EmitterState(
                delayLeft: emitter.delay, durationLeft: emitter.duration, burstPending: emitter.instantaneous > 0,
                periodLeft: emitter.periodic ? rng.draw(emitter.periodicDurationMin, emitter.periodicDurationMax) : 0
            )
        }
        if let trail = config.renderers.first(where: { $0.kind == .ropeTrail }) {
            trailSegments = trail.segments
            trailInterval = trail.length / Float(trail.segments)
            trailTimer = trailInterval
            trailPoints = Array(repeating: .zero, count: capacity * trail.segments)
            trailCount = Array(repeating: 0, count: capacity)
            trailHead = trailCount
        }
        for child in config.children {
            if child.trigger == .always {
                childGroup.append(children.count)
                children.append(WPEParityParticleSystem(
                    config: child.config, instance: Instance(), rng: rng, material: .init(), origin: origin + child.origin
                ))
            } else {
                childGroup.append(eventChildren.count)
                eventChildren.append([])
            }
        }
        prewarm()
    }

    /// One object update: dt × instance rate (D/140230650.c:55-64).
    public mutating func advance(dt: Float) {
        step(dt: dt * instance.rate)
    }

    /// Fixed 0.05 s steps, 0.2 s at maxcount ≥ 500, until starttime is covered (D/14022ebe0.c:349-367).
    private mutating func prewarm() {
        guard config.startTime > 0 else { return }
        prewarmStep = capacity < 500 ? 0.05 : 0.2
        var elapsed: Float = 0
        while elapsed < config.startTime {
            step(dt: prewarmStep)
            elapsed += prewarmStep
            prewarmStepCount += 1
        }
    }

    /// age/death → emit → operators, then children after the parent (D/140236cd0.c:54-79, D/1402308a0.c:2734-2767).
    mutating func step(dt: Float) {
        guard dt > 0 else { return }
        for slot in 0 ..< highWater where lifetime[slot] != 0 {
            age[slot] += dt
            if age[slot] > lifetime[slot] {
                kill(slot)
            }
        }
        for index in config.emitters.indices {
            emit(index, dt: dt)
        }
        runOperators(dt: dt)
        pushTrailHistory(dt: dt)
        for event in pendingEvents {
            let child = config.children[event.child]
            eventChildren[childGroup[event.child]].append(WPEParityParticleSystem(
                config: child.config, instance: Instance(), rng: rng, material: .init(),
                origin: event.position + child.origin
            ))
        }
        pendingEvents.removeAll(keepingCapacity: true)
        for index in children.indices {
            children[index].step(dt: dt)
        }
        for group in eventChildren.indices {
            for index in eventChildren[group].indices {
                eventChildren[group][index].step(dt: dt)
            }
            eventChildren[group].removeAll { $0.isFinished }
        }
    }

    /// No live particles, nothing left to emit, no live descendants.
    var isFinished: Bool {
        guard liveCount == 0 else { return false }
        for (emitter, state) in zip(config.emitters, emitterStates) {
            let idle = emitter.rate == 0 && !state.burstPending && !emitter.periodic
            if !state.disabled, !idle {
                return false
            }
        }
        return children.allSatisfy(\.isFinished) && eventChildren.allSatisfy(\.isEmpty)
    }

    private mutating func kill(_ slot: Int) {
        lifetime[slot] = 0
        liveCount -= 1
        freeHint = min(freeHint, slot)
        let next = birthNext[slot], previous = birthPrevious[slot]
        if previous >= 0 {
            birthNext[Int(previous)] = next
        } else {
            birthHead = next
        }
        if next >= 0 {
            birthPrevious[Int(next)] = previous
        } else {
            birthTail = previous
        }
        // eventdeath fires when U ≤ probability (D/140236cd0.c:203-251).
        for (index, child) in config.children.enumerated() where child.trigger == .death {
            if rng.unit() <= child.probability {
                pendingEvents.append(PendingEvent(child: index, position: position[slot]))
            }
        }
    }

    /// Gate live < maxcount, enabled, delay ≤ 0; acc += rate·dt and the burst both come out of acc (S 590140-590184).
    private mutating func emit(_ index: Int, dt: Float) {
        let emitter = config.emitters[index]
        var state = emitterStates[index]
        if !state.disabled, state.delayLeft <= 0, state.periodOn, liveCount < capacity {
            state.accumulator += emitter.rate * instance.count * dt
            if state.burstPending {
                state.accumulator += Float(emitter.instantaneous) * instance.count
                state.burstPending = false
            }
            let wanted = Int(state.accumulator)
            state.accumulator -= Float(wanted)
            var count = min(wanted, capacity - liveCount)
            if emitter.periodic, emitter.maxPerPeriod > 0 {
                count = min(count, emitter.maxPerPeriod - state.emittedThisPeriod)
                state.emittedThisPeriod += count
            }
            for _ in 0 ..< count {
                spawn(emitter)
            }
        }
        // Frame end: a pending delay only counts down; a duration disables at ≤ 0 (D/1402378a0.c:1771-1794).
        if state.delayLeft > 0 {
            state.delayLeft -= dt
        } else if state.durationLeft > 0 {
            state.durationLeft -= dt
            state.disabled = state.durationLeft <= 0
        }
        if emitter.periodic, state.delayLeft <= 0 {
            state.periodLeft -= dt
            if state.periodLeft <= 0 {
                state.periodOn.toggle()
                state.periodLeft += state.periodOn
                    ? rng.draw(emitter.periodicDurationMin, emitter.periodicDurationMax)
                    : rng.draw(emitter.periodicDelayMin, emitter.periodicDelayMax)
                state.emittedThisPeriod = 0
            }
        }
        emitterStates[index] = state
    }

    /// Lowest free slot; u first, then the emitter shape, then initializers in JSON order (D/14023b340.c:281-320).
    private mutating func spawn(_ emitter: WPEParityParticleEmitterConfig) {
        var slot = freeHint
        while lifetime[slot] != 0 {
            slot += 1
        }
        freeHint = slot + 1
        highWater = max(highWater, slot + 1)
        liveCount += 1
        let u = rng.unit()
        let launch = emitter.sample(rng: rng)
        position[slot] = origin + emitter.origin + launch.offset
        velocity[slot] = launch.velocity
        rotation[slot] = .zero
        angularVelocity[slot] = .zero
        age[slot] = 0
        lifetime[slot] = 1
        initialSize[slot] = 0.5
        initialColor[slot] = instance.color
        initialAlpha[slot] = instance.alpha
        birthU[slot] = u
        frame[slot] = config.randomFrame ? u : 0
        for initializer in config.initializers {
            initialize(slot, initializer)
        }
        lifetime[slot] = max(lifetime[slot] * instance.lifetime, 0.001)
        initialSize[slot] *= instance.size
        velocity[slot] *= instance.speed
        size[slot] = initialSize[slot]
        color[slot] = initialColor[slot]
        alpha[slot] = initialAlpha[slot]
        birthPrevious[slot] = birthTail
        birthNext[slot] = -1
        if birthTail >= 0 {
            birthNext[Int(birthTail)] = Int32(slot)
        } else {
            birthHead = Int32(slot)
        }
        birthTail = Int32(slot)
        if trailSegments > 0 {
            trailCount[slot] = 0
        }
        for (index, child) in config.children.enumerated() where child.trigger == .spawn {
            pendingEvents.append(PendingEvent(child: index, position: position[slot]))
        }
    }

    /// D/14023b340.c:360-825.
    private mutating func initialize(_ slot: Int, _ initializer: WPEParityParticleInitializer) {
        switch initializer {
        case let .lifetime(low, high, exponent):
            lifetime[slot] = max(low + pow(rng.unit(), exponent) * (high - low), 0.001)
        case let .size(low, high, exponent):
            initialSize[slot] *= low + pow(rng.unit(), exponent) * (high - low)
        case let .color(low, high):
            let r = rng.unit()
            initialColor[slot] = initialColor[slot] * (low + r * (high - low)) / 255
        case let .hsvColor(hue, saturation, value):
            let h = rng.draw(hue.x, hue.y)
            let s = rng.draw(saturation.x, saturation.y)
            let v = rng.draw(value.x, value.y)
            initialColor[slot] *= WPEParityParticleMath.hsvToRGB(hue: h, saturation: s, value: v)
        case let .colorList(colors):
            let pick = min(Int(rng.unit() * Float(colors.count)), colors.count - 1)
            initialColor[slot] = initialColor[slot] * colors[pick] / 255
        case let .alpha(low, high):
            initialAlpha[slot] *= rng.draw(low, high)
        case let .velocity(low, high):
            // Sampled z, y, x (D/1401bac50.c:16-25).
            let z = rng.draw(low.z, high.z)
            let y = rng.draw(low.y, high.y)
            let x = rng.draw(low.x, high.x)
            velocity[slot] += SIMD3(x, y, z)
        case let .rotation(low, high):
            rotation[slot] += draw(low, high)
        case let .angularVelocity(low, high):
            angularVelocity[slot] += draw(low, high)
        }
    }

    private func draw(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> SIMD3<Float> {
        let x = rng.draw(low.x, high.x)
        let y = rng.draw(low.y, high.y)
        let z = rng.draw(low.z, high.z)
        return SIMD3(x, y, z)
    }

    /// Size always, colour and alpha reset to their initial values, then each operator multiplies in JSON order (S 596803-596833).
    private mutating func runOperators(dt: Float) {
        for slot in 0 ..< highWater where lifetime[slot] != 0 {
            size[slot] = initialSize[slot]
            color[slot] = initialColor[slot]
            alpha[slot] = initialAlpha[slot]
        }
        for entry in config.operators {
            for slot in 0 ..< highWater where lifetime[slot] != 0 {
                let t = age[slot] / lifetime[slot]
                apply(entry.kind, slot: slot, t: t, weight: entry.blend?.weight(t: t) ?? 1, dt: dt)
            }
        }
    }

    private mutating func apply(_ kind: WPEParityParticleOperator.Kind, slot: Int, t: Float, weight: Float, dt: Float) {
        typealias Math = WPEParityParticleMath
        func blended(_ factor: Float) -> Float {
            1 + (factor - 1) * weight
        }
        switch kind {
        case let .movement(gravity, drag):
            Math.move(
                position: &position[slot], velocity: &velocity[slot],
                acceleration: gravity * weight, drag: drag * weight, dt: dt
            )
        case let .angularMovement(force, drag):
            Math.move(
                position: &rotation[slot], velocity: &angularVelocity[slot],
                acceleration: force * weight, drag: drag * weight, dt: dt
            )
        case let .alphaFade(fadeIn, fadeOut):
            alpha[slot] *= blended(Math.alphaFade(t: t, fadeIn: fadeIn, fadeOut: fadeOut))
        case let .sizeChange(ramp):
            size[slot] *= blended(Math.ramp(
                t: t, startTime: ramp.startTime, endTime: ramp.endTime, start: ramp.start, end: ramp.end
            ))
        case let .alphaChange(ramp):
            alpha[slot] *= blended(Math.ramp(
                t: t, startTime: ramp.startTime, endTime: ramp.endTime, start: ramp.start, end: ramp.end
            ))
        case let .colorChange(startTime, endTime, start, end):
            let factor = Math.ramp(t: t, startTime: startTime, endTime: endTime, start: start, end: end)
            color[slot] *= 1 + (factor - 1) * weight
        case let .oscillatePosition(wave, mask):
            position[slot] += weight * Math.oscillationOffset(
                age: age[slot], dt: dt, u: birthU[slot], wave: wave, mask: mask
            )
        case let .oscillateAlpha(wave):
            alpha[slot] *= blended(Math.oscillation(age: age[slot], u: birthU[slot], wave: wave))
        case let .oscillateSize(wave):
            size[slot] *= blended(Math.oscillation(age: age[slot], u: birthU[slot], wave: wave))
        case let .capVelocity(maxSpeed):
            // v ×= min(1, max·rsqrt|v|²) (S 600856-600891).
            let speed = simd_length(velocity[slot])
            if speed > maxSpeed {
                velocity[slot] *= blended(maxSpeed / speed)
            }
        }
    }

    private mutating func pushTrailHistory(dt: Float) {
        guard trailSegments > 0 else { return }
        trailTimer -= dt
        guard trailTimer <= 0 else { return }
        trailTimer = max(trailTimer + trailInterval, 0)
        for slot in 0 ..< highWater where lifetime[slot] != 0 {
            let head = (Int(trailHead[slot]) + 1) % trailSegments
            trailHead[slot] = Int32(head)
            trailPoints[slot * trailSegments + head] = position[slot]
            trailCount[slot] = min(trailCount[slot] + 1, Int32(trailSegments))
        }
    }
}
