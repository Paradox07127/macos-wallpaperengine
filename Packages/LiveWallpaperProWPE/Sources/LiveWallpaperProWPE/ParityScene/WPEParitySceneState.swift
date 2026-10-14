import simd

/// A material pass the scene JSON sets constants on: the layer material (`effectID` nil, `pass` 0), or entry `pass` of
/// an effect's `passes` overrides.
public struct WPEParityMaterialPassKey: Hashable, Sendable {
    public var objectID: String
    public var effectID: String?
    public var pass: Int

    public init(objectID: String, effectID: String? = nil, pass: Int = 0) {
        self.objectID = objectID
        self.effectID = effectID
        self.pass = pass
    }
}

/// The live fields WPE keeps per object, per image layer effect and per material pass (R24 Q2, Q3, Q6). Animations, user properties and
/// scripts write them; the renderer reads them every frame. Writes that change nothing leave the dirty state alone.
public struct WPEParitySceneState: Sendable {
    public enum Property: String, Sendable, CaseIterable {
        case origin, scale, angles, alpha, color, brightness, visible

        public var componentCount: Int {
            switch self {
            case .origin, .scale, .angles, .color: 3
            case .alpha, .brightness, .visible: 1
            }
        }
    }

    public struct Object: Sendable, Equatable {
        public var origin: SIMD3<Float>
        public var scale: SIMD3<Float>
        /// Radians.
        public var angles: SIMD3<Float>
        public var alpha: Float
        public var color: SIMD3<Float>
        public var brightness: Float
        /// The object's own bit; `isVisible` also reads every ancestor's.
        public var visible: Bool
        /// Stable descriptor slots survive removal; the object no longer participates in the live scene.
        public fileprivate(set) var alive = true
    }

    /// A material constant as WPE holds it: `count` components, the rest of `value` unused.
    public struct Constant: Sendable, Equatable {
        public var value: SIMD4<Float>
        public var count: Int

        public init(value: SIMD4<Float>, count: Int) {
            self.value = value
            self.count = count
        }

        /// The first four components of a JSON constant; nil when it has none.
        public init?(components: [Double]) {
            guard !components.isEmpty else { return nil }
            var value = SIMD4<Float>.zero
            for lane in 0 ..< min(4, components.count) {
                value[lane] = Float(components[lane])
            }
            self.init(value: value, count: min(4, components.count))
        }
    }

    public struct EffectKey: Hashable, Sendable {
        public var objectID: String
        public var effectID: String

        public init(objectID: String, effectID: String) {
            self.objectID = objectID
            self.effectID = effectID
        }
    }

    private struct Pass: Sendable {
        var constants: [String: Constant]
        var generation = 0
    }

    /// The hook WPE's descriptor onChanged runs for a written field (R25 §2).
    public enum Invalidation: Int, Sendable, CaseIterable {
        case none
        /// obj+0xd0 cleared; angles also rebuild the rotation first.
        case transform
        case visibility
        /// Visible effects recounted and the layer's passes rebuilt.
        case effectPasses
        /// pass+0x1f8 set to 3: uploaded at the pass's next bind.
        case materialConstants
        /// scene+0xe0 bit31: bloom constants rebuilt after the script tick.
        case bloom
        /// Copied to Main+0x1298.
        case lighting
        /// instance+0x1b0 = 1, applied by the system's next update.
        case particleInstance
        case textLayout
        /// Player vtable +0x68 (rate) or +0x70 (loop).
        case mediaPlayer
        /// Stream gain volume² × master.
        case soundGain
    }

    /// A field only script descriptors write (R25 §3), keyed by descriptor name; `objectID` "" is the scene.
    public struct ScriptFieldKey: Hashable, Sendable {
        public var objectID: String
        public var name: String

        public init(objectID: String, name: String) {
            self.objectID = objectID
            self.name = name
        }
    }

    public enum ScriptValue: Sendable, Equatable {
        case vector(SIMD4<Float>)
        /// Native type 0 fields keep the full signed 32-bit domain instead of passing through Float32.
        case integer(Int32)
        case string(String)
    }

