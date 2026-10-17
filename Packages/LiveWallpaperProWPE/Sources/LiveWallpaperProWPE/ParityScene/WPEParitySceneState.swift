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

/// The live fields WPE keeps per object, per image layer effect and per material pass. Animations, user properties and
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
        /// One native model reference held by this admitted layer, independent of its script wrapper.
        public internal(set) var modelDataToken: UInt32?
        /// The loaded image object whose materials and textures a script-created image layer draws with.
        public internal(set) var templateID: String?
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

    /// The hook WPE's descriptor onChanged runs for a written field.
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

    /// A field only script descriptors write, keyed by descriptor name; `objectID` "" is the scene.
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

    public private(set) var ids: [String]
    public private(set) var objects: [Object]
    /// Actual common-scene members in current order; transform-only parent placeholders are not members.
    /// Stable object/descriptor slots in `ids` never move when this order changes.
    public private(set) var commonOrder: [String]
    /// The transparent member vector (14018aac0.c:206): creation order until the first sort, then far to near.
    public private(set) var transparentOrder: [String]
    private var transparentMembers: Set<String>
    /// Members that key −∞ and so always sort last.
    private var fullscreenMembers: Set<String>
    /// HDR frames multiply the layer colour by brightness.
    public let hdr: Bool
    /// Bumped by every origin, scale or angles change.
    public private(set) var transformGeneration = 0
    /// Bumped by every visible change.
    public private(set) var visibilityGeneration = 0
    /// Common-scene membership changes require composition again, independently of visibility.
    public private(set) var membershipGeneration = 0
    /// Every image layer effect in scene order, then every text layer effect.
    public private(set) var effects: [EffectKey]
    /// The visible bit of each entry of `effects` (effect+0x118 bit0).
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
    private var indexByID: [String: Int]
    private var parents: [Int?]
    private var passes: [Pass]
    private var passIndexByKey: [WPEParityMaterialPassKey: Int]
    private var effectIndexByKey: [EffectKey: Int]
    var modelDataValues: [UInt32: WPEParitySceneModelData] = [:]
    var lastModelDataToken: UInt32 = 0
    var modelDataRevision = 0
    /// Every object id the document declares, including objects this state holds no slot for.
    public let loadedIDs: Set<String>
    /// The last id 1401a38f0's counter handed out; 0 before any automatic id.
    private var lastAutomaticID: UInt64 = 0

    /// Appends a script-created image layer that copies `templateID`'s live fields before `configure`.
    /// 1401a38f0.c:21-41 keeps an explicit id; otherwise :44-102 advances the counter past reserved ids.
    /// `loaded`: the load-time state whose template effects and pass constants the clone starts from; nil adopts none.
    public mutating func appendImageLayer(cloning templateID: String, id explicitID: UInt64?,
                                          adopting loaded: WPEParitySceneState? = nil,
                                          configure: (inout Object) -> Void) throws -> UInt64 {
        guard let template = indexByID[templateID], objects[template].templateID == nil,
              objects[template].modelDataToken == nil else {
            throw WPEParityModelDataFailure.safety("created image layer requires a loaded image template")
        }
        let number: UInt64
        if let explicitID {
            guard !loadedIDs.contains(String(explicitID)), indexByID[String(explicitID)] == nil else {
                throw WPEParityModelDataFailure.safety("created image layer reuses a reserved id")
            }
            number = explicitID
        } else {
            number = automaticObjectID()
        }
        let id = String(number)
        var object = objects[template]
        object.alive = true
        object.templateID = templateID
        configure(&object)
        indexByID[id] = ids.count
        ids.append(id)
        objects.append(object)
        parents.append(nil)
        commonOrder.append(id)
        if transparentMembers.contains(templateID) {
            transparentMembers.insert(id)
            transparentOrder.append(id)
            if fullscreenMembers.contains(templateID) {
                fullscreenMembers.insert(id)
            }
        }
        if let loaded {
            // Append only: `effects` order is the load order every effect-visibility consumer indexes by.
            for (index, key) in loaded.effects.enumerated() where key.objectID == templateID {
                let clone = EffectKey(objectID: id, effectID: key.effectID)
                effectIndexByKey[clone] = effects.count
                effects.append(clone)
                effectVisibility.append(loaded.effectVisibility[index])
            }
            let templatePasses = loaded.passIndexByKey.filter { $0.key.objectID == templateID }
                .sorted { ($0.key.effectID ?? "", $0.key.pass) < ($1.key.effectID ?? "", $1.key.pass) }
            for (key, index) in templatePasses {
                passIndexByKey[.init(objectID: id, effectID: key.effectID, pass: key.pass)] = passes.count
                passes.append(Pass(constants: loaded.passes[index].constants))
            }
        }
        membershipGeneration += 1
        transformGeneration += 1
        visibilityGeneration += 1
        return number
    }

    /// Advances 1401a38f0's counter past every loaded or held id (1401a38f0.c:44-102).
    public mutating func automaticObjectID() -> UInt64 {
        repeat {
            lastAutomaticID += 1
        } while loadedIDs.contains(String(lastAutomaticID)) || indexByID[String(lastAutomaticID)] != nil
        return lastAutomaticID
    }

    /// Nil for an object with no slot or no parent.
    public func parentID(of id: String) -> String? {
        indexByID[id].flatMap { parents[$0] }.map { ids[$0] }
    }

    /// 1401de750 without adjustTransforms or an attachment. False for a dead or unknown object or parent, and
    /// for a parent that is the object or below it, which leaves the object parentless.
    @discardableResult
    public mutating func setParent(_ id: String, to parentID: String?) -> Bool {
        guard let index = index(of: id) else { return false }
        var parent: Int?
        if let parentID {
            guard let resolved = self.index(of: parentID) else { return false }
            parent = resolved
        }
        guard parents[index] != parent else { return true }
        // WPE rejects only itself; a cycle is rejected too because the frame builder would recurse through it.
        var ancestor = parent
        var steps = 0
        while let current = ancestor, steps <= objects.count {
            if current == index {
                parent = nil
                break
            }
            ancestor = parents[current]
            steps += 1
        }
        let accepted = parent != nil || parentID == nil
        guard parents[index] != parent else { return accepted }
        parents[index] = parent
        membershipGeneration += 1
        transformGeneration += 1
        visibilityGeneration += 1
        return accepted
    }

    /// Appends one already parsed, admitted ModelData layer to a private candidate; all previous slots, values
    /// and retirements survive. The existing Engine transaction publishes the candidate and config together.
    /// Automatic identity, parent/placement/effect resources remain explicit product admission boundaries.
    public mutating func appendModelDataLayer(_ descriptor: WPESceneModelDataObject) throws {
        guard let number = UInt32(descriptor.id), number > 0, String(number) == descriptor.id else {
            throw WPEParityModelDataFailure.safety("dynamic model layer requires an explicit positive UInt32 id")
        }
        guard indexByID[descriptor.id] == nil else {
            throw WPEParityModelDataFailure.safety("dynamic model layer reuses a reserved stable id")
        }
        guard descriptor.parentObjectID == nil else {
            throw WPEParityModelDataFailure.safety("dynamic ModelData parent adoption is not qualified")
        }
        guard var model = modelDataValues[descriptor.modelDataToken] else { throw WPEParityModelDataFailure.native(4) }
        guard model.references < UInt32.max else { throw WPEParityModelDataFailure.safety("reference count overflow") }
        let object = Object(origin: SIMD3(descriptor.localOrigin), scale: SIMD3(descriptor.localScale),
                            angles: SIMD3(descriptor.localAngles), alpha: 1, color: .one, brightness: 1,
                            visible: descriptor.visible, modelDataToken: descriptor.modelDataToken)
        model.references += 1
        modelDataValues[descriptor.modelDataToken] = model
        indexByID[descriptor.id] = ids.count
        ids.append(descriptor.id)
        objects.append(object)
        parents.append(nil)
        commonOrder.append(descriptor.id)
        membershipGeneration += 1
        transformGeneration += 1
        visibilityGeneration += 1
    }

    /// Called only after the existing layer transaction admits its referencing model layer.
    public mutating func retainModelData(_ token: UInt32, for objectID: String) throws {
        guard let index = index(of: objectID), objects[index].modelDataToken == nil,
              var model = modelDataValues[token] else { throw WPEParityModelDataFailure.native(4) }
        guard model.references < UInt32.max else { throw WPEParityModelDataFailure.safety("reference count overflow") }
        model.references += 1
        modelDataValues[token] = model
        objects[index].modelDataToken = token
    }

    /// The actual class destructor/last-reader owner chooses this boundary; common removal alone does not.
    public mutating func releaseLayerModelData(_ objectID: String) {
        guard let index = indexByID[objectID], let token = objects[index].modelDataToken else { return }
        objects[index].modelDataToken = nil
        releaseModelData(token)
    }

    /// The layer ctor seeds alpha 1 and only an authored "alpha" changes it (1401e6980.c:40); shape quads stay as parsed.
    static func nativeAlpha(_ image: WPESceneImageObject, authored: WPESceneJSONValue?) -> Float {
        authored != nil && authored?["alpha"] == nil && !image.isShapeQuad ? 1 : Float(image.alpha)
    }

    /// Objects with a transform (image layers, groups, particles) start from the values the frame plan bakes; any other
    /// object the parent chain names holds only its visible bit. `constants` seeds each material pass.
    public init(document: WPESceneDocument, hdr: Bool, constants: [WPEParityMaterialPassKey: [String: [Double]]] = [:],
                transparentMembers: Set<String> = [], fullscreenMembers: Set<String> = []) {
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
        let authored = Dictionary(document.resolvedObjectsJSON.compactMap { object in
            WPEParitySceneAnimations.id(object).map { ($0, object) }
        }) { first, _ in first }
        lightIDs = Set(lights.keys)
        for layer in WPEParityLayerTransform.layers(document: document)
            + WPEParityLayerTransform.textLayers(document: document) {
            var object = Object(origin: layer.origin, scale: layer.scale, angles: layer.angles, alpha: 1, color: .one,
                                brightness: 1, visible: document.ownVisibilityByID[layer.id] ?? true)
            if let image = images[layer.id] {
                (object.alpha, object.color, object.brightness) = (
                    Self.nativeAlpha(image, authored: authored[layer.id]), SIMD3(image.color), Float(image.brightness)
                )
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
        loadedIDs = Set(document.resolvedObjectsJSON.compactMap(WPEParitySceneAnimations.id))
        var commonIDs: Set<String> = []
        commonOrder = document.resolvedObjectsJSON.compactMap { object in
            guard let id = WPEParitySceneAnimations.id(object), indexByID[id] != nil,
                  commonIDs.insert(id).inserted else { return nil }
            return id
        }
        // 14018ff60.c:347-349: members join the vector as they are created.
        transparentOrder = commonOrder.filter(transparentMembers.contains)
        self.transparentMembers = transparentMembers
        self.fullscreenMembers = fullscreenMembers
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
        transparentOrder.removeAll { $0 == id }
        scriptFields = scriptFields.filter { $0.key.objectID != id }
        membershipGeneration += 1
        return true
    }

    /// 1401865c0 keys each member by its own local origin, unparented; 14019ee60 moves one only past a strictly
    /// smaller key, so ties keep the previous order. A changed order is a membership change.
    public mutating func sortTransparentMembers(viewForward f: SIMD3<Float>) {
        let keys = transparentOrder.map { id -> Float in
            guard !fullscreenMembers.contains(id) else { return -.infinity }
            let o = indexByID[id].map { objects[$0].origin } ?? .zero
            // This summation order, unfused (0x1401865c0 asm :58-69).
            return (o.y * f.y + o.x * f.x) + o.z * f.z
        }
        let order = transparentOrder.indices.sorted { keys[$0] > keys[$1] }.map { transparentOrder[$0] }
        guard order != transparentOrder else { return }
        transparentOrder = order
        membershipGeneration += 1
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

    /// The object's own bit ANDed with every ancestor's.
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

    /// g_Color4 of the object's albedo draws: colour × (HDR ? brightness : 1), alpha.
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
