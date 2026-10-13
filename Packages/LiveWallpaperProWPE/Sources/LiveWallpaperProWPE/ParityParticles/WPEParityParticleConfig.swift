import Foundation

/// Emitter keys with R18's defaults (D/1401b8df0.c:16-104, D/1401b9100.c:62-155, D/1401b9520.c:98-157).
struct WPEParityParticleEmitterConfig: Equatable, Sendable {
    enum Shape: Equatable, Sendable { case sphere, box }

    var shape: Shape
    var origin: SIMD3<Float>
    var directions: SIMD3<Float>
    var sign: SIMD3<Float>
    /// Sphere reads `.x` only.
    var distanceMin: SIMD3<Float>
    var distanceMax: SIMD3<Float>
    var cone: Float
    var speedMin: Float
    var speedMax: Float
    var rate: Float
    var instantaneous: Int
    var duration: Float
    var delay: Float
    /// Emitter flags bit 2 [I]: every authored periodic emitter carries `flags: 4`.
    var periodic: Bool
    var periodicDurationMin: Float
    var periodicDurationMax: Float
    var periodicDelayMin: Float
    var periodicDelayMax: Float
    var maxPerPeriod: Int
}

enum WPEParityParticleInitializer: Equatable, Sendable {
    case lifetime(min: Float, max: Float, exponent: Float)
    case size(min: Float, max: Float, exponent: Float)
    case color(min: SIMD3<Float>, max: SIMD3<Float>, exponent: Float)
    case hsvColor(WPEParityParticleHSVRandom)
    /// Colors as HSV (hue in turns); noise per HSV channel.
    case colorList(hsv: [SIMD3<Float>], noise: SIMD3<Float>)
    case alpha(min: Float, max: Float, exponent: Float)
    case velocity(min: SIMD3<Float>, max: SIMD3<Float>)
    case rotation(min: SIMD3<Float>, max: SIMD3<Float>, exponent: Float)
    case angularVelocity(min: SIMD3<Float>, max: SIMD3<Float>, exponent: Float)
    case turbulentVelocity(WPEParityParticleTurbulentVelocity)
    case positionOffset(WPEParityParticlePositionOffset)
    case sequenceAround(WPEParityParticleSequenceAround)
    case sequenceBetween(WPEParityParticleSequenceBetween)
    case remap(WPEParityParticleRemap)
    case inheritInitial(WPEParityParticleInherit)
}

struct WPEParityParticleOperator: Equatable, Sendable {
    struct Ramp: Equatable, Sendable {
        var startTime: Float
        var endTime: Float
        var start: Float
        var end: Float
    }

    enum Kind: Equatable, Sendable {
        case movement(gravity: SIMD3<Float>, drag: Float)
        case angularMovement(force: SIMD3<Float>, drag: Float)
        case alphaFade(fadeIn: Float, fadeOut: Float)
        case sizeChange(Ramp)
        case colorChange(startTime: Float, endTime: Float, start: SIMD3<Float>, end: SIMD3<Float>)
        case alphaChange(Ramp)
        case oscillatePosition(WPEParityParticleOscillation, mask: SIMD3<Float>)
        case oscillateAlpha(WPEParityParticleOscillation)
        case oscillateSize(WPEParityParticleOscillation)
        case capVelocity(maxSpeed: Float)
        case turbulence(WPEParityParticleTurbulence)
        case controlPointAttract(WPEParityParticleAttract)
        case vortex(WPEParityParticleVortex)
        case vortexRing(WPEParityParticleVortexRing)
        case boids(WPEParityParticleBoids)
        case maintainDistance(controlPoint: Int, distance: Float, variableStrength: Float)
        case maintainDistanceBetween(start: Int, end: Int)
        case reduceMovement(controlPoint: Int, inner: Float, outer: Float, reductionInner: Float, reductionDelta: Float)
        case collisionPlane(WPEParityParticleCollision)
        case collisionSphere(WPEParityParticleCollision)
        case remap(WPEParityParticleRemap)
        case inherit(WPEParityParticleInherit)
    }