    public let ids: [String]
    public private(set) var objects: [Object]
    /// Actual common-scene members in current order; transform-only parent placeholders are not members.
    /// Stable object/descriptor slots in `ids` never move when this order changes.
    public private(set) var commonOrder: [String]
    /// HDR frames multiply the layer colour by brightness (R24 Q6).
    public let hdr: Bool
    /// Bumped by every origin, scale or angles change.
    public private(set) var transformGeneration = 0
    /// Bumped by every visible change.
    public private(set) var visibilityGeneration = 0
    /// Common-scene membership changes require composition again, independently of visibility.
    public private(set) var membershipGeneration = 0
    /// Every image layer effect in scene order, then every text layer effect.
    public let effects: [EffectKey]
    /// The visible bit of each entry of `effects` (effect+0x118 bit0, R24 Q2).
    public private(set) var effectVisibility: [Bool]
    /// Bumped by every effect visible change.
    public private(set) var effectVisibilityGeneration = 0
    /// Bumped by every material constant change of any pass.
    public private(set) var constantsGeneration = 0
    public private(set) var scriptFields: [ScriptFieldKey: ScriptValue] = [:]
    /// Includes fields with no native dirty hook, such as particle instance rate.
    public private(set) var scriptFieldsGeneration = 0
    private var scriptFieldGenerations = [Int](repeating: 0, count: Invalidation.allCases.count)
    private let lightIDs: Set<String>
    private let indexByID: [String: Int]
    private let parents: [Int?]
    private var passes: [Pass]
    private var passIndexByKey: [WPEParityMaterialPassKey: Int]
    private let effectIndexByKey: [EffectKey: Int]

    /// Objects with a transform (image layers, groups, particles) start from the values the frame plan bakes; any other
    /// object the parent chain names holds only its visible bit. `constants` seeds each material pass.
    public init(document: WPESceneDocument, hdr: Bool, constants: [WPEParityMaterialPassKey: [String: [Double]]] = [:]) {
        var ids: [String] = []
        var objects: [Object] = []
        var indexByID: [String: Int] = [:]
        func add(_ id: String, _ object: Object) {
            guard indexByID[id] == nil else { return }
            indexByID[id] = ids.count
            ids.append(id)
            objects.append(object)
        }
        let images = Dictionary(document.imageObjects.map { ($0.id, $0) }) { first, _ in first }
        let particles = Dictionary(document.particleObjects.map { ($0.id, $0) }) { first, _ in first }
        let texts = Dictionary(document.textObjects.map { ($0.id, $0) }) { first, _ in first }
        let lights = Dictionary(document.lightObjects.map { ($0.id, $0) }) { first, _ in first }
        lightIDs = Set(lights.keys)
        for layer in WPEParityLayerTransform.layers(document: document)
            + WPEParityLayerTransform.textLayers(document: document) {
            var object = Object(origin: layer.origin, scale: layer.scale, angles: layer.angles, alpha: 1, color: .one,
                                brightness: 1, visible: document.ownVisibilityByID[layer.id] ?? true)
            if let image = images[layer.id] {
                (object.alpha, object.color, object.brightness) = (Float(image.alpha), SIMD3(image.color),
                                                                   Float(image.brightness))
            } else if let text = texts[layer.id] {
                (object.alpha, object.color, object.brightness) = (Float(text.alpha), SIMD3(text.color),
                                                                   Float(text.brightness))
            } else if let particle = particles[layer.id] {
                (object.alpha, object.color) = (Float(particle.alpha), SIMD3(particle.color))
            } else if let light = lights[layer.id] {
                object.color = SIMD3(light.color)
            }
            add(layer.id, object)
        }
        for id in Set(document.ownVisibilityByID.keys).union(document.objectParentByID.keys)
            .union(document.objectParentByID.values).sorted() {
            add(id, Object(origin: .zero, scale: .one, angles: .zero, alpha: 1, color: .one, brightness: 1,
                           visible: document.ownVisibilityByID[id] ?? true))
        }
        self.ids = ids
        self.objects = objects
        self.indexByID = indexByID
        var commonIDs: Set<String> = []
        commonOrder = document.resolvedObjectsJSON.compactMap { object in
            guard let id = WPEParitySceneAnimations.id(object), indexByID[id] != nil,
                  commonIDs.insert(id).inserted else { return nil }
            return id
        }
        parents = ids.map { document.objectParentByID[$0].flatMap { indexByID[$0] } }
        self.hdr = hdr
        var passes: [Pass] = []
        var passIndexByKey: [WPEParityMaterialPassKey: Int] = [:]
        for (key, values) in constants.sorted(by: { ($0.key.objectID, $0.key.effectID ?? "", $0.key.pass)
                < ($1.key.objectID, $1.key.effectID ?? "", $1.key.pass)
        }) {
            passIndexByKey[key] = passes.count
            passes.append(Pass(constants: values.compactMapValues(Constant.init(components:))))
        }
        self.passes = passes
        self.passIndexByKey = passIndexByKey
        var effects: [EffectKey] = []
        var effectVisibility: [Bool] = []
        var effectIndexByKey: [EffectKey: Int] = [:]
        let layers = document.imageObjects.map { ($0.id, $0.effects) }
            + document.textObjects.map { ($0.id, $0.effects) }
        for (id, layerEffects) in layers {
            for effect in layerEffects {
                let key = EffectKey(objectID: id, effectID: effect.id)
                guard effectIndexByKey[key] == nil else { continue }
                effectIndexByKey[key] = effects.count
                effects.append(key)
                effectVisibility.append(effect.visible)
            }
        }
        self.effects = effects
        self.effectVisibility = effectVisibility
        self.effectIndexByKey = effectIndexByKey
    }

