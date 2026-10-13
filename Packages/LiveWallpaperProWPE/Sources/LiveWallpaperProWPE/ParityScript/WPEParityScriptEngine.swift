import Foundation
import JavaScriptCore

/// One scene's SceneScript engine (R25 §1): a JSContext with WPE's baseclasses.js, every property script of the
/// scene compiled as a module in binding order, and the host objects. Confined to its owner's thread.
public final class WPEParityScriptEngine {
    public enum Failure: Error, Equatable {
        case missingBaseClasses
    }

    public struct ConstantKey: Hashable, Sendable {
        public var pass: WPEParityMaterialPassKey
        public var name: String

        public init(pass: WPEParityMaterialPassKey, name: String) {
            self.pass = pass
            self.name = name
        }
    }

    public struct Configuration {
        /// Scene files first, then WPE's `assets`; modules and baseclasses.js load through it.
        public var assets: WPEParityProgramAssets
        public var canvasSize: SIMD2<Float>
        public var screenResolution: SIMD2<Float>
        /// project.json `properties`: `{key: {type, value}}`, merged with the user's values.
        public var userPropertiesJSON: String
        /// Constants whose shader annotation sets the angle flag (constant flags +0xac bit 0x20).
        public var angleConstants: Set<ConstantKey>
        /// Level 0 log, 1 warn, 2 error.
        public var log: (Int, String) -> Void
        public var openUserShortcut: (String) -> Bool

        public init(assets: WPEParityProgramAssets, canvasSize: SIMD2<Float>, screenResolution: SIMD2<Float>,
                    userPropertiesJSON: String = "{}", angleConstants: Set<ConstantKey> = [],
                    log: @escaping (Int, String) -> Void = { _, _ in },
                    openUserShortcut: @escaping (String) -> Bool = { _ in false }) {
            self.assets = assets
            self.canvasSize = canvasSize
            self.screenResolution = screenResolution
            self.userPropertiesJSON = userPropertiesJSON
            self.angleConstants = angleConstants
            self.log = log
            self.openUserShortcut = openUserShortcut
        }
    }

    public struct Input: Sendable {
        public var cursorScreen: SIMD2<Float>
        public var cursorWorld: SIMD3<Float>
        public var leftDown: Bool
        /// Fraction of the day.
        public var timeOfDay: Float

        public init(cursorScreen: SIMD2<Float> = .zero, cursorWorld: SIMD3<Float> = .zero, leftDown: Bool = false,
                    timeOfDay: Float = 0) {
            self.cursorScreen = cursorScreen
            self.cursorWorld = cursorWorld
            self.leftDown = leftDown
            self.timeOfDay = timeOfDay
        }
    }

    /// A property script in binding order. A failed compile keeps its place with no exports (140175880.c:366-382).
    public struct Binding: Sendable {
        public let objectID: String
        /// The property's path under the object, such as `origin` or `effects/0/passes/0/constantshadervalues/k`.
        public let path: String
        /// WPE's compile name, "class_property".
        public let name: String
        public let compiled: Bool
        public let exportBits: Int
        fileprivate let script: Int
        fileprivate let userKeys: [String: [String]]
    }

    public struct CreatedLayer: Sendable {
        public let id: String
        public let configJSON: String
    }

    private struct Slot {
        var layer: Int32
        var descriptor: Int32
        var effect: Int32 = -1
        var pass: Int32 = -1
    }

    private enum Refresh {
        case object(slot: Int, state: Int, WPEParitySceneState.Property)
        case effect(slot: Int, state: Int)
        case constant(slot: Int, pass: Int, name: String)
    }

    private struct Layer {
        let id: String
        let kind: WPEParityScriptLayerKind
        let base: Int
        let stateIndex: Int?
        let config: WPESceneJSONValue
    }

    /// Exceeding it resets the script clock to 0 (DAT_14049296c, 14017fa70.c:216-223).
    public static let runtimeWrap: Float = 432_000

    public private(set) var bindings: [Binding] = []
    public private(set) var frame: UInt64 = 0
    public private(set) var frametime: Float = 0
    public private(set) var runtime: Float = 0
    public private(set) var exceptionCount = 0
    /// The first 32 exception messages.
    public private(set) var exceptions: [String] = []
    public private(set) var destroyedObjectIDs: [String] = []
    public private(set) var createdLayers: [CreatedLayer] = []
    public private(set) var started = false