    var kind: Kind
    var blend: WPEParityParticleBlend?
}

struct WPEParityParticleChildConfig: Equatable, Sendable {
    enum Trigger: Equatable, Sendable { case always, spawn, death }

    var trigger: Trigger
    var origin: SIMD3<Float>
    var probability: Float
    /// Parsed with WPE's default (D/1401c1430.c:125); R19 has no runtime reader for it yet.
    var maxCount: Int
    var config: WPEParityParticleConfig
}

struct WPEParityParticleConfig: Equatable, Sendable {
    var maxCount: Int
    var startTime: Float
    var flags: Int
    /// JSON hascolor opts out of the direct instance colorn multiplier (R22 Q9).
    var hasColor: Bool
    var randomFrame: Bool
    /// Scales the sprite-sheet phase age/lifetime (R22 Q10).
    var sequenceMultiplier: Float
    var emitters: [WPEParityParticleEmitterConfig] = []
    var initializers: [WPEParityParticleInitializer] = []
    var operators: [WPEParityParticleOperator] = []
    var renderers: [WPEParityParticleRenderer] = []
    var children: [WPEParityParticleChildConfig] = []
    /// Always `WPEParityParticleControlPoint.count` entries; unauthored ones sit at offset 0.
    var controlPoints = Array(repeating: WPEParityParticleControlPoint(), count: WPEParityParticleControlPoint.count)
    /// Texture facts of this system's own `material`.
    var material = WPEParityParticleMaterial()
    var diagnostics: [String] = []

    /// `is3D` picks the 3D defaults of R18/R19 (velocityrandom ±1, distancemax 1, oscillateposition scale 0.5, …).
    init(json: WPESceneJSONValue, is3D: Bool, resolveChild: (String) -> WPESceneJSONValue?) {
        self.init(json: json, ancestors: [""], eventChild: false, is3D: is3D, resolveChild: resolveChild,
                  resolveMaterial: { _ in nil })
    }

    /// `ancestors` are the paths from the root system down to this one; children are numbered the way
    /// `WPEParityProgramScene.particleDraws` keys them, and an event child keeps none of its own.
    init(json: WPESceneJSONValue, ancestors: [String], eventChild: Bool, is3D: Bool,
         resolveChild: (String) -> WPESceneJSONValue?, resolveMaterial: (String) -> WPEParityParticleMaterial?) {
        typealias JSON = WPEParityParticleJSON
        material = JSON.string(json["material"]).flatMap(resolveMaterial) ?? material
        maxCount = max(0, Int(JSON.number(json["maxcount"]) ?? 0))
        startTime = JSON.number(json["starttime"]) ?? 0
        flags = Int(JSON.number(json["flags"]) ?? 0)
        hasColor = JSON.flag(json["hascolor"])
        randomFrame = JSON.string(json["animationmode"])?.lowercased() == "randomframe"
        sequenceMultiplier = JSON.number(json["sequencemultiplier"]) ?? 1
        for (index, value) in JSON.array(json["controlpoint"]).enumerated() {
            let entry = WPEParityParticleEntry(value)
            let id = entry.integer("id", index)
            guard controlPoints.indices.contains(id) else {
                diagnostics.append("controlpoint \(id) skipped")
                continue
            }
            controlPoints[id] = WPEParityParticleControlPoint(
                offset: entry.vector("offset", .zero), flags: entry.integer("flags", 0),
                parent: entry.controlPoint("parentcontrolpoint")
            )
        }
        for entry in JSON.array(json["emitter"]) {
            appendEmitter(entry, is3D: is3D)
        }
        for entry in JSON.array(json["initializer"]) {
            appendInitializer(entry, is3D: is3D)
        }
        for entry in JSON.array(json["operator"]) {
            appendOperator(entry, is3D: is3D)
        }
        for entry in JSON.array(json["renderer"]) {
            let name = JSON.string(entry["name"])?.lowercased() ?? ""
            if let renderer = WPEParityParticleRenderer(name: name, json: entry) {
                renderers.append(renderer)
            } else {
                diagnostics.append("renderer \(name) skipped")
            }
        }
        for entry in JSON.array(json["children"]) {
            appendChild(entry, ancestors: ancestors, eventChild: eventChild, is3D: is3D, resolveChild: resolveChild,
                        resolveMaterial: resolveMaterial)
        }
    }