    /// Seeds a shader annotation default at load without marking a runtime write. Authored values win.
    public mutating func seedConstant(_ name: String, of key: WPEParityMaterialPassKey, value: Constant) {
        if passIndexByKey[key] == nil {
            passIndexByKey[key] = passes.count
            passes.append(Pass(constants: [:]))
        }
        guard let index = passIndexByKey[key], passes[index].constants[name] == nil else { return }
        passes[index].constants[name] = value
    }

    /// Nil for an effect the scene does not have.
    public func isEffectVisible(_ effectID: String, of objectID: String) -> Bool? {
        effectIndexByKey[EffectKey(objectID: objectID, effectID: effectID)].map { effectVisibility[$0] }
    }

    /// False for an effect the scene does not have.
    @discardableResult
    public mutating func setEffect(_ effectID: String, of objectID: String, visible: Bool) -> Bool {
        guard let index = effectIndexByKey[EffectKey(objectID: objectID, effectID: effectID)] else { return false }
        if effectVisibility[index] != visible {
            effectVisibility[index] = visible
            effectVisibilityGeneration += 1
        }
        return true
    }

    public func index(of id: String) -> Int? {
        indexByID[id].flatMap { objects[$0].alive ? $0 : nil }
    }

    public func object(_ id: String) -> Object? {
        index(of: id).map { objects[$0] }
    }

    /// Unmodelled IDs keep their previous admission; known removed objects never re-enter a later layout.
    public func isAlive(_ id: String) -> Bool {
        indexByID[id].map { objects[$0].alive } ?? true
    }

    /// Removes membership without shifting slots already held by compiled draws and descriptor bindings.
    /// Resource owners consume the new membership at the native post-update composition boundary.
    @discardableResult
    public mutating func removeObject(_ id: String) -> Bool {
        guard let index = index(of: id) else { return false }
        objects[index].alive = false
        commonOrder.removeAll { $0 == id }
        scriptFields = scriptFields.filter { $0.key.objectID != id }
        membershipGeneration += 1
        return true
    }

    /// 14018bbd0 removes the common member before clamping the unsigned low32 target position.
    /// Pending members remain sortable until their successful deferred removal.
    @discardableResult
    public mutating func sortObject(_ id: String, to position: Int32) -> Bool {
        guard index(of: id) != nil, let previous = commonOrder.firstIndex(of: id) else { return false }
        commonOrder.remove(at: previous)
        let next = min(Int(UInt32(bitPattern: position)), commonOrder.count)
        commonOrder.insert(id, at: next)
        membershipGeneration += 1
        return true
    }

    /// The property's components in the leading lanes; `visible` reads 1 or 0.
    public func value(_ property: Property, of id: String) -> SIMD4<Float>? {
        guard let object = object(id) else { return nil }
        return switch property {
        case .origin: SIMD4(object.origin, 0)
        case .scale: SIMD4(object.scale, 0)
        case .angles: SIMD4(object.angles, 0)
        case .alpha: SIMD4(object.alpha, 0, 0, 0)
        case .color: SIMD4(object.color, 0)
        case .brightness: SIMD4(object.brightness, 0, 0, 0)
        case .visible: SIMD4(object.visible ? 1 : 0, 0, 0, 0)
        }
    }