    private let context: JSContext
    private let configuration: Configuration
    private var host: JSValue!
    private var tickFunction: JSValue!
    private var floats: UnsafeMutablePointer<Float>
    private var dirtyFlags: UnsafeMutablePointer<UInt8>
    private var dirty: UnsafeMutablePointer<Int32>
    private var capacity: Int
    private let globals: UnsafeMutablePointer<Float>
    private let audio: UnsafeMutablePointer<Float>
    private var slots: [Slot] = []
    private var descriptors: [WPEParityScriptProperty] = []
    private var descriptorIndex: [WPEParityScriptProperty: Int] = [:]
    private var layers: [Layer] = []
    private var refresh: [Refresh] = []
    private var effectKeys: [WPEParitySceneState.EffectKey] = []
    private var sceneBase = 0
    private var clock: Double = 0
    private var wasDown = false
    private var dispatchCounts = [Int](repeating: 0, count: WPEParityScriptEvent.allCases.count)
    private let sourceObjects: [WPESceneJSONValue]

    /// Compiles every property script of `document`; `start` runs their `init`.
    public init(document: WPESceneDocument, state: WPEParitySceneState, configuration: Configuration) throws {
        self.configuration = configuration
        context = JSContext()
        sourceObjects = WPEParityProgramScene.array(document.sourceJSON["objects"])
        capacity = 0
        floats = .allocate(capacity: 1)
        dirtyFlags = .allocate(capacity: 1)
        dirty = .allocate(capacity: 1)
        globals = .allocate(capacity: 16)
        globals.initialize(repeating: 0, count: 16)
        (globals[3], globals[4]) = (configuration.canvasSize.x, configuration.canvasSize.y)
        (globals[5], globals[6]) = (configuration.screenResolution.x, configuration.screenResolution.y)
        audio = .allocate(capacity: 336)
        audio.initialize(repeating: 0, count: 336)
        guard let baseClasses = configuration.assets.data("scripts/jsclasses/baseclasses.js") else {
            throw Failure.missingBaseClasses
        }
        context.exceptionHandler = { [weak self] _, exception in
            self?.record(exception?.toString() ?? "")
        }
        context.evaluateScript(String(bytes: baseClasses, encoding: .utf8) ?? "",
                               withSourceURL: URL(string: "scripts/jsclasses/baseclasses.js"))
        layout(document: document, state: state)
        installHost(document: document)
        compileBindings(document: document, state: state)
    }

    deinit {
        context.exceptionHandler = nil
        globals.deallocate()
        audio.deallocate()
    }

    public func dispatchCount(_ event: WPEParityScriptEvent) -> Int {
        dispatchCounts[event.rawValue]
    }

    /// The `left`, `right` and `average` bins registerAudioBuffers(resolution) hands out, contiguous; nil for any
    /// resolution but 16, 32 and 64 (R25 §4).
    public func audioBuffer(resolution: Int) -> UnsafeMutableBufferPointer<Float>? {
        let start: Int
        switch resolution {
        case 16: start = 0
        case 32: start = 48
        case 64: start = 144
        default: return nil
        }
        return UnsafeMutableBufferPointer(start: audio + start, count: 3 * resolution)
    }

    /// Event 0 to every binding that exports `init`, once, after all objects loaded (140186c90.c:689-738).
    public func start(state: inout WPEParitySceneState) {
        guard !started else { return }
        started = true
        run(state: &state) {
            count(.initialize)
            host.invokeMethod("init", withArguments: [0])
        }
    }

    /// One frame of the manager tick's script step (140171440.c:888-896): timers, then event 1 in binding order.
    /// Animations and media events of the frame must already be in `state`.
    public func tick(dt: Float, input: Input = Input(), state: inout WPEParitySceneState) {
        frame &+= 1
        frametime = dt
        clock += Double(dt)
        runtime = Float(clock)
        if runtime > Self.runtimeWrap {
            clock = 0
            runtime = 0
        }
        globals[0] = dt
        globals[1] = runtime
        globals[14] = dt * 1000
        write(input)
        run(state: &state) {
            count(.update)
            var exception: JSValueRef?
            JSObjectCallAsFunction(context.jsGlobalContextRef, tickFunction.jsValueRef, nil, 0, nil, &exception)
            if let exception {
                record(JSValue(jsValueRef: exception, in: context).toString())
            }
        }
    }