    private mutating func appendEmitter(_ entry: WPESceneJSONValue, is3D: Bool) {
        typealias JSON = WPEParityParticleJSON
        let name = JSON.string(entry["name"])?.lowercased() ?? ""
        let shape: WPEParityParticleEmitterConfig.Shape
        let defaultDirections: SIMD3<Float>
        let defaultDistanceMax: SIMD3<Float>
        switch name {
        case "sphererandom":
            shape = .sphere
            defaultDirections = SIMD3(1, 1, 0)
            defaultDistanceMax = SIMD3(repeating: is3D ? 1 : 256)
        case "boxrandom":
            shape = .box
            defaultDirections = is3D ? SIMD3(1, 1, 1) : SIMD3(1, 1, 0)
            defaultDistanceMax = is3D ? SIMD3(1, 1, 1) : SIMD3(256, 256, 0)
        default:
            diagnostics.append("emitter \(name) skipped")
            return
        }
        let flags = Int(JSON.number(entry["flags"]) ?? 0)
        emitters.append(WPEParityParticleEmitterConfig(
            shape: shape,
            origin: JSON.vector(entry["origin"]) ?? .zero,
            directions: JSON.vector(entry["directions"]) ?? defaultDirections,
            sign: JSON.vector(entry["sign"]) ?? .zero,
            distanceMin: JSON.vector(entry["distancemin"]) ?? .zero,
            distanceMax: JSON.vector(entry["distancemax"]) ?? defaultDistanceMax,
            cone: JSON.number(entry["cone"]) ?? 0,
            speedMin: JSON.number(entry["speedmin"]) ?? 0,
            speedMax: JSON.number(entry["speedmax"]) ?? 0,
            rate: JSON.number(entry["rate"]) ?? 10,
            instantaneous: max(0, Int(JSON.number(entry["instantaneous"]) ?? 0)),
            duration: JSON.number(entry["duration"]) ?? 0,
            delay: JSON.number(entry["delay"]) ?? 0,
            periodic: flags & 4 != 0,
            periodicDurationMin: JSON.number(entry["minperiodicduration"]) ?? 2,
            periodicDurationMax: JSON.number(entry["maxperiodicduration"]) ?? 3,
            periodicDelayMin: JSON.number(entry["minperiodicdelay"]) ?? 1,
            periodicDelayMax: JSON.number(entry["maxperiodicdelay"]) ?? 2,
            maxPerPeriod: max(0, Int(JSON.number(entry["maxtoemitperperiod"]) ?? 0))
        ))
    }

