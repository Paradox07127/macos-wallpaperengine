import Foundation

/// Emitter keys with their native defaults (1401b8df0.c:16-104, 1401b9100.c:62-155, 1401b9520.c:98-157).
struct WPEParityParticleEmitterConfig: Equatable, Sendable {
    enum Shape: Equatable, Sendable { case sphere, box }

    var shape: Shape
    var origin: SIMD3<Float>
    /// Compiled sphere +0xf0 / box +0xa8: unsigned min(authored index, 7), default 0.
    var controlPoint: Int
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
    /// Emitter flags bit 2: every authored periodic emitter carries `flags: 4`.
    var periodic: Bool
    /// Native emitter flags bit 1 caps the rate portion to one particle per update, after accumulator subtraction.
    var maxOnePerFrame: Bool
    var periodicDurationMin: Float
    var periodicDurationMax: Float
    var periodicDelayMin: Float
    var periodicDelayMax: Float
    var maxPerPeriod: Int
    var audio: WPEParityParticleAudioResponse
}

/// audioprocessing* keys (1401c1e20.c). Mode 0 is off, 1 left, 2 right, 3 the two channels averaged.
struct WPEParityParticleAudioResponse: Equatable, Sendable {
    var mode: UInt32
    var exponent: Float
    var low: Float
    var high: Float
    /// Inclusive band range, both ≤ 15 and ordered.
    var start: Int
    var end: Int
}

extension WPEParityParticleAudioResponse {
    init(_ entry: WPEParityParticleEntry) {
        let bounds = WPEParityParticleJSON.vector(entry.json["audioprocessingbounds"]) ?? SIMD3(0.8, 1, 0)
        // Unsigned reads: a negative band wraps and clamps to 15 like any index past it.
        let start = min(UInt32(truncatingIfNeeded: entry.integer("audioprocessingfrequencystart", 0)), 15)
        let end = min(UInt32(truncatingIfNeeded: entry.integer("audioprocessingfrequencyend", 1)), 15)
        self.init(
            mode: UInt32(truncatingIfNeeded: entry.integer("audioprocessingmode", 0)),
            exponent: entry.number("audioprocessingexponent", 2), low: bounds.x, high: bounds.y,
            start: Int(min(start, end)), end: Int(max(start, end))
        )
    }

    /// 14022a8a0: the loudest band remapped through the bounds, smoothstepped, then raised to the exponent; 1 when off.
    func level(left: SIMD16<Float>, right: SIMD16<Float>) -> Float {
        guard mode != 0 else { return 1 }
        func band(_ index: Int) -> Float {
            switch mode {
            case 1: left[index]
            case 2: right[index]
            default: (left[index] + right[index]) / 2
            }
        }
        var loudest = band(start)
        for index in start ... end {
            loudest = max(loudest, band(index))
        }
        let x = WPEParityParticleMath.saturate((loudest - low) / (high - low))
        return WPEParityParticleMath.saturate(powf(x * x * (3 - 2 * x), exponent))
    }
}

enum WPEParityParticleInitializer: Equatable, Sendable {
    case lifetime(min: Float, max: Float, exponent: Float)
    case size(min: Float, max: Float, exponent: Float)
    case color(min: SIMD3<Float>, max: SIMD3<Float>, exponent: Float)
    case hsvColor(WPEParityParticleHSVRandom)
    /// Colors as HSV (hue in turns); noise per HSV channel.
    case colorList(hsv: [SIMD3<Float>], noise: SIMD3<Float>)
    case alpha(min: Float, max: Float, exponent: Float)
    case velocity(min: SIMD3<Float>, max: SIMD3<Float>, exponent: Float)
    case inheritControlPointVelocity(controlPoint: Int, min: Float, max: Float)
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
        /// Original operator type 23 immediately returns to the dispatch loop (23fbc0 case 0x17).
        case collisionBox
        case remap(WPEParityParticleRemap)
        case inherit(WPEParityParticleInherit)
    }

    var kind: Kind
    var blend: WPEParityParticleBlend?
}

struct WPEParityParticleChildConfig: Equatable, Sendable {
    enum Trigger: Equatable, Sendable { case always, follow, spawn, death }

    var trigger: Trigger
    var origin: SIMD3<Float>
    var anglesRadians: SIMD3<Float>
    var scale: SIMD3<Float>
    var flags: Int
    var controlPointStartIndex: Int
    var probability: Float
    /// Native child config +0x70, default 10 (1401c1430.c:125); event groups consume this independently of slots.
    var maxCount: Int
    var config: WPEParityParticleConfig
}