    /// The cursor pass's events of this frame, sent before `tick` (14017fa70.c:473-476). A left press opens the
    /// openUserShortcut gate for the click it starts; the release closes it after the pass (140189e10.c:102-105).
    public func cursor(_ dispatches: [WPEParityCursorTracker.Dispatch], input: Input,
                       state: inout WPEParitySceneState) {
        write(input)
        if input.leftDown, !wasDown {
            globals[13] = 1
        }
        let payload = "{\"world\":[\(input.cursorWorld.x),\(input.cursorWorld.y),\(input.cursorWorld.z)],"
            + "\"local\":[\(input.cursorWorld.x),\(input.cursorWorld.y),\(input.cursorWorld.z)],\"hitBox\":null}"
        run(state: &state) {
            for dispatch in dispatches {
                guard let target = layers.firstIndex(where: { $0.id == dispatch.id }) else { continue }
                count(dispatch.event)
                host.invokeMethod("dispatch", withArguments: [dispatch.event.rawValue, target, payload])
            }
        }
        if !input.leftDown, wasDown {
            globals[13] = 0
        }
        wasDown = input.leftDown
    }

    /// Any other event with its payload JSON: media fields, `[w, h]` for resizeScreen, `{"event":…,"value":…}` for
    /// animation events. `target` limits it to one object's bindings.
    public func dispatch(_ event: WPEParityScriptEvent, payloadJSON: String?, target: String? = nil,
                         state: inout WPEParitySceneState) {
        let index = target.flatMap { id in layers.firstIndex { $0.id == id } } ?? -1
        run(state: &state) {
            count(event)
            host.invokeMethod("dispatch", withArguments: [event.rawValue, index, payloadJSON ?? NSNull()])
        }
    }

    /// The user-property path after the descriptor bindings (1401731d0.c:238-840): engine.userProperties takes
    /// `mergedJSON`, bound scriptproperties take the changed values, then event 4 carries `changedJSON`.
    public func applyUserProperties(changedJSON: String, mergedJSON: String, state: inout WPEParitySceneState) {
        let changed = (try? JSONSerialization.jsonObject(with: Data(changedJSON.utf8))) as? [String: Any] ?? [:]
        run(state: &state) {
            host.invokeMethod("setUserProperties", withArguments: [mergedJSON])
            for binding in bindings where binding.script >= 0 {
                var vars: [String: Any] = [:]
                for (key, names) in binding.userKeys {
                    guard let value = (changed[key] as? [String: Any])?["value"] else { continue }
                    for name in names {
                        vars[name] = value
                    }
                }
                guard !vars.isEmpty, let data = try? JSONSerialization.data(withJSONObject: vars) else { continue }
                host.invokeMethod("applyScriptProperties",
                                  withArguments: [binding.script, String(bytes: data, encoding: .utf8) ?? "{}"])
            }
            count(.applyUserProperties)
            host.invokeMethod("dispatch", withArguments: [WPEParityScriptEvent.applyUserProperties.rawValue, -1,
                                                          changedJSON])
        }
    }

    /// Event 3 to every binding, which then stops (140176f70.c:400-426).
    public func destroy(state: inout WPEParitySceneState) {
        run(state: &state) {
            count(.destroy)
            host.invokeMethod("destroyAll", withArguments: [])
        }
    }

    // MARK: Frame plumbing

    private func count(_ event: WPEParityScriptEvent) {
        dispatchCounts[event.rawValue] += 1
    }

    private func record(_ message: String) {
        exceptionCount += 1
        if exceptions.count < 32 {
            exceptions.append(message)
        }
        configuration.log(2, message)
    }

    private func write(_ input: Input) {
        globals[2] = input.timeOfDay
        globals[7] = input.cursorScreen.x
        globals[8] = input.cursorScreen.y
        globals[9] = input.cursorWorld.x
        globals[10] = input.cursorWorld.y
        globals[11] = input.cursorWorld.z
        globals[12] = input.leftDown ? 1 : 0
    }

