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

        init() {}

        /// `json` is the particle file; `hdr` is the scene's HDR bit (ctx+0x118 & 0x2000).
        init(_ override: WPESceneParticleInstanceOverride?, json: WPESceneJSONValue, hdr: Bool) {
            guard let override else { return }
            // Object update multiplies dt by the instance rate, floored at 0.01 (D/140230650.c:55-64).
            rate = Float(max(override.rate ?? 1, 0.01))
            count = Float(max(override.count ?? 1, 0))
            lifetime = Float(max(override.lifetime ?? 1, 0))
            size = Float(max(override.size ?? 1, 0))
            speed = Float(max(override.speed ?? 1, 0))
            alpha = Float(override.alpha ?? 1)
            // R22 Q9: colour only without `"hascolor": true`; brightness only in HDR with particle flags bit3 clear.
            if !WPEParityParticleJSON.flag(json["hascolor"]) {
                color = override.color.map { SIMD3<Float>($0 / 255) } ?? color
            }
            if hdr, Int(WPEParityParticleJSON.number(json["flags"]) ?? 0) & 8 == 0 {
                brightness = Float(max(override.brightness ?? 1, 0))
            }
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
    let crt: WPEParityCRTRandom
    /// Baked into births: zero except for an event child, which starts at its event in the parent's space.
    private(set) var origin: SIMD3<Float>
    /// Static-child origins from the object down to this system, which the model matrix carries (R16 Q4).
    private(set) var localTransform: simd_float4x4
    /// A worldspace root or static child: its model matrix is I, so births go through the object matrix.
    let emitsInWorld: Bool
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
    /// Per event group, finished instances the next events reset instead of allocating new slot arrays.
    var finishedEventChildren: [[WPEParityParticleSystem]] = []

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
    /// The inputs of the frame being stepped; prewarm steps with the defaults.
    var frameContext = WPEParityParticleFrameContext()
    /// Control point transforms (translation in column 3) and last frame's translations.
    var controlPoints = Array(repeating: matrix_identity_float4x4, count: WPEParityParticleControlPoint.count)
    var previousControlPoints = Array(repeating: SIMD3<Float>.zero, count: WPEParityParticleControlPoint.count)
    var controlPointsSeeded = false
    /// Positions at the start of the operator pass: the path segment controlpointattract tests.
    var previousPosition: [SIMD3<Float>]
    /// One per initializer; only the mapsequence entries move theirs.
    var sequenceStates: [WPEParityParticleSequenceState]
    /// Frame counter boids splits its slot blocks by (ctx+0x144).
    var boidsFrame = 0
    /// Event-child systems this system has constructed, for tests.
    var eventChildConstructions = 0

    /// `starttime` prewarms here; children are parsed through `resolveChild(path)`.
    /// `crt` is the scene's CRT `rand()` state, shared like `rng`. Brightness overrides need an HDR scene, which
    /// only `WPEParityParticleScene` knows.
    public init(
        json: WPESceneJSONValue,
        instanceOverride: WPESceneParticleInstanceOverride? = nil,
        rng: WPEParityMT19937,
        crt: WPEParityCRTRandom = WPEParityCRTRandom(),
        is3D: Bool = false,
        material: WPEParityParticleMaterial = .init(),
        resolveChild: (String) -> WPESceneJSONValue? = { _ in nil }
    ) {
        var config = WPEParityParticleConfig(json: json, is3D: is3D, resolveChild: resolveChild)
        config.material = material
        self.init(config: config, instance: Instance(instanceOverride, json: json, hdr: false), rng: rng, crt: crt)
    }

    /// `context` is what prewarm steps with; an event child (`eventOrigin` set) uses its parent's space.
    init(
        config: WPEParityParticleConfig, instance: Instance, rng: WPEParityMT19937, crt: WPEParityCRTRandom,
        eventOrigin: SIMD3<Float>? = nil, localTransform: simd_float4x4 = matrix_identity_float4x4,
        context: WPEParityParticleFrameContext = .init()
    ) {
        self.config = config
        self.instance = instance
        self.rng = rng
        self.crt = crt
        material = config.material
        origin = eventOrigin ?? .zero
        self.localTransform = localTransform
        emitsInWorld = eventOrigin == nil && config.flags & 1 != 0
        frameContext = context
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
        previousPosition = position
        sequenceStates = config.initializers.map(Self.sequenceState)
        birthNext = Array(repeating: -1, count: capacity)
        birthPrevious = birthNext
        emitterStates = config.emitters.map { Self.emitterState($0, rng: rng) }
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
                    config: child.config, instance: Instance(), rng: rng, crt: crt,
                    localTransform: localTransform * Self.translation(child.origin), context: context
                ))
            } else {
                childGroup.append(eventChildren.count)
                eventChildren.append([])
                finishedEventChildren.append([])
            }
        }
        prewarm()
    }

    private static func sequenceState(_ initializer: WPEParityParticleInitializer) -> WPEParityParticleSequenceState {
        switch initializer {
        case let .sequenceAround(field): WPEParityParticleSequenceState(step: 1 / Float(field.count))
        case let .sequenceBetween(field): WPEParityParticleSequenceState(step: 1 / Float(field.count - 1))
        default: WPEParityParticleSequenceState()
        }
    }

    private static func emitterState(_ emitter: WPEParityParticleEmitterConfig, rng: WPEParityMT19937) -> EmitterState {
        EmitterState(
            delayLeft: emitter.delay, durationLeft: emitter.duration, burstPending: emitter.instantaneous > 0,
            periodLeft: emitter.periodic ? rng.draw(emitter.periodicDurationMin, emitter.periodicDurationMax) : 0
        )
    }

    /// Turns a finished event child into the system `init` would build for a new event, with the same RNG draws,
    /// clearing its slot arrays in place. Event children have no children of their own.
    private mutating func reuseForEvent(origin: SIMD3<Float>, localTransform: simd_float4x4,
                                        context: WPEParityParticleFrameContext) {
        self.origin = origin
        self.localTransform = localTransform
        frameContext = context
        restart()
        prewarm()
    }

    /// A hidden object with live particles starts over at time 0: no particles, emitters as built, static children
    /// reset and event children destroyed (140230650.c:16-67). It is not prewarmed again.
    mutating func reset() {
        restart()
        for index in children.indices {
            children[index].reset()
        }
        for group in eventChildren.indices {
            finishedEventChildren[group] += eventChildren[group]
            eventChildren[group].removeAll(keepingCapacity: true)
        }
    }

    var hasLiveParticles: Bool {
        liveCount > 0 || children.contains(where: \.hasLiveParticles) || eventChildren.contains { !$0.isEmpty }
    }

    /// Live particles of this system and every descendant.
    var totalLiveCount: Int {
        children.reduce(liveCount) { $0 + $1.totalLiveCount }
            + eventChildren.joined().reduce(0) { $0 + $1.totalLiveCount }
    }

    /// Clears the slot arrays in place and rebuilds the emitter state with the same RNG draws `init` makes.
    private mutating func restart() {
        func clear<Element>(_ array: inout [Element], to value: Element) {
            array.withUnsafeMutableBufferPointer { $0.update(repeating: value) }
        }
        prewarmStep = 0
        prewarmStepCount = 0
        liveCount = 0
        clear(&position, to: .zero)
        clear(&velocity, to: .zero)
        clear(&rotation, to: .zero)
        clear(&angularVelocity, to: .zero)
        clear(&color, to: .zero)
        clear(&initialColor, to: .zero)
        clear(&previousPosition, to: .zero)
        clear(&alpha, to: 0)
        clear(&initialAlpha, to: 0)
        clear(&size, to: 0)
        clear(&initialSize, to: 0)
        clear(&age, to: 0)
        clear(&lifetime, to: 0)
        clear(&birthU, to: 0)
        clear(&frame, to: 0)
        clear(&birthNext, to: -1)
        clear(&birthPrevious, to: -1)
        birthHead = -1
        birthTail = -1
        freeHint = 0
        highWater = 0
        pendingEvents.removeAll(keepingCapacity: true)
        for index in sequenceStates.indices {
            sequenceStates[index] = Self.sequenceState(config.initializers[index])
        }
        for index in emitterStates.indices {
            emitterStates[index] = Self.emitterState(config.emitters[index], rng: rng)
        }
        trailTimer = trailInterval
        clear(&trailPoints, to: .zero)
        clear(&trailCount, to: 0)
        clear(&trailHead, to: 0)
        clear(&controlPoints, to: matrix_identity_float4x4)
        clear(&previousControlPoints, to: .zero)
        controlPointsSeeded = false
        boidsFrame = 0
    }

    /// One object update: dt × instance rate (D/140230650.c:55-64).
    public mutating func advance(dt: Float, frame: WPEParityParticleFrameContext = .init()) {
        frameContext = frame
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

    /// age/death → control points → emit → operators, then children after the parent
    /// (D/140236cd0.c:54-79, 360; D/1402308a0.c:2734-2767).
    mutating func step(dt: Float, parentControlPoints: [simd_float4x4]? = nil) {
        guard dt > 0 else { return }
        for slot in 0 ..< highWater where lifetime[slot] != 0 {
            age[slot] += dt
            if age[slot] > lifetime[slot] {
                kill(slot)
            }
        }
        updateControlPoints(parent: parentControlPoints)
        for index in config.emitters.indices {
            emit(index, dt: dt)
        }
        runOperators(dt: dt)
        boidsFrame &+= 1
        pushTrailHistory(dt: dt)
        for event in pendingEvents {
            let child = config.children[event.child]
            let group = childGroup[event.child]
            let origin = event.position + child.origin
            if let last = finishedEventChildren[group].indices.last {
                finishedEventChildren[group][last].reuseForEvent(origin: origin, localTransform: localTransform,
                                                                 context: frameContext)
                eventChildren[group].append(finishedEventChildren[group].removeLast())
            } else {
                eventChildConstructions += 1
                eventChildren[group].append(WPEParityParticleSystem(
                    config: child.config, instance: Instance(), rng: rng, crt: crt,
                    eventOrigin: origin, localTransform: localTransform, context: frameContext
                ))
            }
        }
        pendingEvents.removeAll(keepingCapacity: true)
        for index in children.indices {
            children[index].frameContext = frameContext
            children[index].step(dt: dt, parentControlPoints: controlPoints)
        }
        for group in eventChildren.indices {
            for index in eventChildren[group].indices {
                eventChildren[group][index].frameContext = frameContext
                eventChildren[group][index].step(dt: dt, parentControlPoints: controlPoints)
            }
            var index = 0
            while index < eventChildren[group].count {
                if eventChildren[group][index].isFinished {
                    finishedEventChildren[group].append(eventChildren[group].remove(at: index))
                } else {
                    index += 1
                }
            }
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
        if emitsInWorld {
            // [I] A top-level worldspace M is I (R22 Q1), so births are placed in the world here.
            let placement = frameContext.objectMatrix * localTransform
            let world = placement * SIMD4(position[slot], 1)
            position[slot] = SIMD3(world.x, world.y, world.z)
            let moved = placement * SIMD4(velocity[slot], 0)
            velocity[slot] = SIMD3(moved.x, moved.y, moved.z)
        }
        rotation[slot] = .zero
        angularVelocity[slot] = .zero
        age[slot] = 0
        lifetime[slot] = 1
        initialSize[slot] = 0.5
        initialColor[slot] = instance.color
        initialAlpha[slot] = instance.alpha
        birthU[slot] = u
        frame[slot] = config.randomFrame ? u : 0
        for (index, initializer) in config.initializers.enumerated() {
            initialize(slot, initializer, index: index)
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

    /// D/14023b340.c:360-1032.
    private mutating func initialize(_ slot: Int, _ initializer: WPEParityParticleInitializer, index: Int) {
        switch initializer {
        case let .lifetime(low, high, exponent):
            lifetime[slot] = max(low + pow(rng.unit(), exponent) * (high - low), 0.001)
        case let .size(low, high, exponent):
            initialSize[slot] *= low + pow(rng.unit(), exponent) * (high - low)
        case let .color(low, high, exponent):
            let r = shaped(rng.unit(), exponent)
            initialColor[slot] = initialColor[slot] * (low + r * (high - low)) / 255
        case let .hsvColor(hsv):
            initializeHSV(hsv, slot: slot)
        case let .colorList(colors, noise):
            initializeColorList(colors, noise: noise, slot: slot)
        case let .turbulentVelocity(field):
            initializeTurbulentVelocity(field, slot: slot)
        case let .positionOffset(field):
            initializePositionOffset(field, slot: slot)
        case let .sequenceAround(field):
            initializeSequenceAround(field, index: index, slot: slot)
        case let .sequenceBetween(field):
            initializeSequenceBetween(field, index: index, slot: slot)
        case let .alpha(low, high):
            initialAlpha[slot] *= rng.draw(low, high)
        case let .velocity(low, high):
            // Sampled z, y, x (D/1401bac50.c:16-25).
            let z = rng.draw(low.z, high.z)
            let y = rng.draw(low.y, high.y)
            let x = rng.draw(low.x, high.x)
            velocity[slot] += SIMD3(x, y, z)
        case let .rotation(low, high, exponent):
            rotation[slot] += draw(low, high, exponent)
        case let .angularVelocity(low, high, exponent):
            angularVelocity[slot] += draw(low, high, exponent)
        }
    }

    /// powf(U, exp) only when exp ≠ 1 (D/14023b340.c:387-410, 668-695).
    private func shaped(_ u: Float, _ exponent: Float) -> Float {
        exponent == 1 ? u : pow(u, exponent)
    }

    private func draw(_ low: SIMD3<Float>, _ high: SIMD3<Float>, _ exponent: Float) -> SIMD3<Float> {
        let x = low.x + shaped(rng.unit(), exponent) * (high.x - low.x)
        let y = low.y + shaped(rng.unit(), exponent) * (high.y - low.y)
        let z = low.z + shaped(rng.unit(), exponent) * (high.z - low.z)
        return SIMD3(x, y, z)
    }

    /// Size always, colour and alpha reset to their initial values, then each operator multiplies in JSON order (S 596803-596833).
    private mutating func runOperators(dt: Float) {
        for slot in 0 ..< highWater where lifetime[slot] != 0 {
            size[slot] = initialSize[slot]
            color[slot] = initialColor[slot]
            alpha[slot] = initialAlpha[slot]
            previousPosition[slot] = position[slot]
        }
        for entry in config.operators {
            if case let .boids(field) = entry.kind {
                applyBoids(field, blend: entry.blend, dt: dt)
                continue
            }
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
        case let .turbulence(field):
            applyTurbulence(field, slot: slot, weight: weight, dt: dt)
        case let .controlPointAttract(field):
            applyAttract(field, slot: slot, weight: weight, dt: dt)
        case let .vortex(field):
            applyVortex(field, slot: slot, weight: weight, dt: dt)
        case let .vortexRing(field):
            applyVortexRing(field, slot: slot, weight: weight, dt: dt)
        case .boids:
            break
        case let .maintainDistance(controlPoint, distance, variableStrength):
            applyMaintainDistance(
                controlPoint: controlPoint, distance: distance, variableStrength: variableStrength,
                slot: slot, weight: weight, dt: dt
            )
        case let .maintainDistanceBetween(start, end):
            applyMaintainBetween(start: start, end: end, slot: slot, weight: weight)
        case let .reduceMovement(controlPoint, inner, outer, reductionInner, reductionDelta):
            applyReduceMovement(
                controlPoint: controlPoint, inner: inner, outer: outer, reductionInner: reductionInner,
                reductionDelta: reductionDelta, slot: slot, weight: weight, dt: dt
            )
        case let .collisionPlane(field):
            applyCollisionPlane(field, slot: slot, weight: weight)
        case let .collisionSphere(field):
            applyCollisionSphere(field, slot: slot, weight: weight)
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
