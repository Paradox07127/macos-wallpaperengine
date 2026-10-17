import Foundation
import simd

/// One particle object instance simulated in WPE 2.8.42's order: SoA slots sized maxcount, children nested.
/// Not Sendable because every system of a scene shares the scene's `WPEParityMT19937`.
public struct WPEParityParticleSystem {
    /// `instanceoverride` multipliers; color is 0–1 and alpha/color seed each birth.
    struct Instance: Equatable {
        var rate: Float = 1
        var count: Float = 1
        var lifetime: Float = 1
        var size: Float = 1
        var speed: Float = 1
        var alpha: Float = 1
        var color = SIMD3<Float>(repeating: 1)
        /// The override or a script supplied colorn; without it `color` is only the default.
        var hasColorn = false
        var brightness: Float = 1
        var controlPointOffsets = [SIMD3<Float>?](repeating: nil, count: WPEParityParticleControlPoint.count)
        var controlPointAngles = [SIMD3<Float>?](repeating: nil, count: WPEParityParticleControlPoint.count)

        init() {}

        /// Colour/brightness gates are applied per system at birth; children may have different hascolor/flags.
        init(_ override: WPESceneParticleInstanceOverride?, hdr: Bool) {
            guard let override else { return }
            // Object update multiplies dt by the instance rate, floored at 0.01 (D/140230650.c:55-64).
            rate = Float(max(override.rate ?? 1, 0.01))
            count = Float(max(override.count ?? 1, 0))
            lifetime = Float(max(override.lifetime ?? 1, 0))
            size = Float(max(override.size ?? 1, 0))
            speed = Float(max(override.speed ?? 1, 0))
            alpha = Float(override.alpha ?? 1)
            // Normalized colorn and the HDR brightness become the system's birth colour seed.
            color = override.color.map { SIMD3<Float>($0 / 255) } ?? color
            hasColorn = override.color != nil
            if hdr {
                brightness = Float(max(override.brightness ?? 1, 0))
            }
        }

        /// A fresh child's copy: 22f890 hands it the override fields but no CP overrides (only 22bd40 applies those).
        var childConstruction: Instance {
            var copy = self
            copy.controlPointOffsets = Array(repeating: nil, count: WPEParityParticleControlPoint.count)
            copy.controlPointAngles = copy.controlPointOffsets
            return copy
        }
    }

    struct EmitterState {
        var accumulator: Float = 0
        var delayLeft: Float
        var durationLeft: Float
        var disabled = false
        var burstPending: Bool
        /// Native +0x40: positive on duration, nonpositive off delay; transitions discard overshoot.
        var periodTimer: Float = 0
        var emittedThisPeriod = 0
    }

    struct PendingEvent {
        /// A nil child is the parent-death detach marker, before that slot's death children/prewarm.
        var child: Int?
        var position: SIMD3<Float>
        var slot: Int
    }

    let config: WPEParityParticleConfig
    var instance: Instance
    /// Event instances created after a hot update inherit that update, without changing the loaded child path.
    private var hasScriptInstanceChanges = false
    /// Owner +0x3f7 & 2: the root's colorn validity, which 22f890 copies unchanged to every descendant.
    private var colornRootValid = true
    /// Valid colorn (22f890:21-31) seeds births and re-hues colorrandom.
    private(set) var colornActive = false
    /// Re-hued colorrandom endpoints (0–255) by initializer index; empty while colorn is invalid.
    private var colorRanges: [Int: (low: SIMD3<Float>, high: SIMD3<Float>)] = [:]
    /// Re-hued colorchange operators by operator index; empty while colorn is invalid.
    private var colorChanges: [Int: WPEParityParticleOperator.Kind] = [:]
    let material: WPEParityParticleMaterial
    let rng: WPEParityMT19937
    let crt: WPEParityCRTRandom
    /// Native inst+0x3a0: the unique per-instance placement E, not a cumulative ancestor transform.
    private(set) var instanceTransform: simd_float4x4
    let bulkControlPointStart: Int?
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
    /// One group per follow/spawn/death child in JSON order; each event adds an instance at the parent particle.
    public internal(set) var eventChildren: [[WPEParityParticleSystem]] = []
    /// Per event group, finished instances the next events reset instead of allocating new slot arrays.
    var finishedEventChildren: [[WPEParityParticleSystem]] = []