    /// Mirrors the state into the slots, runs `body`, and applies every slot it wrote.
    private func run(state: inout WPEParitySceneState, _ body: () -> Void) {
        for entry in refresh {
            switch entry {
            case let .object(slot, index, property):
                let object = state.objects[index]
                let value: SIMD4<Float> = switch property {
                case .origin: SIMD4(object.origin, 0)
                case .scale: SIMD4(object.scale, 0)
                case .angles: SIMD4(object.angles, 0)
                case .alpha: SIMD4(object.alpha, 0, 0, 0)
                case .color: SIMD4(object.color, 0)
                case .brightness: SIMD4(object.brightness, 0, 0, 0)
                case .visible: SIMD4(object.visible ? 1 : 0, 0, 0, 0)
                }
                store(value, at: slot)
            case let .effect(slot, index):
                floats[slot * 4] = state.effectVisibility[index] ? 1 : 0
            case let .constant(slot, pass, name):
                if let constant = state.constants(pass: pass)[name] {
                    store(constant.value, at: slot)
                }
            }
        }
        body()
        let count = Int(dirty[0])
        guard count > 0 else { return }
        for entry in 1 ... count {
            let slot = Int(dirty[entry])
            dirtyFlags[slot] = 0
            apply(slot: slot, to: &state)
        }
        dirty[0] = 0
    }

    private func store(_ value: SIMD4<Float>, at slot: Int) {
        let base = floats + slot * 4
        base[0] = value.x
        base[1] = value.y
        base[2] = value.z
        base[3] = value.w
    }

    private func apply(slot index: Int, to state: inout WPEParitySceneState) {
        let slot = slots[index]
        let descriptor = descriptors[Int(slot.descriptor)]
        let base = floats + index * 4
        let value = SIMD4(base[0], base[1], base[2], base[3])
        let layer = slot.layer >= 0 ? layers[Int(slot.layer)] : nil
        switch descriptor.target {
        case let .object(property):
            if let stateIndex = layer?.stateIndex {
                state.set(property, at: stateIndex, to: value)
            }
        case .effectVisible:
            if slot.effect >= 0 {
                let key = effectKeys[Int(slot.effect)]
                state.setEffect(key.effectID, of: key.objectID, visible: value.x != 0)
            }
        case .constant:
            if slot.pass >= 0 {
                state.setConstant(descriptor.name, pass: Int(slot.pass),
                                  to: WPEParitySceneState.Constant(value: value,
                                                                   count: descriptor.type.componentCount))
            }
        case .field:
            let stored: WPEParitySceneState.ScriptValue = descriptor.type == .string
                ? .string(host.invokeMethod("getString", withArguments: [index]).toString()) : .vector(value)
            state.setScriptField(descriptor.fieldName, of: layer?.id ?? "", to: stored,
                                 invalidating: descriptor.invalidation)
        }
    }

    // MARK: Layout

    private func index(of descriptor: WPEParityScriptProperty) -> Int32 {
        if let index = descriptorIndex[descriptor] {
            return Int32(index)
        }
        descriptorIndex[descriptor] = descriptors.count
        descriptors.append(descriptor)
        return Int32(descriptors.count - 1)
    }

    private static func fields(_ kind: WPEParityScriptLayerKind) -> [WPEParityScriptProperty] {
        WPEParityScriptProperty.layer(kind) + (kind == .image ? WPEParityScriptProperty.video : [])
    }

    private static func kind(of id: String, object: WPESceneJSONValue,
                             document: WPESceneDocument) -> WPEParityScriptLayerKind {
        // 14018ff60.c:116-118: a string `camera` member makes the object a camera.
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
        return .group
    }

    private var initialValues: [(slot: Int, value: WPEParitySceneState.ScriptValue)] = []

    private func layout(document: WPESceneDocument, state: WPEParitySceneState) {
        for object in document.resolvedObjectsJSON {
            guard let id = WPEParitySceneAnimations.id(object) else { continue }
            addLayer(id: id, kind: Self.kind(of: id, object: object, document: document), config: object, state: state)
        }
        sceneBase = slots.count
        for descriptor in WPEParityScriptProperty.scene {
            let slot = slots.count
            slots.append(Slot(layer: -1, descriptor: index(of: descriptor)))
            if let value = Self.parse(document.resolvedGeneralJSON[descriptor.name.lowercased()], descriptor) {
                initialValues.append((slot, value))
            }
        }
        grow(to: slots.count + 256)
        for (slot, value) in initialValues {
            if case let .vector(vector) = value {
                store(vector, at: slot)
            }
        }
    }