    /// Defaults per R19 其余 and 初始化器.
    private mutating func appendInitializer(_ entry: WPESceneJSONValue, is3D: Bool) {
        typealias JSON = WPEParityParticleJSON
        let name = JSON.string(entry["name"])?.lowercased() ?? ""
        let minimum = entry["min"], maximum = entry["max"]
        let exponent = JSON.number(entry["exponent"]) ?? 1
        let fields = WPEParityParticleEntry(entry)
        let initializer: WPEParityParticleInitializer
        switch name {
        case "lifetimerandom":
            initializer = .lifetime(min: JSON.number(minimum) ?? 0, max: JSON.number(maximum) ?? 1, exponent: exponent)
        case "sizerandom":
            initializer = .size(
                min: JSON.number(minimum) ?? (is3D ? 0.001 : 5), max: JSON.number(maximum) ?? (is3D ? 1 : 50),
                exponent: exponent
            )
        case "colorrandom":
            initializer = .color(
                min: JSON.vector(minimum) ?? .zero, max: JSON.vector(maximum) ?? SIMD3(repeating: 255), exponent: exponent
            )
        case "hsvcolorrandom":
            initializer = .hsvColor(WPEParityParticleHSVRandom(fields))
        case "colorlist":
            let colors = JSON.array(entry["colors"]).compactMap { JSON.vector($0) }
            let authored = entry["colors"] == nil ? [SIMD3<Float>(repeating: 1)] : colors
            initializer = .colorList(
                hsv: authored.isEmpty ? [SIMD3(0, 1, 1)] : authored.map(WPEParityParticleMath.rgbToHSV),
                noise: SIMD3(
                    fields.number("huenoise", 0), fields.number("saturationnoise", 0), fields.number("valuenoise", 0)
                )
            )
        case "alpharandom":
            initializer = .alpha(min: JSON.number(minimum) ?? 0.05, max: JSON.number(maximum) ?? 1, exponent: exponent)
        case "velocityrandom":
            let limit: SIMD3<Float> = is3D ? SIMD3(1, 1, 1) : SIMD3(32, 32, 0)
            initializer = .velocity(min: JSON.vector(minimum) ?? -limit, max: JSON.vector(maximum) ?? limit)
        case "rotationrandom":
            initializer = .rotation(
                min: JSON.vector(minimum) ?? .zero, max: JSON.vector(maximum) ?? SIMD3(0, 0, 6.283_185_307_17),
                exponent: exponent
            )
        case "angularvelocityrandom":
            initializer = .angularVelocity(
                min: JSON.vector(minimum) ?? SIMD3(0, 0, -5), max: JSON.vector(maximum) ?? SIMD3(0, 0, 5),
                exponent: exponent
            )
        case "turbulentvelocityrandom":
            initializer = .turbulentVelocity(WPEParityParticleTurbulentVelocity(fields, is3D: is3D))
        case "positionoffsetrandom":
            initializer = .positionOffset(WPEParityParticlePositionOffset(fields, is3D: is3D))
        case "mapsequencearoundcontrolpoint":
            initializer = .sequenceAround(WPEParityParticleSequenceAround(fields))
        case "mapsequencebetweencontrolpoints":
            initializer = .sequenceBetween(WPEParityParticleSequenceBetween(fields))
        case "remapinitialvalue":
            initializer = .remap(WPEParityParticleRemap(fields, defaultInput: .maxLifetime))
        case "inheritinitialvaluefromevent":
            initializer = .inheritInitial(WPEParityParticleInherit(fields, fallback: .setColor))
        default:
            diagnostics.append("initializer \(name) skipped")
            return
        }
        initializers.append(initializer)
    }