/// A rejected child-system field, retaining the attempted typed path and its authored asset.
struct WPEParityParticleChildRejection: Equatable, Sendable {
    var path: [WPEParityParticlePathElement]
    var asset: String
    var field: String
    var reason: String
}

private struct WPEParityParticleParseContext {
    var ancestors: [String]
    var path: [WPEParityParticlePathElement] = []
    var underEventAncestor = false
    var issues: [WPEParityParticleChildRejection] = []
    var sceneVersion = 0
}

struct WPEParityParticleConfig: Equatable, Sendable {
    var maxCount: Int
    var startTime: Float
    var flags: Int
    /// Birth seeds multiply colorn below scene version 5 or without a colour source (c5490:767-770, 6656-6663).
    var multipliesColorn = true
    var randomFrame: Bool
    /// Scales the sprite-sheet phase age/lifetime.
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
    var materialPath: String?
    /// Children omitted at the native maximum system depth.
    var omittedChildPaths: [String] = []
    var diagnostics: [String] = []
    var unsupportedChildren: [WPEParityParticleChildRejection] = []
    /// Effective native CP allocation is the highest referenced index + 1, not the authored array length.
    var controlPointCount = 0
    private var nestedEligibilityIssues: [WPEParityParticleChildRejection] = []

    /// Program prototypes, probes and runtime systems share this resolved tree and its accepted-child indexes.
    init?(path: String, assets: WPEParityProgramAssets, is3D: Bool, sceneVersion: Int = 0) {
        guard let json = assets.json(path) else { return nil }
        self.init(json: json, context: .init(ancestors: [path], sceneVersion: sceneVersion), is3D: is3D,
                  resolveChild: assets.json,
                  resolveMaterial: { materialPath in
                      WPEParityProgramMaterial(path: materialPath, assets: assets).map {
                          WPEParityParticleMaterial(texture0: $0.textures[0].flatMap(assets.textureHeader(named:)))
                      }
                  })
    }

    /// The colour colorn is measured against, 0–1: the last colorrandom midpoint or first colorlist entry, else the
    /// first colorchange startvalue (1401c45f0:129-183, 241-322, 536-595); hsvcolorrandom is not scanned.
    var colornReference: SIMD3<Float> {
        var reference: SIMD3<Float>?
        for initializer in initializers {
            switch initializer {
            case let .color(low, high, _):
                reference = (low + high) / 2 / 255
            case let .colorList(hsv, _):
                reference = WPEParityParticleMath.hsvToRGB(hue: hsv[0].x * 360, saturation: hsv[0].y, value: hsv[0].z)
            default:
                break
            }
        }
        if let reference {
            return reference
        }
        for item in operators {
            if case let .colorChange(_, _, start, _) = item.kind {
                return start
            }
        }
        return SIMD3(repeating: 1)
    }

    /// A colour source: a colorrandom, hsvcolorrandom or colorlist initializer, else a colorchange operator (1401c45f0).
    var hasColor: Bool {
        initializers.contains {
            switch $0 {
            case .color, .hsvColor, .colorList: true
            default: false
            }
        } || operators.contains {
            if case .colorChange = $0.kind {
                true
            } else {
                false
            }
        }
    }

    func descendant(at path: ArraySlice<WPEParityParticlePathElement>) -> WPEParityParticleConfig? {
        guard let first = path.first else { return self }
        let candidates: [WPEParityParticleChildConfig]
        let index: Int
        switch first {
        case let .staticChild(value):
            candidates = children.filter { $0.trigger == .always }
            index = value
        case let .eventGroup(value):
            candidates = children.filter { $0.trigger != .always }
            index = value
        }
        guard candidates.indices.contains(index) else { return nil }
        return candidates[index].config.descendant(at: path.dropFirst())
    }

    /// `is3D` picks the 3D defaults (velocityrandom ±1, distancemax 1, oscillateposition scale 0.5, …).
    init(json: WPESceneJSONValue, is3D: Bool, resolveChild: (String) -> WPESceneJSONValue?) {
        self.init(json: json, context: .init(ancestors: [""]), is3D: is3D, resolveChild: resolveChild,
                  resolveMaterial: { _ in nil })
    }