    @discardableResult
    private func addLayer(id: String, kind: WPEParityScriptLayerKind, config: WPESceneJSONValue,
                          state: WPEParitySceneState?) -> Int {
        let layerIndex = Int32(layers.count)
        let base = slots.count
        let stateIndex = state?.index(of: id)
        layers.append(Layer(id: id, kind: kind, base: base, stateIndex: stateIndex, config: config))
        for descriptor in Self.fields(kind) {
            let slot = slots.count
            slots.append(Slot(layer: layerIndex, descriptor: index(of: descriptor)))
            if case let .object(property) = descriptor.target, let stateIndex {
                refresh.append(.object(slot: slot, state: stateIndex, property))
                continue
            }
            let raw: WPESceneJSONValue? = switch descriptor.owner {
            case .particleInstance: config["instanceoverride"]?[descriptor.name]
            case .video: nil
            default: config[descriptor.name]
            }
            if let value = Self.parse(raw, descriptor) ?? Self.fallback(descriptor) {
                initialValues.append((slot, value))
            }
        }
        guard let state else { return Int(layerIndex) }
        for effect in WPEParityProgramScene.array(config["effects"]) {
            guard let effectID = WPEParitySceneAnimations.id(effect) else { continue }
            let slot = slots.count
            var entry = Slot(layer: layerIndex, descriptor: index(of: WPEParityScriptProperty.effectVisible))
            if let effectIndex = state.effects.firstIndex(of: .init(objectID: id, effectID: effectID)) {
                entry.effect = Int32(effectKeys.count)
                effectKeys.append(state.effects[effectIndex])
                refresh.append(.effect(slot: slot, state: effectIndex))
            }
            slots.append(entry)
            effectSlots[Int(layerIndex), default: []].append((effectID, slot))
            for (pass, values) in WPEParityProgramScene.array(effect["passes"]).enumerated() {
                addConstants(values["constantshadervalues"], layer: layerIndex,
                             pass: WPEParityMaterialPassKey(objectID: id, effectID: effectID, pass: pass), state: state)
            }
        }
        addConstants(config["instance"]?["constantshadervalues"], layer: layerIndex,
                     pass: WPEParityMaterialPassKey(objectID: id), state: state)
        return Int(layerIndex)
    }

    private var constantSlots: [WPEParityMaterialPassKey: [String: Int]] = [:]
    /// Each layer's effect visible slots in effect order.
    private var effectSlots: [Int: [(id: String, slot: Int)]] = [:]

    private func addConstants(_ values: WPESceneJSONValue?, layer: Int32, pass key: WPEParityMaterialPassKey,
                              state: WPEParitySceneState) {
        guard case let .object(entries)? = values else { return }
        let passIndex = state.passIndex(of: key)
        for (name, raw) in entries.sorted(by: { $0.key < $1.key }) {
            let components = state.constant(name, of: key)?.count ?? Self.components(raw["value"] ?? raw).count
            let angle = configuration.angleConstants.contains(ConstantKey(pass: key, name: name))
            guard let descriptor = WPEParityScriptProperty.material(name: name, components: components, angle: angle)
            else { continue }
            let slot = slots.count
            slots.append(Slot(layer: layer, descriptor: index(of: descriptor), pass: Int32(passIndex ?? -1)))
            constantSlots[key, default: [:]][name] = slot
            if let passIndex {
                refresh.append(.constant(slot: slot, pass: passIndex, name: name))
            } else {
                initialValues.append((slot, .vector(Self.vector(Self.components(raw["value"] ?? raw)))))
            }
        }
    }