    var emitterStates: [EmitterState]
    var childGroup: [Int] = []
    var pendingEvents: [PendingEvent] = []
    /// Native system byte +0x41 & 0xc: births record spawn/follow events; starttime prewarm clears it (2378a0:1796).
    var birthsRecordSpawnEvents = true
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
    /// Control point transforms (translation in column 3) and the previous operator pass's full transforms.
    var controlPoints = Array(repeating: matrix_identity_float4x4, count: WPEParityParticleControlPoint.count)
    /// Native CP+0x80 bases are rebuilt by the property hook, not by every simulation step.
    var controlPointBases = Array(repeating: matrix_identity_float4x4,
                                  count: WPEParityParticleControlPoint.count)
    var previousControlPoints = Array(repeating: matrix_identity_float4x4,
                                      count: WPEParityParticleControlPoint.count)
    var controlPointsSeeded = false
    /// Positions at the start of the operator pass: the path segment controlpointattract tests.
    var previousPosition: [SIMD3<Float>]
    /// One per initializer; only the mapsequence entries move theirs.
    var sequenceStates: [WPEParityParticleSequenceState]
    /// Frame counter boids splits its slot blocks by (ctx+0x144).
    var boidsFrame = 0
    /// Event-child systems this system has constructed, for tests.
    var eventChildConstructions = 0
    /// inst+0x3f0, advanced by normal system updates, excluding construction prewarm (1402308a0:60).
    var simulationTime: Float = 0
    /// Owner +0x770: the root advances it; children receive that same owner time, including during prewarm.
    public internal(set) var objectTime: Float = 0
    /// The parent slot of an event child (inst+0x478) and what the parent holds there now.
    var parentSlot = -1
    var parentSample: WPEParityParticleParentSample?
    /// Native +0x438: parent-owned raw-slot counts. Parent death releases once, then detaches all matches;
    /// multiple follow groups can therefore leave a count with no attached instance (236cd0:121–202).
    private(set) var followReferences: [Int: Int32] = [:]
    /// Owner +0x3f7 bit 0, set by script pause: without a forced count the emitter pass is skipped (2378a0.c:362-363).
    var paused = false

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
        self.init(config: config, instance: Instance(instanceOverride, hdr: false), rng: rng, crt: crt)
    }

    /// Fresh/root/event push is conditional on this node's own world-space flag (229760).
    init(
        config: WPEParityParticleConfig, instance: Instance, rng: WPEParityMT19937, crt: WPEParityCRTRandom,
        instanceTransform: simd_float4x4? = nil,
        context: WPEParityParticleFrameContext = .init(), parentSlot: Int = -1,
        parentSample: WPEParityParticleParentSample? = nil, ownerTime: Float = 0,
        scriptInstance: Instance? = nil, parentControlPoints: [simd_float4x4]? = nil,
        parentControlPointCount: Int = 0, parentUpdateMatrix: simd_float4x4 = matrix_identity_float4x4,
        parentWorldSpace: Bool = false, bulkControlPointStart: Int? = nil, rootColornValid: Bool? = nil,
        paused: Bool = false
    ) {
        self.parentSlot = parentSlot
        self.parentSample = parentSample
        objectTime = ownerTime
        self.config = config
        let birthInstance = scriptInstance ?? instance
        self.instance = birthInstance
        hasScriptInstanceChanges = scriptInstance != nil
        self.rng = rng
        self.crt = crt
        material = config.material
        self.instanceTransform = instanceTransform ?? context.objectMatrix
        self.bulkControlPointStart = bulkControlPointStart
        frameContext = context
        frameContext.worldSpace = config.flags & 1 != 0
        frameContext.objectMatrix = frameContext.worldSpace
            ? self.instanceTransform : parentUpdateMatrix * self.instanceTransform
        // count scales emission only; the slots stay at maxcount (D/14022ebe0.c:355).
        let capacity = config.maxCount
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
        emitterStates = config.emitters.map(Self.emitterState)
        if let trail = config.renderers.first(where: { $0.kind == .ropeTrail }) {
            trailSegments = trail.segments
            trailInterval = trail.length / Float(trail.segments)
            trailTimer = trailInterval
            trailPoints = Array(repeating: .zero, count: capacity * trail.segments)
            trailCount = Array(repeating: 0, count: capacity)
            trailHead = trailCount
        }
        initializeControlPoints()
        updateColorn(rootColornValid: rootColornValid)
        self.paused = paused
        for child in config.children {
            if child.trigger == .always {
                childGroup.append(children.count)
                children.append(WPEParityParticleSystem(
                    config: child.config, instance: instance.childConstruction, rng: rng, crt: crt,
                    instanceTransform: Self.childTransform(child), context: frameContext,
                    ownerTime: ownerTime, scriptInstance: scriptInstance, parentControlPoints: controlPoints,
                    parentControlPointCount: controlPointCount, parentUpdateMatrix: frameContext.objectMatrix,
                    parentWorldSpace: frameContext.worldSpace,
                    bulkControlPointStart: child.flags & 1 == 0 ? nil : child.controlPointStartIndex,
                    rootColornValid: colornRootValid, paused: paused
                ))
            } else {
                childGroup.append(eventChildren.count)
                eventChildren.append([])
                finishedEventChildren.append([])
            }
        }
        updateControlPoints(parent: parentControlPoints, parentCount: parentControlPointCount,
                            parentUpdateMatrix: parentUpdateMatrix, parentWorldSpace: parentWorldSpace)
        commitControlPointHistory()
        prewarm(parent: parentControlPoints, parentCount: parentControlPointCount,
                parentUpdateMatrix: parentUpdateMatrix, parentWorldSpace: parentWorldSpace)
    }

    private static func sequenceState(_ initializer: WPEParityParticleInitializer) -> WPEParityParticleSequenceState {
        // 1c5490.c:7350-7435: a divisor ≤ 1e-4 becomes 1e-4; NaN fails that test and stays NaN.
        func step(_ divisor: Float) -> Float {
            1 / (divisor <= 1e-4 ? 1e-4 : divisor)
        }
        switch initializer {
        case let .sequenceAround(field): return WPEParityParticleSequenceState(step: step(field.count))
        case let .sequenceBetween(field): return WPEParityParticleSequenceState(step: step(field.count - 1))
        default: return WPEParityParticleSequenceState()
        }
    }

    private static func emitterState(_ emitter: WPEParityParticleEmitterConfig) -> EmitterState {
        // 1c1c70 initializes the signed timer to zero; the first eligible emit call draws the on duration.
        EmitterState(delayLeft: emitter.delay, durationLeft: emitter.duration, burstPending: emitter.instantaneous > 0)
    }

    /// Reuses the finished instance in place. Native reset/enable visits only static descendants and never
    /// clears their slots or CP/history (22f6c0/22f5b0). Only this event root prewarms again (22f430).
    private mutating func reuseForEvent(instanceTransform: simd_float4x4,
                                        context: WPEParityParticleFrameContext, parentSlot: Int,
                                        parentSample: WPEParityParticleParentSample?, ownerTime: Float,
                                        parentControlPoints: [simd_float4x4], parentCount: Int) {
        self.instanceTransform = instanceTransform
        self.parentSlot = parentSlot
        self.parentSample = parentSample
        objectTime = ownerTime
        setUpdateFrame(context, parentUpdateMatrix: context.objectMatrix, conditional: true)
        resetFinishedEventThroughStaticChildren()
        prewarm(parent: parentControlPoints, parentCount: parentCount,
                parentUpdateMatrix: context.objectMatrix, parentWorldSpace: context.worldSpace)
    }

    mutating func resetFinishedEventThroughStaticChildren() {
        simulationTime = 0
        prewarmStep = 0
        prewarmStepCount = 0
        // In place, not `map`: steady-state event reuse must keep every buffer (no reallocation per reuse).
        for index in emitterStates.indices {
            emitterStates[index] = Self.emitterState(config.emitters[index])
        }
        for index in sequenceStates.indices {
            sequenceStates[index].t = 0
        }
        for index in children.indices {
            children[index].resetFinishedEventThroughStaticChildren()
        }
    }

    /// A hidden object with live particles starts over at time 0: no particles, emitters restored as built (disabled
    /// bits kept) without new draws, sequence positions to 0, static children reset, event children destroyed (140230650.c:16-67,
    /// D/14022f6c0.c). Nothing calls the starttime prewarm again.
    mutating func reset() {
        objectTime = 0
        restart()
        for index in children.indices {
            children[index].reset()
        }
        for group in eventChildren.indices {
            // 22fd90 destroys active event instances; they are not finished and cannot enter the reuse pool.
            eventChildren[group].removeAll(keepingCapacity: true)
        }
        followReferences.removeAll(keepingCapacity: true)
    }

    /// Clears the pause bit; only a system with nothing alive re-enables its static tree, without timer resets
    /// (14024c5b0-14024c661, W6/14022f5b0.c).
    public mutating func play() {
        paused = false
        guard !isAlive else { return }
        enableEmissionThroughStaticChildren()
    }

    public mutating func pause() {
        paused = true
    }

    /// The hidden-layer reset, then emission disabled through the static tree; the pause bit is untouched (14024c680).
    public mutating func stop() {
        reset()
        stopEmissionThroughStaticChildren()
    }

    /// One root emitter pass with dt 0 forcing `count` births, even while paused; 0 forces 1, a negative count
    /// nothing (14024cac0-14024caf1).
    public mutating func emitParticles(_ count: Int32) {
        guard count >= 0 else { return }
        for index in config.emitters.indices {
            emit(index, dt: 0, forced: count == 0 ? 1 : Int(count))
        }
        processSpawnEvents()
    }

    public var isPlaying: Bool {
        !paused && isAlive
    }

    /// A live particle, an enabled emitter, or an alive static or active event descendant (W6/14022c310.c).
    var isAlive: Bool {
        liveCount != 0 || emitterStates.contains { !$0.disabled } || children.contains(where: \.isAlive)
            || eventChildren.joined().contains(where: \.isAlive)
    }

    /// Live particles of this system and every descendant.
    var totalLiveCount: Int {
        children.reduce(liveCount) { $0 + $1.totalLiveCount }
            + eventChildren.joined().reduce(0) { $0 + $1.totalLiveCount }
    }

    /// Hidden reset clears slots in place and restores emitter state without RNG or construction prewarm.
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
        simulationTime = 0
        for index in sequenceStates.indices {
            sequenceStates[index].t = 0
        }
        // 22f6c0 restores timers, burst and accumulator but leaves each disabled bit as it was.
        for index in emitterStates.indices {
            let disabled = emitterStates[index].disabled
            emitterStates[index] = Self.emitterState(config.emitters[index])
            emitterStates[index].disabled = disabled
        }
        trailTimer = trailInterval
        clear(&trailPoints, to: .zero)
        clear(&trailCount, to: 0)
        clear(&trailHead, to: 0)
        // 230650/22fd90 clear live storage, not CP base/current/previous.
        boidsFrame = 0
    }

    /// One object update: dt × instance rate (D/140230650.c:55-64).
    public mutating func advance(dt: Float, frame: WPEParityParticleFrameContext = .init()) {
        instanceTransform = frame.objectMatrix
        setUpdateFrame(frame, parentUpdateMatrix: matrix_identity_float4x4, conditional: true)
        objectTime += dt * instance.rate
        step(dt: dt * instance.rate)
    }

    /// The hook updates compiled emitter/birth parameters and control points, not existing particle slots
    /// (14022bd40 → 1401d15a0). Count changes the emitter multiplier while the loaded slot capacity stays fixed.
    mutating func applyScriptInstanceFields(state: WPEParitySceneState, objectID: String) {
        var next = instance
        func scalar(_ name: String, nonnegative: Bool = false) -> Float? {
            guard case let .vector(value)? = state.scriptField("instance.\(name)", of: objectID),
                  value.x.isFinite, !nonnegative || value.x >= 0 else { return nil }
            return value.x
        }
        func vector(_ name: String) -> SIMD3<Float>? {
            guard case let .vector(value)? = state.scriptField("instance.\(name)", of: objectID),
                  value.x.isFinite, value.y.isFinite, value.z.isFinite else { return nil }
            return SIMD3(value.x, value.y, value.z)
        }
        if let value = scalar("rate") {
            next.rate = max(value, 0.01)
        }
        if let value = scalar("count", nonnegative: true) {
            next.count = value
        }
        if let value = scalar("lifetime") {
            next.lifetime = value
        }
        if let value = scalar("size") {
            next.size = value
        }
        if let value = scalar("speed") {
            next.speed = value
        }
        if let value = scalar("alpha") {
            next.alpha = value
        }
        if state.hdr, let value = scalar("brightness") {
            next.brightness = value
        }
        // The script engine seeds unwritten colorn with the current colour; only a changed value is a script write.
        if let value = vector("colorn"), next.hasColorn || value != next.color {
            next.color = value
            next.hasColorn = true
        }
        for index in 0 ..< WPEParityParticleControlPoint.count {
            if let value = vector("controlpoint\(index)") {
                next.controlPointOffsets[index] = value.x == Float.greatestFiniteMagnitude ? nil : value
            }
            if let value = vector("controlpointangle\(index)") {
                next.controlPointAngles[index] = value.x == Float.greatestFiniteMagnitude ? nil : value
            }
        }
        guard next != instance else { return }
        useScriptInstance(next)
    }

    /// The native hook walks static children and both active/finished event pools with their shared owner.
    private mutating func useScriptInstance(_ next: Instance, rootColornValid: Bool? = nil,
                                            parentUpdateMatrix: simd_float4x4 = matrix_identity_float4x4) {
        let previousFrame = frameContext
        // 22bd40 pushes with 229760 even for a world static child, then pops after the recursive hook.
        setUpdateFrame(previousFrame, parentUpdateMatrix: parentUpdateMatrix, conditional: true)
        defer { frameContext = previousFrame }
        instance = next
        updateColorn(rootColornValid: rootColornValid)
        applyControlPointInstance()
        hasScriptInstanceChanges = true
        let matrix = frameContext.objectMatrix, rootValid = colornRootValid
        for index in children.indices {
            children[index].useScriptInstance(next, rootColornValid: rootValid, parentUpdateMatrix: matrix)
        }
        for group in eventChildren.indices {
            for index in eventChildren[group].indices {
                eventChildren[group][index].useScriptInstance(next, rootColornValid: rootValid,
                                                              parentUpdateMatrix: matrix)
            }
            for index in finishedEventChildren[group].indices {
                finishedEventChildren[group][index].useScriptInstance(next, rootColornValid: rootValid,
                                                                      parentUpdateMatrix: matrix)
            }
        }
    }

    /// `rootColornValid` is nil for the root, whose own validity becomes the bit its descendants receive.
    /// Valid colorn differs from `colornReference` by at least 0.0035294 in a channel (22f890:21-31).
    private mutating func updateColorn(rootColornValid: Bool?) {
        let reference = config.colornReference
        colornActive = rootColornValid != false && instance.hasColorn && config.flags & 8 == 0
            && simd_reduce_max(abs(instance.color - reference)) >= 0.0035294
        colornRootValid = rootColornValid ?? colornActive
        colorRanges.removeAll()
        colorChanges.removeAll()
        guard colornActive else { return }
        // Both endpoints move by colorn − reference in HSV: hue wraps, s/v clamp (1d15a0.c:248-402, 403-580).
        let shift = WPEParityParticleMath.rgbToHSV(instance.color) - WPEParityParticleMath.rgbToHSV(reference)
        func rehue(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
            let hsv = WPEParityParticleMath.rgbToHSV(rgb) + shift
            let saturated = simd_clamp(hsv, .zero, SIMD3(repeating: 1))
            return WPEParityParticleMath.hsvToRGB(hue: (hsv.x - hsv.x.rounded(.down)) * 360,
                                                  saturation: saturated.y, value: saturated.z)
        }
        for (index, initializer) in config.initializers.enumerated() {
            if case let .color(low, high, _) = initializer {
                colorRanges[index] = (rehue(low / 255) * 255, rehue(high / 255) * 255)
            }
        }
        for (index, entry) in config.operators.enumerated() {
            if case let .colorChange(startTime, endTime, start, end) = entry.kind {
                colorChanges[index] = .colorChange(startTime: startTime, endTime: endTime,
                                                   start: rehue(start), end: rehue(end))
            }
        }
    }

    /// Fixed 0.05 s steps, 0.2 s at maxcount ≥ 500, until starttime is covered (D/14022ebe0.c:349-367).
    private mutating func prewarm(parent: [simd_float4x4]?, parentCount: Int,
                                  parentUpdateMatrix: simd_float4x4, parentWorldSpace: Bool) {
        guard config.startTime > 0 else { return }
        prewarmStep = capacity < 500 ? 0.05 : 0.2
        var stepLimit = Float.infinity
        if let horizon = prewarmHorizon, config.startTime > horizon {
            // Stands in for the native full loop (D/14022ebe0.c:349-367); valid only because production prewarm uses a random seed.
            stepLimit = (horizon / prewarmStep).rounded(.up) + 2
        }
        let recorded = birthsRecordSpawnEvents
        birthsRecordSpawnEvents = false
        defer { birthsRecordSpawnEvents = recorded }
        var elapsed: Float = 0
        while elapsed < config.startTime, Float(prewarmStepCount) < stepLimit {
            simulate(dt: prewarmStep, parentControlPoints: parent, parentCount: parentCount,
                     parentUpdateMatrix: parentUpdateMatrix, parentWorldSpace: parentWorldSpace)
            elapsed += prewarmStep
            prewarmStepCount += 1
        }
    }

    /// Longest lifetime a birth can get, in seconds; nil when the prewarm's end state can also depend on older
    /// births or on the step count (non-continuous emitters, children, rope trails, sequence counters, boids).
    private var prewarmHorizon: Float? {
        guard config.children.isEmpty, trailSegments == 0, config.emitters.allSatisfy({
            !$0.periodic && $0.instantaneous == 0 && $0.duration <= 0 && $0.delay <= 0
        }) else { return nil }
        var longest: Float?
        for initializer in config.initializers {
            switch initializer {
            case let .lifetime(low, high, exponent):
                guard exponent > 0, (high - low).isFinite else { return nil }
                longest = max(longest ?? low, low, high)
            case .sequenceAround, .sequenceBetween:
                return nil
            case let .remap(field) where field.output == .maxLifetime:
                return nil
            default:
                break
            }
        }
        for entry in config.operators {
            switch entry.kind {
            case .boids:
                return nil
            case let .remap(field) where field.output == .maxLifetime:
                return nil
            default:
                break
            }
        }
        let horizon = max(max(longest ?? 1, 0.001) * instance.lifetime, 0.001)
        return horizon.isFinite ? horizon : nil
    }

    /// The normal update wrapper advances this system's elapsed time and then its children (1402308a0).
    mutating func step(dt: Float, parentControlPoints: [simd_float4x4]? = nil, parentCount: Int = 0,
                       parentUpdateMatrix: simd_float4x4 = matrix_identity_float4x4,
                       parentWorldSpace: Bool = false) {
        guard dt > 0 else { return }
        simulationTime += dt
        simulate(dt: dt, parentControlPoints: parentControlPoints, parentCount: parentCount,
                 parentUpdateMatrix: parentUpdateMatrix, parentWorldSpace: parentWorldSpace)
        for index in children.indices {
            children[index].copyBulkControlPoints(positions: position, lifetimes: lifetime, highWater: highWater,
                                                  parentUpdateMatrix: frameContext.objectMatrix,
                                                  parentWorldSpace: frameContext.worldSpace)
            children[index].setUpdateFrame(frameContext, parentUpdateMatrix: frameContext.objectMatrix, conditional: false)
            children[index].objectTime = objectTime
            children[index].paused = paused
            children[index].step(dt: dt, parentControlPoints: controlPoints, parentCount: controlPointCount,
                                 parentUpdateMatrix: frameContext.objectMatrix, parentWorldSpace: frameContext.worldSpace)
        }
        for (childIndex, child) in config.children.enumerated() where child.trigger != .always {
            let group = childGroup[childIndex]
            var index = 0
            while index < eventChildren[group].count {
                let slot = eventChildren[group][index].parentSlot
                let sample = parentSample(slot: slot)
                if child.trigger == .follow, sample != nil {
                    // 2308a0:2763–2767: follow relocation is after the parent's operators, before child update.
                    eventChildren[group][index].instanceTransform = eventTransform(child, position: position[slot])
                }
                eventChildren[group][index].copyBulkControlPoints(
                    positions: position, lifetimes: lifetime, highWater: highWater,
                    parentUpdateMatrix: frameContext.objectMatrix, parentWorldSpace: frameContext.worldSpace
                )
                eventChildren[group][index].parentSample = sample
                eventChildren[group][index].setUpdateFrame(frameContext, parentUpdateMatrix: frameContext.objectMatrix,
                                                           conditional: true)
                eventChildren[group][index].objectTime = objectTime
                eventChildren[group][index].paused = paused
                eventChildren[group][index].step(dt: dt, parentControlPoints: controlPoints, parentCount: controlPointCount,
                                                 parentUpdateMatrix: frameContext.objectMatrix,
                                                 parentWorldSpace: frameContext.worldSpace)
                if eventChildren[group][index].isFinished {
                    if child.trigger == .follow, slot != -1 {
                        releaseFollowReference(parentSlot: slot)
                    }
                    finishedEventChildren[group].append(eventChildren[group].remove(at: index))
                } else {
                    index += 1
                }
            }
        }
    }

    /// Construction prewarm calls only this inner simulation: it neither advances system elapsed nor recursively
    /// updates existing children (14022ebe0:363 → 140236cd0). Death children prewarm before the parent's emit.
    private mutating func simulate(dt: Float, parentControlPoints: [simd_float4x4]? = nil, parentCount: Int = 0,
                                   parentUpdateMatrix: simd_float4x4 = matrix_identity_float4x4,
                                   parentWorldSpace: Bool = false) {
        for slot in 0 ..< highWater where lifetime[slot] != 0 {
            age[slot] += dt
            if age[slot] > lifetime[slot] {
                kill(slot)
            }
        }
        processDeathEvents()
        updateControlPoints(parent: parentControlPoints, parentCount: parentCount,
                            parentUpdateMatrix: parentUpdateMatrix, parentWorldSpace: parentWorldSpace)
        if !paused {
            for index in config.emitters.indices {
                emit(index, dt: dt)
            }
        }
        processSpawnEvents()
        runOperators(dt: dt)
        commitControlPointHistory()
        boidsFrame &+= 1
        pushTrailHistory(dt: dt)
    }

    /// The native death CFG has one wrapping 32-bit remaining count shared by all death groups. It checks != 0
    /// only at the start of a dead parent, and reaching one group's exact max skips that parent's later groups.
    /// In particular, this deliberately is not a conventional per-group clamp (1402373c8–1402376ce).
    private mutating func processDeathEvents() {
        guard !pendingEvents.isEmpty else { return }
        var remaining: Int32 = 0
        for (index, child) in config.children.enumerated() where child.trigger == .death {
            remaining &+= Int32(truncatingIfNeeded: child.maxCount)
                &- Int32(truncatingIfNeeded: eventChildren[childGroup[index]].count)
        }
        var parentSlot = -1
        var skipParent = false
        for event in pendingEvents {
            if event.slot != parentSlot {
                parentSlot = event.slot
                skipParent = remaining == 0
            }
            guard let childIndex = event.child else {
                detachFollowInstances(parentSlot: event.slot)
                continue
            }
            guard !skipParent else { continue }
            let child = config.children[childIndex]
            if rng.unit() <= child.probability {
                // The old slot still holds its final values; each child's prewarm consumes RNG before emit.
                spawnEvent(event)
                remaining &-= 1
                skipParent = eventChildren[childGroup[childIndex]].count
                    == Int(UInt32(truncatingIfNeeded: child.maxCount))
            }
        }
        pendingEvents.removeAll(keepingCapacity: true)
    }

    /// Spawn/follow native order is group first, then this emitter pass's births, after all emitters and before
    /// parent operators (1402378a0:1800–1967). Successful follow instances register only after prewarm/append.
    private mutating func processSpawnEvents() {
        guard !pendingEvents.isEmpty else { return }
        for (index, child) in config.children.enumerated() where child.trigger == .spawn || child.trigger == .follow {
            let group = childGroup[index]
            let limit = Int(UInt32(truncatingIfNeeded: child.maxCount))
            guard eventChildren[group].count != limit else { continue }
            for event in pendingEvents where event.child == index {
                if rng.unit() <= child.probability {
                    spawnEvent(event)
                    if eventChildren[group].count == limit {
                        break
                    }
                }
            }
        }
        pendingEvents.removeAll(keepingCapacity: true)
    }

    private mutating func spawnEvent(_ event: PendingEvent) {
        guard let childIndex = event.child else { return }
        let child = config.children[childIndex]
        let group = childGroup[childIndex]
        let placement = eventTransform(child, position: event.position)
        let sample = parentSample(slot: event.slot)
        if let last = finishedEventChildren[group].indices.last {
            // The owner's pause bit reaches the instance before its reuse prewarm (1402378a0.c:1873-1874).
            finishedEventChildren[group][last].paused = paused
            finishedEventChildren[group][last].reuseForEvent(
                instanceTransform: placement, context: frameContext, parentSlot: event.slot,
                parentSample: sample, ownerTime: objectTime, parentControlPoints: controlPoints,
                parentCount: controlPointCount
            )
            eventChildren[group].append(finishedEventChildren[group].removeLast())
        } else {
            eventChildConstructions += 1
            eventChildren[group].append(WPEParityParticleSystem(
                config: child.config, instance: hasScriptInstanceChanges ? instance : instance.childConstruction,
                rng: rng, crt: crt, instanceTransform: placement, context: frameContext,
                parentSlot: event.slot, parentSample: sample, ownerTime: objectTime,
                scriptInstance: hasScriptInstanceChanges ? instance : nil, parentControlPoints: controlPoints,
                parentControlPointCount: controlPointCount, parentUpdateMatrix: frameContext.objectMatrix,
                parentWorldSpace: frameContext.worldSpace,
                bulkControlPointStart: child.flags & 1 == 0 ? nil : child.controlPointStartIndex,
                rootColornValid: colornRootValid, paused: paused
            ))
        }
        if child.trigger == .follow {
            followReferences[event.slot] = (followReferences[event.slot] ?? 0) &+ 1
        }
    }

    private mutating func releaseFollowReference(parentSlot: Int) {
        guard let count = followReferences[parentSlot] else { return }
        let remaining = count &- 1
        if remaining == 0 {
            followReferences.removeValue(forKey: parentSlot)
        } else {
            followReferences[parentSlot] = remaining
        }
    }

    private mutating func detachFollowInstances(parentSlot: Int) {
        // Native gates the entire detach scan on finding the map entry, and decrements once per dead slot,
        // not once per matching instance. Detached finishes never release again (2308a0:2774–2780).
        guard followReferences[parentSlot] != nil else { return }
        releaseFollowReference(parentSlot: parentSlot)
        for (childIndex, child) in config.children.enumerated() where child.trigger == .follow {
            let group = childGroup[childIndex]
            for index in eventChildren[group].indices where eventChildren[group][index].parentSlot == parentSlot {
                eventChildren[group][index].parentSlot = -1
                eventChildren[group][index].parentSample = nil
                eventChildren[group][index].stopEmissionThroughStaticChildren()
            }
        }
    }

    /// 22f640 stops only emission through the static tree. Live SoA, CP/history and the last placement survive.
    private mutating func stopEmissionThroughStaticChildren() {
        for index in emitterStates.indices {
            emitterStates[index].disabled = true
        }
        for index in children.indices {
            children[index].stopEmissionThroughStaticChildren()
        }
    }

    /// 22f5b0 clears only the disabled bits through the static tree.
    private mutating func enableEmissionThroughStaticChildren() {
        for index in emitterStates.indices {
            emitterStates[index].disabled = false
        }
        for index in children.indices {
            children[index].enableEmissionThroughStaticChildren()
        }
    }

    /// No live particles, nothing left to emit, no live descendants.
    var isFinished: Bool {
        guard liveCount == 0 else { return false }
        for (emitter, state) in zip(config.emitters, emitterStates) {
            // 2378a0:1771–1788 uses compiled rate/burst, after delay and duration complete.
            // A hot count=0 does not kill live slots, but it must allow the finished subtree into the pool.
            let pendingBurst = state.burstPending && emitter.instantaneous > 0
            let idle = state.delayLeft <= 0 && state.durationLeft <= 0
                && emitter.rate * instance.count <= 0 && !pendingBurst && !emitter.periodic
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
        // Finish the death list before processing children; their probability draws and prewarm belong before emit.
        if followReferences[slot] != nil {
            pendingEvents.append(PendingEvent(child: nil, position: position[slot], slot: slot))
        }
        for (index, child) in config.children.enumerated() where child.trigger == .death {
            pendingEvents.append(PendingEvent(child: index, position: position[slot], slot: slot))
        }
    }

    /// Lowest free slot; emitter shape/direction/speed precede birthU and initializers in JSON order
    /// (140238185/238bda → 23b340:281–283 → 1f87a0).
    mutating func spawn(_ emitter: WPEParityParticleEmitterConfig) {
        var slot = freeHint
        while lifetime[slot] != 0 {
            slot += 1
        }
        freeHint = slot + 1
        highWater = max(highWater, slot + 1)
        liveCount += 1
        let point = controlPoints[emitter.controlPoint]
        let center = SIMD3(point.columns.3.x, point.columns.3.y, point.columns.3.z) + emitter.origin
        let basis = frameContext.worldSpace || emitter.controlPoint != 0 ? controlPointBasis(emitter.controlPoint) : nil
        let launch = emitter.sample(rng: rng, at: center, basis: basis)
        position[slot] = launch.position
        velocity[slot] = launch.velocity
        let u = rng.unit()
        rotation[slot] = .zero
        angularVelocity[slot] = .zero
        age[slot] = 0
        lifetime[slot] = 1
        initialSize[slot] = 0.5
        let brightness = config.flags & 8 == 0 ? instance.brightness : 1
        // Seed: brightness, times colorn only while it is valid and the definition flag 0x200000 is set (1d15a0.c:68-72).
        let seed = colornActive && config.multipliesColorn ? instance.color : SIMD3<Float>(repeating: 1)
        initialColor[slot] = seed * brightness
        initialAlpha[slot] = instance.alpha
        birthU[slot] = u
        frame[slot] = config.randomFrame ? u : 0
        for (index, initializer) in config.initializers.enumerated() {
            initialize(slot, initializer, index: index, birthBasis: basis ?? matrix_identity_float3x3)
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
        guard birthsRecordSpawnEvents else { return }
        for (index, child) in config.children.enumerated() where child.trigger == .spawn || child.trigger == .follow {
            pendingEvents.append(PendingEvent(child: index, position: position[slot], slot: slot))
        }
    }

    /// D/14023b340.c:360-1032.
    private mutating func initialize(_ slot: Int, _ initializer: WPEParityParticleInitializer, index: Int,
                                     birthBasis: simd_float3x3) {
        switch initializer {
        case let .lifetime(low, high, exponent):
            lifetime[slot] = max(low + pow(rng.unit(), exponent) * (high - low), 0.001)
        case let .size(low, high, exponent):
            initialSize[slot] *= low + pow(rng.unit(), exponent) * (high - low)
        case let .color(low, high, exponent):
            let r = shaped(rng.unit(), exponent)
            let range = colorRanges[index] ?? (low, high)
            initialColor[slot] = initialColor[slot] * (range.low + r * (range.high - range.low)) / 255
        case let .hsvColor(hsv):
            initializeHSV(hsv, slot: slot)
        case let .colorList(colors, noise):
            initializeColorList(colors, noise: noise, slot: slot)
        case let .turbulentVelocity(field):
            initializeTurbulentVelocity(field, slot: slot, birthBasis: birthBasis)
        case let .positionOffset(field):
            initializePositionOffset(field, slot: slot)
        case let .sequenceAround(field):
            initializeSequenceAround(field, index: index, slot: slot)
        case let .sequenceBetween(field):
            initializeSequenceBetween(field, index: index, slot: slot)
        case let .alpha(low, high, exponent):
            // (U^exp·Δ + min)·alpha, powf only for exp ≠ 1 (D/14023b340.c:524-539).
            initialAlpha[slot] *= shaped(rng.unit(), exponent) * (high - low) + low
        case let .remap(field):
            applyRemap(field, slot: slot, initializer: true)
        case let .inheritInitial(field):
            if let parentSample {
                applyInitialInherit(field, slot: slot, parent: parentSample)
            }
        case let .inheritControlPointVelocity(point, low, high):
            initializeControlPointVelocity(point, minimum: low, maximum: high, slot: slot, birthBasis: birthBasis)
        case let .velocity(low, high, exponent):
            // 23bac6..23bc2d: three independent words in ZYX order, exponent before the emitter birth basis.
            let z = low.z + shaped(rng.unit(), exponent) * (high.z - low.z)
            let y = low.y + shaped(rng.unit(), exponent) * (high.y - low.y)
            let x = low.x + shaped(rng.unit(), exponent) * (high.x - low.x)
            velocity[slot] += Self.transformVelocity(SIMD3(x, y, z), by: birthBasis)
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
        for (index, entry) in config.operators.enumerated() {
            if case let .boids(field) = entry.kind {
                applyBoids(field, blend: entry.blend, dt: dt)
                continue
            }
            let kind = colorChanges[index] ?? entry.kind
            for slot in 0 ..< highWater where lifetime[slot] != 0 {
                let t = age[slot] / lifetime[slot]
                apply(kind, slot: slot, t: t, weight: entry.blend?.weight(t: t) ?? 1, dt: dt)
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
            // The instance size also scales sizechange start/end (1401c5490.c:9694-9719, 1d15a0.c:168-193).
            size[slot] *= blended(instance.size * Math.ramp(
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
        case .collisionBox:
            break
        case let .remap(field):
            // The blended variant (type 0x29) is not read; the weight is not applied.
            applyRemap(field, slot: slot, initializer: false)
        case let .inherit(field):
            if let parentSample, parentSample.alive {
                applyInherit(field, slot: slot, parent: parentSample)
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
