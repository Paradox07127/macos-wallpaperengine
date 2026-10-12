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
    case color(min: SIMD3<Float>, max: SIMD3<Float>)
    case hsvColor(hue: SIMD2<Float>, saturation: SIMD2<Float>, value: SIMD2<Float>)
    case colorList([SIMD3<Float>])
    case alpha(min: Float, max: Float)
    case velocity(min: SIMD3<Float>, max: SIMD3<Float>)
    case rotation(min: SIMD3<Float>, max: SIMD3<Float>)
    case angularVelocity(min: SIMD3<Float>, max: SIMD3<Float>)
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
    }

    var kind: Kind
    var blend: WPEParityParticleBlend?
}

struct WPEParityParticleChildConfig: Equatable, Sendable {
    enum Trigger: Equatable, Sendable { case always, spawn, death }

    var trigger: Trigger
    var origin: SIMD3<Float>
    var probability: Float
    var config: WPEParityParticleConfig
}

struct WPEParityParticleConfig: Equatable, Sendable {
    var maxCount: Int
    var startTime: Float
    var flags: Int
    var randomFrame: Bool
    var emitters: [WPEParityParticleEmitterConfig] = []
    var initializers: [WPEParityParticleInitializer] = []
    var operators: [WPEParityParticleOperator] = []
    var renderers: [WPEParityParticleRenderer] = []
    var children: [WPEParityParticleChildConfig] = []
    var diagnostics: [String] = []

    /// `is3D` picks R18's 3D defaults (velocityrandom ±1, distancemax 1, oscillateposition scale 0.5).
    init(json: WPESceneJSONValue, is3D: Bool, resolveChild: (String) -> WPESceneJSONValue?) {
        typealias JSON = WPEParityParticleJSON
        maxCount = max(0, Int(JSON.number(json["maxcount"]) ?? 0))
        startTime = JSON.number(json["starttime"]) ?? 0
        flags = Int(JSON.number(json["flags"]) ?? 0)
        randomFrame = JSON.string(json["animationmode"])?.lowercased() == "randomframe"
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
            appendChild(entry, is3D: is3D, resolveChild: resolveChild)
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

    private mutating func appendInitializer(_ entry: WPESceneJSONValue, is3D: Bool) {
        typealias JSON = WPEParityParticleJSON
        let name = JSON.string(entry["name"])?.lowercased() ?? ""
        let minimum = entry["min"], maximum = entry["max"]
        let exponent = JSON.number(entry["exponent"]) ?? 1
        let initializer: WPEParityParticleInitializer
        switch name {
        case "lifetimerandom":
            initializer = .lifetime(min: JSON.number(minimum) ?? 1, max: JSON.number(maximum) ?? 1, exponent: exponent)
        case "sizerandom":
            initializer = .size(min: JSON.number(minimum) ?? 4, max: JSON.number(maximum) ?? 4, exponent: exponent)
        case "colorrandom":
            initializer = .color(min: JSON.vector(minimum) ?? .zero, max: JSON.vector(maximum) ?? SIMD3(repeating: 255))
        case "hsvcolorrandom":
            initializer = .hsvColor(
                hue: SIMD2(JSON.number(entry["huemin"]) ?? 0, JSON.number(entry["huemax"]) ?? 360),
                saturation: SIMD2(JSON.number(entry["saturationmin"]) ?? 1, JSON.number(entry["saturationmax"]) ?? 1),
                value: SIMD2(JSON.number(entry["valuemin"]) ?? 1, JSON.number(entry["valuemax"]) ?? 1)
            )
        case "colorlist":
            let colors = JSON.array(entry["colors"]).compactMap { JSON.vector($0) }
            guard !colors.isEmpty else { return }
            initializer = .colorList(colors)
        case "alpharandom":
            initializer = .alpha(min: JSON.number(minimum) ?? 0.05, max: JSON.number(maximum) ?? 1)
        case "velocityrandom":
            let limit: SIMD3<Float> = is3D ? SIMD3(1, 1, 1) : SIMD3(32, 32, 0)
            initializer = .velocity(min: JSON.vector(minimum) ?? -limit, max: JSON.vector(maximum) ?? limit)
        case "rotationrandom":
            initializer = .rotation(min: JSON.vector(minimum) ?? .zero, max: JSON.vector(maximum) ?? SIMD3(0, 0, 2 * .pi))
        case "angularvelocityrandom":
            initializer = .angularVelocity(
                min: JSON.vector(minimum) ?? SIMD3(0, 0, -5), max: JSON.vector(maximum) ?? SIMD3(0, 0, 5)
            )
        default:
            diagnostics.append("initializer \(name) skipped")
            return
        }
        initializers.append(initializer)
    }

    private mutating func appendOperator(_ entry: WPESceneJSONValue, is3D: Bool) {
        typealias JSON = WPEParityParticleJSON
        let name = JSON.string(entry["name"])?.lowercased() ?? ""
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
            kind = .capVelocity(maxSpeed: number("maxspeed", .infinity))
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
        _ entry: WPESceneJSONValue, is3D: Bool, resolveChild: (String) -> WPESceneJSONValue?
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
        guard let json = resolveChild(path) else {
            diagnostics.append("child \(path) unresolved")
            return
        }
        children.append(WPEParityParticleChildConfig(
            trigger: trigger,
            origin: JSON.vector(entry["origin"]) ?? .zero,
            probability: JSON.number(entry["probability"]) ?? 1,
            config: WPEParityParticleConfig(json: json, is3D: is3D, resolveChild: resolveChild)
        ))
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