    private mutating func appendOperator(_ entry: WPESceneJSONValue, is3D: Bool) {
        typealias JSON = WPEParityParticleJSON
        let name = JSON.string(entry["name"])?.lowercased() ?? ""
        let fields = WPEParityParticleEntry(entry)
        func number(_ key: String, _ fallback: Float) -> Float {
            JSON.number(entry[key]) ?? fallback
        }
        func wave(scale: SIMD2<Float>, frequency: SIMD2<Float>) -> WPEParityParticleOscillation {
            WPEParityParticleOscillation(
                frequencyMin: number("frequencymin", frequency.x), frequencyMax: number("frequencymax", frequency.y),
                scaleMin: number("scalemin", scale.x), scaleMax: number("scalemax", scale.y),
                phaseMin: number("phasemin", 0), phaseMax: number("phasemax", 2 * .pi)
            )
        }
        let ramp = WPEParityParticleOperator.Ramp(
            startTime: number("starttime", 0), endTime: number("endtime", 1),
            start: number("startvalue", 1), end: number("endvalue", 0)
        )
        let kind: WPEParityParticleOperator.Kind
        switch name {
        case "movement":
            kind = .movement(gravity: JSON.vector(entry["gravity"]) ?? .zero, drag: number("drag", 0))
        case "angularmovement":
            kind = .angularMovement(force: JSON.vector(entry["force"]) ?? .zero, drag: number("drag", 0))
        case "alphafade":
            kind = .alphaFade(fadeIn: number("fadeintime", 0.5), fadeOut: number("fadeouttime", 0.5))
        case "sizechange":
            kind = .sizeChange(ramp)
        case "colorchange":
            kind = .colorChange(
                startTime: ramp.startTime, endTime: ramp.endTime,
                start: JSON.vector(entry["startvalue"]) ?? SIMD3(repeating: 1),
                end: JSON.vector(entry["endvalue"]) ?? .zero
            )
        case "alphachange":
            kind = .alphaChange(ramp)
        case "oscillateposition":
            kind = .oscillatePosition(
                wave(scale: SIMD2(0, is3D ? 0.5 : 10), frequency: SIMD2(1, 5)),
                mask: JSON.vector(entry["mask"]) ?? SIMD3(1, 1, 0)
            )
        case "oscillatealpha":
            kind = .oscillateAlpha(wave(scale: SIMD2(0, 1), frequency: SIMD2(1, 10)))
        case "oscillatesize":
            kind = .oscillateSize(wave(scale: SIMD2(0.8, 1.2), frequency: SIMD2(1, 10)))
        case "capvelocity":
            kind = .capVelocity(maxSpeed: number("maxspeed", is3D ? 1 : 100))
        case "turbulence":
            kind = .turbulence(WPEParityParticleTurbulence(fields, is3D: is3D))
        case "controlpointattract":
            kind = .controlPointAttract(WPEParityParticleAttract(fields, is3D: is3D))
        case "vortex":
            kind = .vortex(WPEParityParticleVortex(fields, is3D: is3D))
        case "vortex_v2":
            kind = .vortexRing(WPEParityParticleVortexRing(fields, is3D: is3D))
        case "boids":
            kind = .boids(WPEParityParticleBoids(fields, is3D: is3D))
        case "maintaindistancetocontrolpoint":
            kind = .maintainDistance(
                controlPoint: fields.controlPoint("controlpoint"), distance: number("distance", is3D ? 1 : 200),
                variableStrength: number("variablestrength", 0)
            )
        case "maintaindistancebetweencontrolpoints":
            kind = .maintainDistanceBetween(
                start: fields.controlPoint("controlpointstart"), end: fields.controlPoint("controlpointend", 1)
            )
        case "reducemovementnearcontrolpoint":
            let reductionInner = number("reductioninner", 100), reductionOuter = number("reductionouter", 0)
            // Equal reductions store a delta of 1, not 0 (B:8842-8847).
            kind = .reduceMovement(
                controlPoint: fields.controlPoint("controlpoint"),
                inner: number("distanceinner", is3D ? 0.5 : 100), outer: number("distanceouter", is3D ? 1 : 350),
                reductionInner: reductionInner,
                reductionDelta: reductionInner == reductionOuter ? 1 : reductionOuter - reductionInner
            )
        case "collisionplane", "collisionsphere":
            let behavior = JSON.string(entry["collisionbehavior"])?.lowercased() ?? "bounce"
            guard behavior == "bounce" else {
                diagnostics.append("operator \(name) (\(behavior)) skipped")
                return
            }
            let collision = WPEParityParticleCollision(fields, sphere: name == "collisionsphere", is3D: is3D)
            kind = name == "collisionsphere" ? .collisionSphere(collision) : .collisionPlane(collision)
        case "remapvalue":
            kind = .remap(WPEParityParticleRemap(fields, defaultInput: .lifetimeFraction))
        case "inheritvaluefromevent":
            kind = .inherit(WPEParityParticleInherit(fields, fallback: .setColorOpacity))
        default:
            diagnostics.append("operator \(name) skipped")
            return
        }
        var blend: WPEParityParticleBlend?
        let fallback = WPEParityParticleBlend()
        if entry["blendinstart"] != nil || entry["blendinend"] != nil {
            blend = fallback
            blend?.inStart = number("blendinstart", 0)
            blend?.inEnd = number("blendinend", 0)
        }
        if entry["blendoutstart"] != nil || entry["blendoutend"] != nil {
            blend = blend ?? fallback
            blend?.outStart = number("blendoutstart", 1)
            blend?.outEnd = number("blendoutend", 1)
        }
        operators.append(WPEParityParticleOperator(kind: kind, blend: blend))
    }