    /// Takes `property.componentCount` leading lanes of `value`; `visible` is set by any non-zero x. False for an
    /// unknown object.
    @discardableResult
    public mutating func set(_ property: Property, of id: String, to value: SIMD4<Float>) -> Bool {
        guard let index = index(of: id) else { return false }
        set(property, at: index, to: value)
        return true
    }

    public mutating func set(_ property: Property, at index: Int, to value: SIMD4<Float>) {
        guard objects[index].alive else { return }
        let xyz = SIMD3(value.x, value.y, value.z)
        switch property {
        case .origin where objects[index].origin != xyz:
            objects[index].origin = xyz
            transformGeneration += 1
        case .scale where objects[index].scale != xyz:
            objects[index].scale = xyz
            transformGeneration += 1
        case .angles where objects[index].angles != xyz:
            objects[index].angles = xyz
            transformGeneration += 1
        case .alpha:
            objects[index].alpha = value.x
        case .color where objects[index].color != xyz:
            objects[index].color = xyz
            if lightIDs.contains(ids[index]) {
                scriptFieldGenerations[Invalidation.lighting.rawValue] += 1
            }
        case .brightness:
            objects[index].brightness = value.x
        case .visible where objects[index].visible != (value.x != 0):
            objects[index].visible = value.x != 0
            visibilityGeneration += 1
        default:
            break
        }
    }

    /// The object's own bit ANDed with every ancestor's (R24 Q2).
    public func isVisible(_ id: String) -> Bool {
        indexByID[id].map(isVisible(at:)) ?? true
    }

    public func isVisible(at index: Int) -> Bool {
        var current: Int? = index
        var steps = 0
        while let object = current, steps <= objects.count {
            if !objects[object].alive || !objects[object].visible {
                return false
            }
            current = parents[object]
            steps += 1
        }
        return true
    }

    /// g_Color4 of the object's albedo draws: colour × (HDR ? brightness : 1), alpha (R24 Q6).
    public func layerColor(at index: Int) -> SIMD4<Float> {
        let object = objects[index]
        return SIMD4(object.color * (hdr ? object.brightness : 1), object.alpha)
    }

    public func passIndex(of key: WPEParityMaterialPassKey) -> Int? {
        passIndexByKey[key]
    }

    public func constant(_ name: String, of key: WPEParityMaterialPassKey) -> Constant? {
        passIndexByKey[key].flatMap { passes[$0].constants[name] }
    }

    /// False when no draw uses the pass.
    @discardableResult
    public mutating func setConstant(_ name: String, of key: WPEParityMaterialPassKey, to constant: Constant) -> Bool {
        guard let index = passIndexByKey[key] else { return false }
        setConstant(name, pass: index, to: constant)
        return true
    }

    public mutating func setConstant(_ name: String, pass index: Int, to constant: Constant) {
        guard passes[index].constants[name] != constant else { return }
        passes[index].constants[name] = constant
        passes[index].generation += 1
        constantsGeneration += 1
    }

    /// The counter `invalidation` bumps; `.none` never moves.
    public func generation(_ invalidation: Invalidation) -> Int {
        switch invalidation {
        case .none: 0
        case .transform: transformGeneration
        case .visibility: visibilityGeneration
        case .effectPasses: effectVisibilityGeneration
        case .materialConstants: constantsGeneration
        default: scriptFieldGenerations[invalidation.rawValue]
        }
    }

    public func scriptField(_ name: String, of objectID: String) -> ScriptValue? {
        scriptFields[ScriptFieldKey(objectID: objectID, name: name)]
    }

    /// A changed value bumps `generation(invalidation)`.
    public mutating func setScriptField(_ name: String, of objectID: String, to value: ScriptValue,
                                        invalidating invalidation: Invalidation) {
        guard objectID.isEmpty || isAlive(objectID) else { return }
        let key = ScriptFieldKey(objectID: objectID, name: name)
        guard scriptFields[key] != value else { return }
        scriptFields[key] = value
        scriptFieldsGeneration += 1
        scriptFieldGenerations[invalidation.rawValue] += 1
    }

    /// The pass's constants by material key name.
    public func constants(pass index: Int) -> [String: Constant] {
        passes[index].constants
    }

    /// Bumped by every change of the pass's constants; 0 while they hold their loaded values.
    public func constantGeneration(pass index: Int) -> Int {
        passes[index].generation
    }
}
