/// One scriptable descriptor (R25 §2–§3): the state field a script write lands in and the hook WPE's onChanged runs.
/// Every write overwrites the field (setNative copies, R25/dis1.txt:1-13); only flag 4 converts units.
public struct WPEParityScriptProperty: Hashable, Sendable {
    /// Descriptor type codes.
    public enum ValueType: Int, Sendable {
        case int = 0, vec2, vec3, vec4, float, string, flagBool, object, byteBool

        public var componentCount: Int {
            switch self {
            case .vec2: 2
            case .vec3: 3
            case .vec4: 4
            case .string, .object: 0
            default: 1
            }
        }

        /// The type a material constant of `components` floats registers with (140154480.c:484-513).
        public init?(constantComponents components: Int) {
            switch components {
            case 1: self = .float
            case 2: self = .vec2
            case 3: self = .vec3
            case 4: self = .vec4
            default: return nil
            }
        }
    }

    public struct Flags: OptionSet, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// The native wrapper registers this member without a setter, and JSON does not parse it.
        public static let notFromJSON = Flags(rawValue: 2)
        /// Float and vec3 object conversions use the native angle branch.
        public static let angle = Flags(rawValue: 4)
    }

    /// The object class that registers the descriptor.
    public enum Owner: Sendable {
        /// Every object (1401e0530).
        case object
        case image
        case effect
        case material
        /// A particle system's instance override object (14024d940).
        case particleInstance
        case camera
        case light
        case text
        case sound
        /// The IVideoTexture of an image layer (140214050).
        case video
        case scene
    }

    public enum Target: Hashable, Sendable {
        case object(WPEParitySceneState.Property)
        case effectVisible
        case constant
        case field
    }

    public let name: String
    public let owner: Owner
    public let type: ValueType
    public let flags: Flags
    public let target: Target
    public let invalidation: WPEParitySceneState.Invalidation

    public init(name: String, owner: Owner, type: ValueType, flags: Flags = [], target: Target = .field,
                invalidation: WPEParitySceneState.Invalidation = .none) {
        self.name = name
        self.owner = owner
        self.type = type
        self.flags = flags
        self.target = target
        self.invalidation = invalidation
    }

    /// The accepted-write hook is separate from changed-value render invalidation (1401a49f0/1f7090).
    var isSoundVolumeWrite: Bool {
        owner == .sound && name == "volume" && type == .float && target == .field
            && !flags.contains(.notFromJSON)
    }

    /// π/180 as WPE multiplies it (DAT_140492628).
    public static let degreesToRadians: Float = 0.017_453_292
    public static let radiansToDegrees: Float = 57.295_78

    /// Base class members (1401e0530.c:69-739).
    public static let base: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "origin", owner: .object, type: .vec3, target: .object(.origin),
                                invalidation: .transform),
        WPEParityScriptProperty(name: "scale", owner: .object, type: .vec3, target: .object(.scale),
                                invalidation: .transform),
        WPEParityScriptProperty(name: "angles", owner: .object, type: .vec3, flags: .angle, target: .object(.angles),
                                invalidation: .transform),
        WPEParityScriptProperty(name: "parallaxDepth", owner: .object, type: .vec2),
        WPEParityScriptProperty(name: "sortorder", owner: .object, type: .int),
        WPEParityScriptProperty(name: "name", owner: .object, type: .string),
        WPEParityScriptProperty(name: "solid", owner: .object, type: .flagBool),
        WPEParityScriptProperty(name: "disablepropagation", owner: .object, type: .flagBool),
    ]

    /// Layer visible: +0x120 bit0, no hook (R25/dis1.txt:110-124).
    public static let visible = WPEParityScriptProperty(name: "visible", owner: .object, type: .flagBool,
                                                        target: .object(.visible), invalidation: .visibility)

    /// Image members (1401ee520.c:69-247); none has a hook.
    public static let image: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "alpha", owner: .image, type: .float, target: .object(.alpha)),
        WPEParityScriptProperty(name: "color", owner: .image, type: .vec3, target: .object(.color)),
        WPEParityScriptProperty(name: "brightness", owner: .image, type: .float, target: .object(.brightness)),
        WPEParityScriptProperty(name: "size", owner: .image, type: .vec2),
        WPEParityScriptProperty(name: "perspective", owner: .image, type: .flagBool),
        WPEParityScriptProperty(name: "castshadow", owner: .image, type: .flagBool),
        WPEParityScriptProperty(name: "copybackground", owner: .image, type: .flagBool),
        WPEParityScriptProperty(name: "nointerpolation", owner: .image, type: .flagBool),
        WPEParityScriptProperty(name: "clampuvs", owner: .image, type: .flagBool),
        WPEParityScriptProperty(name: "ledsource", owner: .image, type: .flagBool),
        WPEParityScriptProperty(name: "colorBlendMode", owner: .image, type: .int),
    ]

    /// Effect visible: the hook recounts visible effects and rebuilds the passes (1401e6300.c:17-30).
    public static let effectVisible = WPEParityScriptProperty(name: "visible", owner: .effect, type: .flagBool,
                                                              target: .effectVisible, invalidation: .effectPasses)

    /// Particle instance fields (14024d940): all but `rate` set instance+0x1b0.
    public static let particleInstance: [WPEParityScriptProperty] = {
        var fields = ["alpha", "size", "count", "speed", "lifetime", "brightness"].map {
            WPEParityScriptProperty(name: $0, owner: .particleInstance, type: .float, invalidation: .particleInstance)
        }
        fields.append(WPEParityScriptProperty(name: "rate", owner: .particleInstance, type: .float))
        fields.append(WPEParityScriptProperty(name: "colorn", owner: .particleInstance, type: .vec3,
                                              invalidation: .particleInstance))
        for index in 0 ..< 8 {
            fields.append(WPEParityScriptProperty(name: "controlpoint\(index)", owner: .particleInstance,
                                                  type: .vec3, invalidation: .particleInstance))
            fields.append(WPEParityScriptProperty(name: "controlpointangle\(index)", owner: .particleInstance,
                                                  type: .vec3, invalidation: .particleInstance))
        }
        return fields
    }()

    /// Camera fov +0x2d8 and zoom +0x2dc, read by the next frame's V/P (1401f3460.c:72-123).
    public static let camera: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "fov", owner: .camera, type: .float),
        WPEParityScriptProperty(name: "zoom", owner: .camera, type: .float),
        WPEParityScriptProperty(name: "queuemode", owner: .camera, type: .string),
    ]

    /// 1401f3460's byte enum table and 1401f38c0: exact names; any unmatched UTF-8 string chooses entry zero.
    public var stringValues: [String]? {
        owner == .camera && name == "queuemode" ? ["random", "sequential"] : nil
    }

    public func canonicalString(_ value: String, fromJSON: Bool = false) -> String {
        guard let stringValues else { return value }
        // Runtime 1401f38c0 uses strlen; fromJSON 1401f3a20 compares the explicit std::string length.
        let bytes = value.utf8.prefix { fromJSON || $0 != 0 }
        return stringValues.first { bytes.elementsEqual($0.utf8) } ?? stringValues[0]
    }

    /// Basic shader-light fields (14025da80.c). Native fields have no setter hook; the lighting generation is the
    /// parity renderer's consumption boundary. Type/shadow/cookie changes need a real resource reclassification.
    public static let light: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "color", owner: .light, type: .vec3, target: .object(.color),
                                invalidation: .lighting),
        WPEParityScriptProperty(name: "controlpoint", owner: .light, type: .vec3, invalidation: .lighting),
    ] + ["intensity", "radius", "exponent", "innercone", "outercone"].map {
        WPEParityScriptProperty(name: $0, owner: .light, type: .float, invalidation: .lighting)
    }

    /// Text fields whose hook re-lays the text out (R25/dis1.txt:134-135); the alpha/colour group has no hook.
    public static let text: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "alpha", owner: .text, type: .float, target: .object(.alpha)),
        WPEParityScriptProperty(name: "color", owner: .text, type: .vec3, target: .object(.color)),
        WPEParityScriptProperty(name: "brightness", owner: .text, type: .float, target: .object(.brightness)),
        WPEParityScriptProperty(name: "backgroundbrightness", owner: .text, type: .float),
        WPEParityScriptProperty(name: "text", owner: .text, type: .string, invalidation: .textLayout),
        WPEParityScriptProperty(name: "font", owner: .text, type: .string, invalidation: .textLayout),
        WPEParityScriptProperty(name: "pointsize", owner: .text, type: .float, invalidation: .textLayout),
        WPEParityScriptProperty(name: "horizontalalign", owner: .text, type: .string, invalidation: .textLayout),
        WPEParityScriptProperty(name: "verticalalign", owner: .text, type: .string, invalidation: .textLayout),
        WPEParityScriptProperty(name: "padding", owner: .text, type: .vec2, invalidation: .textLayout),
        WPEParityScriptProperty(name: "spacing", owner: .text, type: .vec2, invalidation: .textLayout),
        WPEParityScriptProperty(name: "maxwidth", owner: .text, type: .float, invalidation: .textLayout),
        WPEParityScriptProperty(name: "maxrows", owner: .text, type: .int, invalidation: .textLayout),
        WPEParityScriptProperty(name: "blockalign", owner: .text, type: .flagBool, invalidation: .textLayout),
        WPEParityScriptProperty(name: "limitwidth", owner: .text, type: .flagBool, invalidation: .textLayout),
        WPEParityScriptProperty(name: "limitrows", owner: .text, type: .flagBool, invalidation: .textLayout),
        WPEParityScriptProperty(name: "limituseellipsis", owner: .text, type: .flagBool, invalidation: .textLayout),
    ]

    /// Sound: volume's hook sets each stream's gain to volume² × master (1401f7090.c:71).
    public static let sound: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "volume", owner: .sound, type: .float, invalidation: .soundGain),
        WPEParityScriptProperty(name: "mintime", owner: .sound, type: .float),
        WPEParityScriptProperty(name: "maxtime", owner: .sound, type: .float),
        WPEParityScriptProperty(name: "attenuation", owner: .sound, type: .float),
        WPEParityScriptProperty(name: "mindistance", owner: .sound, type: .float),
    ]

    /// IVideoTexture rate and loop call the player at once (R25/dis1.txt:168-190).
    public static let video: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "rate", owner: .video, type: .float, invalidation: .mediaPlayer),
        WPEParityScriptProperty(name: "loop", owner: .video, type: .byteBool, invalidation: .mediaPlayer),
        WPEParityScriptProperty(name: "duration", owner: .video, type: .float, flags: .notFromJSON),
    ]

    /// Scene fields under the IScene names of the official docs: bloom sets scene+0xe0 bit31 (R25/dis1.txt:154-156),
    /// ambient and skylight copy to Main+0x1298 (:161-167).
    public static let scene: [WPEParityScriptProperty] = [
        WPEParityScriptProperty(name: "bloomstrength", owner: .scene, type: .float, invalidation: .bloom),
        WPEParityScriptProperty(name: "bloomthreshold", owner: .scene, type: .float, invalidation: .bloom),
        WPEParityScriptProperty(name: "ambientcolor", owner: .scene, type: .vec3, invalidation: .lighting),
        WPEParityScriptProperty(name: "skylightcolor", owner: .scene, type: .vec3, invalidation: .lighting),
    ]

    /// A material constant's instance descriptor (140154480.c:463-514): its onChanged sets pass+0x1f8 |= 3.
    public static func material(name: String, components: Int, angle: Bool = false) -> WPEParityScriptProperty? {
        ValueType(constantComponents: components).map {
            WPEParityScriptProperty(name: name, owner: .material, type: $0, flags: angle ? .angle : [],
                                    target: .constant, invalidation: .materialConstants)
        }
    }

    /// The members a layer of `kind` exposes, base class first.
    public static func layer(_ kind: WPEParityScriptLayerKind) -> [WPEParityScriptProperty] {
        switch kind {
        case .image: base + [visible] + image
        case .text: base + [visible] + text
        case .particle: base + [WPEParityScriptProperty(name: "visible", owner: .object, type: .flagBool,
                                                        flags: .notFromJSON, target: .object(.visible),
                                                        invalidation: .visibility)] + particleInstance
        case .sound: base + sound
        case .camera: base + [visible] + camera
        case .light: base + [visible] + light
        case .group: base + [visible]
        }
    }

    /// Stored units of a script value: flag 4 degrees become radians.
    public func stored(fromScript value: SIMD4<Float>) -> SIMD4<Float> {
        flags.contains(.angle) && (type == .float || type == .vec3) ? value * Self.degreesToRadians : value
    }

    public func script(fromStored value: SIMD4<Float>) -> SIMD4<Float> {
        flags.contains(.angle) && (type == .float || type == .vec3) ? value * Self.radiansToDegrees : value
    }

    /// Writes `value` (script units) to the object `objectID`; `pass` names the material pass of a constant.
    public func write(_ value: WPEParitySceneState.ScriptValue, objectID: String, effectID: String? = nil,
                      pass: WPEParityMaterialPassKey? = nil, to state: inout WPEParitySceneState) {
        guard !flags.contains(.notFromJSON) else { return }
        switch (target, value) {
        case let (.object(property), .vector(vector)):
            state.set(property, of: objectID, to: stored(fromScript: vector))
        case let (.effectVisible, .vector(vector)):
            if let effectID {
                state.setEffect(effectID, of: objectID, visible: vector.x != 0)
            }
        case let (.constant, .vector(vector)):
            if let pass {
                state.setConstant(name, of: pass, to: WPEParitySceneState.Constant(
                    value: stored(fromScript: vector), count: type.componentCount
                ))
            }
        case (.field, .vector):
            state.setScriptField(fieldName, of: objectID, to: value.map(stored(fromScript:)), invalidating: invalidation)
        case let (.field, .string(string)):
            state.setScriptField(fieldName, of: objectID, to: .string(canonicalString(string)), invalidating: invalidation)
        case (.field, .integer):
            state.setScriptField(fieldName, of: objectID, to: value, invalidating: invalidation)
        default:
            break
        }
    }

    /// The field's value in script units; nil while the state holds none.
    public func read(objectID: String, effectID: String? = nil, pass: WPEParityMaterialPassKey? = nil,
                     from state: WPEParitySceneState) -> WPEParitySceneState.ScriptValue? {
        switch target {
        case let .object(property):
            state.value(property, of: objectID).map { .vector(script(fromStored: $0)) }
        case .effectVisible:
            effectID.flatMap { state.isEffectVisible($0, of: objectID) }.map { .vector(SIMD4($0 ? 1 : 0, 0, 0, 0)) }
        case .constant:
            pass.flatMap { state.constant(name, of: $0) }.map { .vector(script(fromStored: $0.value)) }
        case .field:
            state.scriptField(fieldName, of: objectID).map { $0.map(script(fromStored:)) }
        }
    }

    /// Owners with members of the same name (particle instance `alpha`, video `rate`) keep apart in the state.
    var fieldName: String {
        switch owner {
        case .particleInstance: "instance.\(name)"
        case .video: "video.\(name)"
        default: name
        }
    }
}

/// The descriptor table a layer registers, by the object class the scene JSON names.
public enum WPEParityScriptLayerKind: Int, Sendable, CaseIterable {
    case image, text, particle, sound, camera, group, light

    /// Shared by script slots and native-unit animation bindings; neither keeps a second object registry.
    public static func classify(id: String, object: WPESceneJSONValue,
                                document: WPESceneDocument) -> WPEParityScriptLayerKind {
        // 14018ff60: a string camera member selects the camera class.
        if case .string? = object["camera"] {
            return .camera
        }
        if document.textObjects.contains(where: { $0.id == id }) {
            return .text
        }
        if document.imageObjects.contains(where: { $0.id == id }) {
            return .image
        }
        if document.particleObjects.contains(where: { $0.id == id }) {
            return .particle
        }
        if document.soundObjects.contains(where: { $0.id == id }) {
            return .sound
        }
        if document.lightObjects.contains(where: { $0.id == id }) {
            return .light
        }
        return .group
    }
}

extension WPEParitySceneState.ScriptValue {
    func map(_ transform: (SIMD4<Float>) -> SIMD4<Float>) -> Self {
        switch self {
        case let .vector(vector): .vector(transform(vector))
        case .string, .integer: self
        }
    }
}