    private func grow(to count: Int) {
        guard count > capacity else { return }
        let newCapacity = max(count, capacity * 2)
        let newFloats = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity * 4)
        newFloats.initialize(repeating: 0, count: newCapacity * 4)
        let newFlags = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newFlags.initialize(repeating: 0, count: newCapacity)
        let newDirty = UnsafeMutablePointer<Int32>.allocate(capacity: newCapacity + 1)
        newDirty.initialize(repeating: 0, count: newCapacity + 1)
        if capacity > 0 {
            newFloats.update(from: floats, count: capacity * 4)
            newFlags.update(from: dirtyFlags, count: capacity)
            newDirty.update(from: dirty, count: capacity + 1)
        } else {
            floats.deallocate()
            dirtyFlags.deallocate()
            dirty.deallocate()
        }
        // The old buffers belong to their typed arrays, which free them when collected.
        (floats, dirtyFlags, dirty, capacity) = (newFloats, newFlags, newDirty, newCapacity)
        guard host != nil else { return }
        host.invokeMethod("rebind", withArguments: [typedArray(.float32, floats, newCapacity * 16),
                                                    typedArray(.uint8, dirtyFlags, newCapacity),
                                                    typedArray(.int32, dirty, (newCapacity + 1) * 4)])
    }

    private enum ArrayType {
        case float32, uint8, int32
    }

    /// A typed array over `bytes`; `owned` arrays free their bytes when collected.
    private func typedArray(_ type: ArrayType, _ bytes: UnsafeMutableRawPointer, _ length: Int,
                            owned: Bool = true) -> JSValue {
        let kind: JSTypedArrayType = switch type {
        case .float32: kJSTypedArrayTypeFloat32Array
        case .uint8: kJSTypedArrayTypeUint8Array
        case .int32: kJSTypedArrayTypeInt32Array
        }
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef, kind, bytes, length, owned ? { bytes, _ in bytes?.deallocate() } : nil, nil,
            &exception
        )
        return JSValue(jsValueRef: array, in: context)
    }

    // MARK: Host

    private func installHost(document _: WPESceneDocument) {
        let host = JSValue(newObjectIn: context)!
        func set(_ key: String, _ value: Any) {
            host.setObject(value, forKeyedSubscript: key as NSString)
        }
        set("floats", typedArray(.float32, floats, capacity * 16))
        set("dirtyFlags", typedArray(.uint8, dirtyFlags, capacity))
        set("dirty", typedArray(.int32, dirty, (capacity + 1) * 4))
        set("globals", typedArray(.float32, globals, 64, owned: false))
        set("audio", typedArray(.float32, audio, 336 * 4, owned: false))
        set("eventNames", WPEParityScriptEvent.allCases.map { $0.functionName ?? NSNull() as Any })
        set("kinds", WPEParityScriptLayerKind.allCases.map { kind in
            Self.fields(kind).enumerated().map { rel, field in Self.fieldInfo(field, rel: rel) }
        })
        set("sceneFields", WPEParityScriptProperty.scene.enumerated().map { rel, field in
            Self.fieldInfo(field, rel: rel)
        })
        set("sceneBase", sceneBase)
        let resolve: @convention(block) (String, String) -> String = { specifier, importer in
            WPEParityScriptModule.resolve(specifier, importer: importer)
        }
        let load: @convention(block) (String) -> JSValue? = { [weak self] path in
            guard let self, let data = configuration.assets.data(path) else { return nil }
            return context.evaluateScript(WPEParityScriptModule.lower(String(bytes: data, encoding: .utf8) ?? ""),
                                          withSourceURL: URL(string: path))
        }
        let error: @convention(block) (String, String) -> Void = { [weak self] name, message in
            self?.record(name.isEmpty ? message : "\(name): \(message)")
        }
        let log: @convention(block) (Double, String) -> Void = { [weak self] level, message in
            self?.configuration.log(Int(level), message)
        }
        let shortcut: @convention(block) (String) -> Bool = { [weak self] name in
            self?.configuration.openUserShortcut(name) ?? false
        }
        let destroyed: @convention(block) (Double) -> Void = { [weak self] index in
            guard let self else { return }
            destroyedObjectIDs.append(layers[Int(index)].id)
        }
        let initialConfig: @convention(block) (Double) -> String? = { [weak self] index in
            guard let self, case var .object(entries) = layers[Int(index)].config else { return nil }
            entries["id"] = nil
            return Self.jsonText(.object(entries))
        }
        let create: @convention(block) (String) -> Double = { [weak self] json in
            self?.createLayer(json: json) ?? -1
        }
        set("resolve", resolve)
        set("load", load)
        set("error", error)
        set("log", log)
        set("openUserShortcut", shortcut)
        set("destroyed", destroyed)
        set("initialConfig", initialConfig)
        set("createLayer", create)
        context.evaluateScript(WPEParityScriptPrelude.source, withSourceURL: URL(string: "parity-host.js"))
            .call(withArguments: [host])
        self.host = host
        tickFunction = host.forProperty("tick")
        for (index, layer) in layers.enumerated() {
            addHostLayer(index, layer)
        }
        for (slot, value) in initialValues {
            if case let .string(string) = value {
                host.invokeMethod("setString", withArguments: [slot, string])
            }
        }
        host.invokeMethod("setUserProperties", withArguments: [configuration.userPropertiesJSON])
    }

    private static func fieldInfo(_ field: WPEParityScriptProperty, rel: Int) -> [String: Any] {
        let owner = switch field.owner {
        case .particleInstance: "instance"
        case .video: "video"
        default: ""
        }
        return ["name": field.name, "type": field.type.rawValue, "angle": field.flags.contains(.angle),
                "rel": rel, "owner": owner]
    }

    private func addHostLayer(_ index: Int, _ layer: Layer) {
        let parent = WPEParityProgramScene.string(layer.config["parent"]).flatMap { id in
            layers.firstIndex { $0.id == id }
        } ?? (WPEParityProgramScene.number(layer.config["parent"]).flatMap { number in
            layers.firstIndex { $0.id == String(Int(number)) }
        } ?? -1)
        var effects: [[String: Any]] = []
        let effectJSON = WPEParityProgramScene.array(layer.config["effects"])
        for (effectID, slot) in effectSlots[index] ?? [] {
            guard let effect = effectJSON.first(where: { WPEParitySceneAnimations.id($0) == effectID }) else {
                continue
            }
            let passes = WPEParityProgramScene.array(effect["passes"]).indices.map { pass -> [String: Any] in
                let key = WPEParityMaterialPassKey(objectID: layer.id, effectID: effectID, pass: pass)
                var constants: [String: Any] = [:]
                for (name, constantSlot) in constantSlots[key] ?? [:] {
                    let descriptor = descriptors[Int(slots[constantSlot].descriptor)]
                    constants[name] = ["slot": constantSlot, "type": descriptor.type.rawValue,
                                       "angle": descriptor.flags.contains(.angle)]
                }
                return constants
            }
            effects.append(["slot": slot, "name": WPEParityProgramScene.string(effect["name"]) ?? effectID,
                            "passes": passes])
        }
        host.invokeMethod("addLayer", withArguments: [index, layer.kind.rawValue, layer.base, parent, effects])
    }

    private func createLayer(json: String) -> Double {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let config = WPESceneJSONValue(jsonValue: object) else { return -1 }
        let kind: WPEParityScriptLayerKind = config["text"] != nil ? .text
            : config["particle"] != nil ? .particle : config["sound"] != nil ? .sound : .image
        let id = "created-\(createdLayers.count + 1)"
        let start = initialValues.count
        let index = addLayer(id: id, kind: kind, config: config, state: nil)
        grow(to: slots.count)
        for (slot, value) in initialValues[start...] {
            switch value {
            case let .vector(vector): store(vector, at: slot)
            case let .string(string): host.invokeMethod("setString", withArguments: [slot, string])
            }
        }
        addHostLayer(index, layers[index])
        createdLayers.append(CreatedLayer(id: id, configJSON: json))
        return Double(index)
    }

    // MARK: Bindings

    private func compileBindings(document _: WPESceneDocument, state _: WPEParitySceneState) {
        for (layerIndex, layer) in layers.enumerated() {
            let source = sourceObjects.first { WPEParitySceneAnimations.id($0) == layer.id }
            for (rel, descriptor) in Self.fields(layer.kind).enumerated() {
                let path = descriptor.owner == .particleInstance ? "instanceoverride/\(descriptor.name)"
                    : descriptor.name
                guard descriptor.owner != .video else { continue }
                addBinding(layerIndex: layerIndex, path: path, slot: layer.base + rel, descriptor: descriptor,
                           className: "\(layer.kind)", source: source)
            }
            for (effectIndex, effect) in WPEParityProgramScene.array(layer.config["effects"]).enumerated() {
                guard let effectID = WPEParitySceneAnimations.id(effect) else { continue }
                if let slot = effectSlots[layerIndex]?.first(where: { $0.id == effectID })?.slot {
                    addBinding(layerIndex: layerIndex, path: "effects/\(effectIndex)/visible", slot: slot,
                               descriptor: WPEParityScriptProperty.effectVisible, className: "effect", source: source)
                }
                for pass in WPEParityProgramScene.array(effect["passes"]).indices {
                    let key = WPEParityMaterialPassKey(objectID: layer.id, effectID: effectID, pass: pass)
                    for (name, slot) in (constantSlots[key] ?? [:]).sorted(by: { $0.key < $1.key }) {
                        addBinding(layerIndex: layerIndex,
                                   path: "effects/\(effectIndex)/passes/\(pass)/constantshadervalues/\(name)",
                                   slot: slot, descriptor: descriptors[Int(slots[slot].descriptor)],
                                   className: "material", source: source)
                    }
                }
            }
            for (name, slot) in (constantSlots[WPEParityMaterialPassKey(objectID: layer.id)] ?? [:])
                .sorted(by: { $0.key < $1.key }) {
                addBinding(layerIndex: layerIndex, path: "instance/constantshadervalues/\(name)", slot: slot,
                           descriptor: descriptors[Int(slots[slot].descriptor)], className: "material",
                           source: source)
            }
        }
    }

    private func addBinding(layerIndex: Int, path: String, slot: Int, descriptor: WPEParityScriptProperty,
                            className: String, source: WPESceneJSONValue?) {
        let components = path.split(separator: "/").map(String.init)
        let resolved = components.reduce(Optional(layers[layerIndex].config)) { node, key in
            Int(key).flatMap { node?[$0] } ?? node?[key]
        }
        guard case let .string(script)? = resolved?["script"], !script.isEmpty else { return }
        let raw = components.reduce(source) { node, key in Int(key).flatMap { node?[$0] } ?? node?[key] }
        var userKeys: [String: [String]] = [:]
        if case let .object(entries)? = raw?["scriptproperties"] {
            for (name, entry) in entries {
                if let key = WPEParityProgramScene.string(entry["user"])
                    ?? WPEParityProgramScene.string(entry["user"]?["name"]) {
                    userKeys[key, default: []].append(name)
                }
            }
        }
        let name = "\(className)_\(components.last ?? path)"
        let vars = resolved?["scriptproperties"].map(Self.jsonText) ?? NSNull() as Any
        let before = exceptionCount
        let function = context.evaluateScript(WPEParityScriptModule.lower(script),
                                              withSourceURL: URL(string: "scripts/\(name).js"))
        var bits = -1
        var handle = -1
        if exceptionCount == before, let function, function.isObject {
            bits = Int(host.invokeMethod("addBinding", withArguments: [
                function, name, "scripts/\(name).js", layerIndex, slot, descriptor.type.rawValue,
                descriptor.flags.contains(.angle), vars,
            ]).toInt32())
            if bits >= 0 {
                handle = bindings.filter { $0.script >= 0 }.count
            }
        }
        bindings.append(Binding(objectID: layers[layerIndex].id, path: path, name: name, compiled: handle >= 0,
                                exportBits: max(bits, 0), script: handle, userKeys: userKeys))
    }

    // MARK: JSON

    private static func fallback(_ descriptor: WPEParityScriptProperty) -> WPEParitySceneState.ScriptValue? {
        switch (descriptor.owner, descriptor.type) {
        case (.particleInstance, .vec3): .vector(SIMD4(1, 1, 1, 0))
        case (.particleInstance, _): .vector(SIMD4(1, 0, 0, 0))
        case (_, .string): .string("")
        default: nil
        }
    }

    private static func parse(_ raw: WPESceneJSONValue?,
                              _ descriptor: WPEParityScriptProperty) -> WPEParitySceneState.ScriptValue? {
        guard var value = raw else { return nil }
        if case .object = value {
            guard let inner = value["value"] else { return nil }
            value = inner
        }
        if descriptor.type == .string {
            return WPEParityProgramScene.string(value).map { .string($0) }
        }
        let components = Self.components(value)
        return components.isEmpty ? nil : .vector(vector(components))
    }

    private static func components(_ value: WPESceneJSONValue) -> [Float] {
        switch value {
        case let .number(number): [Float(number)]
        case let .bool(flag): [flag ? 1 : 0]
        case let .string(text): text.split(separator: " ").compactMap { Float($0) }
        case let .object(entries): entries["value"].map(components) ?? []
        default: []
        }
    }

    private static func vector(_ components: [Float]) -> SIMD4<Float> {
        var vector = SIMD4<Float>.zero
        for (lane, component) in components.prefix(4).enumerated() {
            vector[lane] = component
        }
        return vector
    }

    static func jsonText(_ value: WPESceneJSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundation(value), options: [.fragmentsAllowed])
        else { return "null" }
        return String(bytes: data, encoding: .utf8) ?? "null"
    }

    private static func foundation(_ value: WPESceneJSONValue) -> Any {
        switch value {
        case let .object(entries): entries.mapValues(foundation)
        case let .array(values): values.map(foundation)
        case let .string(text): text
        case let .number(number): number
        case let .bool(flag): flag
        case .null: NSNull()
        }
    }
}