    /// Parse context is copied per branch: a rejected new nested edge cannot change a healthy sibling.
    private init(json: WPESceneJSONValue, context: WPEParityParticleParseContext, is3D: Bool,
                 resolveChild: (String) -> WPESceneJSONValue?, resolveMaterial: (String) -> WPEParityParticleMaterial?) {
        typealias JSON = WPEParityParticleJSON
        materialPath = JSON.string(json["material"])
        material = materialPath.flatMap(resolveMaterial) ?? material
        maxCount = max(0, Int(JSON.number(json["maxcount"]) ?? 0))
        startTime = JSON.number(json["starttime"]) ?? 0
        // Only the low byte is kept (E 0x1401c56e9).
        flags = Int(JSON.number(json["flags"]) ?? 0) & 0xFF
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
                parent: Int(UInt32(truncatingIfNeeded: entry.integer("parentcontrolpoint", 0)))
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
        // 1401c5490.c:791–810 injects sprite only when renderer is not an array; [] stays empty.
        let rendererEntries: [WPESceneJSONValue] = if case let .array(entries)? = json["renderer"] {
            entries
        } else {
            [.object(["name": .string("sprite")])]
        }
        for entry in rendererEntries {
            let name = JSON.string(entry["name"])?.lowercased() ?? ""
            if let renderer = WPEParityParticleRenderer(name: name, json: entry) {
                renderers.append(renderer)
            } else {
                diagnostics.append("renderer \(name) skipped")
            }
        }
        let asset = context.ancestors.last.flatMap { $0.isEmpty ? nil : $0 } ?? "<root>"
        nestedEligibilityIssues = context.issues + nestedIssues(at: context.path, asset: asset)
        var descendants = context
        descendants.issues = nestedEligibilityIssues
        for entry in JSON.array(json["children"]) {
            appendChild(entry, context: descendants, is3D: is3D, resolveChild: resolveChild,
                        resolveMaterial: resolveMaterial)
        }
        multipliesColorn = context.sceneVersion < 5 || !hasColor
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
        // 1401c6008 / 1401c6910 use cmovb: negative authored integers become point 7, not point 0.
        // Keep Entry's finite conversion protection; do not change other components' controlPoint parser.
        let controlPoint = min(UInt32(truncatingIfNeeded: WPEParityParticleEntry(entry).integer("controlpoint", 0)), 7)
        controlPointCount = max(controlPointCount, Int(controlPoint) + 1)
        emitters.append(WPEParityParticleEmitterConfig(
            shape: shape,
            origin: JSON.vector(entry["origin"]) ?? .zero,
            controlPoint: Int(controlPoint),
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
            maxOnePerFrame: flags & 2 != 0,
            periodicDurationMin: min(JSON.number(entry["minperiodicduration"]) ?? 2,
                                     JSON.number(entry["maxperiodicduration"]) ?? 3),
            periodicDurationMax: JSON.number(entry["maxperiodicduration"]) ?? 3,
            periodicDelayMin: min(JSON.number(entry["minperiodicdelay"]) ?? 1,
                                  JSON.number(entry["maxperiodicdelay"]) ?? 2),
            periodicDelayMax: JSON.number(entry["maxperiodicdelay"]) ?? 2,
            maxPerPeriod: max(0, Int(JSON.number(entry["maxtoemitperperiod"]) ?? 0)),
            audio: WPEParityParticleAudioResponse(WPEParityParticleEntry(entry))
        ))
    }

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
            initializer = .velocity(min: JSON.vector(minimum) ?? -limit, max: JSON.vector(maximum) ?? limit,
                                    exponent: exponent)
        case "inheritcontrolpointvelocity":
            let point = Int(UInt32(truncatingIfNeeded: fields.integer("controlpoint", 0)))
            guard controlPoints.indices.contains(point) else {
                diagnostics.append("initializer \(name) controlpoint \(point) exceeds the current 8-slot allocation")
                return
            }
            initializer = .inheritControlPointVelocity(controlPoint: point,
                                                       min: fields.number("min", 0.1), max: fields.number("max", 0.2))
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
        switch initializer {
        case let .inheritControlPointVelocity(point, _, _): useControlPoints(point)
        case let .sequenceAround(field): useControlPoints(field.controlPoint)
        case let .sequenceBetween(field): useControlPoints(field.start, field.end)
        case let .remap(field): useRemapControlPoints(field, entry: fields)
        default: break
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
            let collision = WPEParityParticleCollision(fields, sphere: name == "collisionsphere", is3D: is3D)
            if collision.behavior != .bounce, name == "collisionsphere" {
                diagnostics.append("operator \(name) (\(collision.behavior.rawValue)) skipped")
                return
            }
            kind = name == "collisionsphere" ? .collisionSphere(collision) : .collisionPlane(collision)
        case "collisionbox":
            kind = .collisionBox
        case "remapvalue":
            kind = .remap(WPEParityParticleRemap(fields, defaultInput: .lifetimeFraction))
        case "inheritvaluefromevent":
            kind = .inherit(WPEParityParticleInherit(fields, fallback: .setColorOpacity))
        default:
            diagnostics.append("operator \(name) skipped")
            return
        }
        var blend = WPEParityParticleBlend.compiled(
            inStart: number("blendinstart", 0), inEnd: number("blendinend", 0),
            outStart: number("blendoutstart", 1), outEnd: number("blendoutend", 1)
        )
        switch kind {
        case .collisionPlane, .collisionSphere, .collisionBox:
            // 1cf5f7→1cc446 goes directly to iteration/clone; these compiler branches never call 1c2a40.
            blend = nil
        default: break
        }
        switch kind {
        case let .controlPointAttract(field): useControlPoints(field.controlPoint)
        case let .vortex(field): useControlPoints(field.controlPoint)
        case let .vortexRing(field): useControlPoints(field.controlPoint)
        case let .maintainDistance(point, _, _), let .reduceMovement(point, _, _, _, _): useControlPoints(point)
        case let .maintainDistanceBetween(start, end): useControlPoints(start, end)
        case let .collisionPlane(field), let .collisionSphere(field): useControlPoints(field.controlPoint)
        case let .remap(field): useRemapControlPoints(field, entry: fields)
        default: break
        }
        operators.append(WPEParityParticleOperator(kind: kind, blend: blend))
    }

    private mutating func useControlPoints(_ indexes: Int...) {
        for index in indexes {
            controlPointCount = max(controlPointCount, index + 1)
        }
    }

    /// Native remap compiler reserves both input/output CP0, and both CP1 only for the between-points value.
    private mutating func useRemapControlPoints(_ field: WPEParityParticleRemap, entry: WPEParityParticleEntry) {
        let values = [field.input, field.output]
        if values.contains(where: { [.distanceToControlPoint, .positionBetweenControlPoints, .controlPoint,
                                     .deltaToControlPoint, .directionToControlPoint].contains($0) }) {
            useControlPoints(field.inputControlPoint, field.outputControlPoint0)
        }
        if values.contains(.positionBetweenControlPoints) {
            useControlPoints(entry.controlPoint("inputcontrolpoint1", 1), field.outputControlPoint1)
        }
    }

    private func nestedIssues(at path: [WPEParityParticlePathElement], asset: String)
        -> [WPEParityParticleChildRejection] {
        var issues: [WPEParityParticleChildRejection] = []
        func reject(_ field: String, _ reason: String) {
            issues.append(.init(path: path, asset: asset, field: field, reason: reason))
        }
        for (index, point) in controlPoints.enumerated() {
            if point.flags & ~0x1000F != 0 {
                reject("controlpoint[\(index)].flags", "unknown control point flag bits")
            }
            if !Self.finite(point.offset) {
                reject("controlpoint[\(index)].offset", "non-finite control point")
            }
        }
        for diagnostic in diagnostics {
            reject("component", diagnostic)
        }
        return issues
    }

    private static func finite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    private mutating func appendChild(
        _ entry: WPESceneJSONValue, context: WPEParityParticleParseContext, is3D: Bool,
        resolveChild: (String) -> WPESceneJSONValue?, resolveMaterial: (String) -> WPEParityParticleMaterial?
    ) {
        typealias JSON = WPEParityParticleJSON
        let path = JSON.string(entry["name"]) ?? JSON.string(entry["particle"]) ?? ""
        let kind = WPEParticleChildEventKind(authoredType: JSON.string(entry["type"]),
                                             flags: JSON.number(entry["flags"]).map { Int($0) })
        let trigger: WPEParityParticleChildConfig.Trigger
        switch kind {
        case .staticSystem: trigger = .always
        case .spawn: trigger = .spawn
        case .death: trigger = .death
        case .follow:
            // Only an explicit "eventfollow" type becomes a follow child; the flags-only default is rejected.
            guard JSON.string(entry["type"])?.lowercased() == "eventfollow" else {
                unsupportedChildren.append(.init(path: context.path + [.eventGroup(children.filter { $0.trigger != .always }.count)],
                                                 asset: path, field: "type",
                                                 reason: "flags-only eventfollow default is unsupported"))
                return
            }
            trigger = .follow
        case .unsupported:
            let reason = "child \(path) (\(JSON.string(entry["type"]) ?? "eventfollow")) skipped"
            diagnostics.append(reason)
            if context.underEventAncestor {
                unsupportedChildren.append(.init(path: context.path + [.eventGroup(children.filter { $0.trigger != .always }.count)],
                                                 asset: path, field: "type", reason: reason))
            }
            return
        }
        let index = children.filter { ($0.trigger == .always) == (trigger == .always) }.count
        let childPath = context.path + [trigger == .always ? .staticChild(index) : .eventGroup(index)]
        // 22ebe0 creates children while the current system's depth is < 10; 22f890 assigns depth + 1.
        // A repeated asset is another instance, not a cycle error. The native depth also bounds such recursion.
        guard context.path.count < WPEParityProgramScene.particleChildDepthLimit else {
            omittedChildPaths.append(path)
            return
        }
        guard let json = resolveChild(path) else {
            diagnostics.append("child \(path) unresolved")
            if context.underEventAncestor || trigger == .follow {
                unsupportedChildren.append(.init(path: childPath, asset: path, field: "name", reason: "unresolved child asset"))
            }
            return
        }
        let origin = JSON.vector(entry["origin"]) ?? .zero
        let angles = JSON.vector(entry["angles"]) ?? .zero
        let scale = JSON.vector(entry["scale"]) ?? SIMD3<Float>(repeating: 1)
        let flags = WPEParityParticleEntry(entry).integer("flags", 0)
        var next = context
        next.ancestors.append(path)
        next.path = childPath
        next.underEventAncestor = context.underEventAncestor || trigger != .always
        func edgeIssue(_ field: String, _ reason: String) -> WPEParityParticleChildRejection {
            .init(path: childPath, asset: path, field: field, reason: reason)
        }
        var placementIssues: [WPEParityParticleChildRejection] = []
        for key in ["origin", "angles", "scale"] where entry[key] != nil && JSON.vector(entry[key]) == nil {
            placementIssues.append(edgeIssue(key, "unparsed child TRS field"))
        }
        if !Self.finite(origin) {
            placementIssues.append(edgeIssue("origin", "non-finite child origin"))
        }
        if !Self.finite(angles) {
            placementIssues.append(edgeIssue("angles", "non-finite child TRS angles"))
        }
        if !Self.finite(scale) {
            placementIssues.append(edgeIssue("scale", "non-finite child TRS scale"))
        } else if scale.x == 0 || scale.y == 0 || scale.z == 0 {
            placementIssues.append(edgeIssue("scale", "singular child TRS scale remains unsupported by Mac policy"))
        }
        if !placementIssues.isEmpty {
            unsupportedChildren += placementIssues
            return
        }
        // Bit 0 copies the parent's live positions into the child's CPs, bit 1 restarts it with each parent period.
        if flags & ~3 != 0 {
            next.issues.append(edgeIssue("child.flags", "unknown child flag bits remain unsupported"))
        }
        let child = WPEParityParticleConfig(json: json, context: next, is3D: is3D, resolveChild: resolveChild,
                                            resolveMaterial: resolveMaterial)
        if context.underEventAncestor || trigger == .follow, !child.nestedEligibilityIssues.isEmpty {
            // Reject this ineligible edge. Already-pruned descendants do not disqualify a healthy ancestor.
            unsupportedChildren += child.nestedEligibilityIssues.map {
                .init(path: childPath, asset: path, field: $0.field, reason: "\($0.asset) \($0.path): \($0.reason)")
            }
            unsupportedChildren += child.unsupportedChildren
            return
        }
        children.append(WPEParityParticleChildConfig(
            trigger: trigger, origin: origin, anglesRadians: angles, scale: scale, flags: flags,
            controlPointStartIndex: Int(UInt8(truncatingIfNeeded: WPEParityParticleEntry(entry).integer("controlpointstartindex", 0))),
            probability: JSON.number(entry["probability"]) ?? 1,
            maxCount: WPEParityParticleEntry(entry).integer("maxcount", 10), config: child
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