    private mutating func appendChild(
        _ entry: WPESceneJSONValue, ancestors: [String], eventChild: Bool, is3D: Bool,
        resolveChild: (String) -> WPESceneJSONValue?, resolveMaterial: (String) -> WPEParityParticleMaterial?
    ) {
        typealias JSON = WPEParityParticleJSON
        let path = JSON.string(entry["name"]) ?? JSON.string(entry["particle"]) ?? ""
        let kind = WPEParticleChildEventKind(
            authoredType: JSON.string(entry["type"]),
            flags: JSON.number(entry["flags"]).map { Int($0) }
        )
        let trigger: WPEParityParticleChildConfig.Trigger
        switch kind {
        case .staticSystem: trigger = .always
        case .spawn: trigger = .spawn
        case .death: trigger = .death
        case .follow, .unsupported:
            diagnostics.append("child \(path) (\(JSON.string(entry["type"]) ?? "eventfollow")) skipped")
            return
        }
        guard !eventChild, !ancestors.contains(path),
              ancestors.count < WPEParityProgramScene.particleChildDepthLimit else {
            diagnostics.append("child \(path) omitted")
            return
        }
        guard let json = resolveChild(path) else {
            diagnostics.append("child \(path) unresolved")
            return
        }
        children.append(WPEParityParticleChildConfig(
            trigger: trigger,
            origin: JSON.vector(entry["origin"]) ?? .zero,
            probability: JSON.number(entry["probability"]) ?? 1,
            maxCount: WPEParityParticleEntry(entry).integer("maxcount", 10),
            config: WPEParityParticleConfig(json: json, ancestors: ancestors + [path], eventChild: trigger != .always,
                                            is3D: is3D, resolveChild: resolveChild, resolveMaterial: resolveMaterial)
        ))
    }
}

/// One component object read with per-key fallbacks.
struct WPEParityParticleEntry {
    let json: WPESceneJSONValue

    init(_ json: WPESceneJSONValue) {
        self.json = json
    }

    func number(_ key: String, _ fallback: Float) -> Float {
        WPEParityParticleJSON.number(json[key]) ?? fallback
    }

    func vector(_ key: String, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        WPEParityParticleJSON.vector(json[key]) ?? fallback
    }

    /// Clamped so that authored 1e300 or NaN cannot trap the Int conversion.
    func integer(_ key: String, _ fallback: Int) -> Int {
        guard let value = WPEParityParticleJSON.number(json[key]), !value.isNaN else { return fallback }
        return Int(min(max(value, -1e9), 1e9))
    }

    /// Control point indices clamp to 0…7.
    func controlPoint(_ key: String, _ fallback: Int = 0) -> Int {
        min(max(integer(key, fallback), 0), WPEParityParticleControlPoint.count - 1)
    }
}

/// Particle JSON scalars and vectors: numbers, "x y z" strings, `{ "value": … }` user bindings.
enum WPEParityParticleJSON {
    static func array(_ value: WPESceneJSONValue?) -> [WPESceneJSONValue] {
        WPEParityProgramScene.array(value)
    }

    static func string(_ value: WPESceneJSONValue?) -> String? {
        WPEParityProgramScene.string(value)
    }

    static func number(_ value: WPESceneJSONValue?) -> Float? {
        value.flatMap(WPEParityProgramConstants.components)?.first.map { Float($0) }
    }

    static func flag(_ value: WPESceneJSONValue?) -> Bool {
        (number(value) ?? 0) != 0
    }

    /// A single number fills all three axes.
    static func vector(_ value: WPESceneJSONValue?) -> SIMD3<Float>? {
        guard let components = value.flatMap(WPEParityProgramConstants.components), let first = components.first else {
            return nil
        }
        guard components.count > 1 else {
            return SIMD3(repeating: Float(first))
        }
        return SIMD3(Float(first), Float(components[1]), components.count > 2 ? Float(components[2]) : 0)
    }
}
