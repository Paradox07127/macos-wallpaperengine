import Foundation
import JavaScriptCore

/// One scene's SceneScript engine (R25 §1): a JSContext with WPE's baseclasses.js, every property script of the
/// scene compiled as a module in binding order, and the host objects. Confined to its owner's thread.
public final class WPEParityScriptEngine {
    public enum Failure: Error, Equatable {
        case missingBaseClasses
        case registeredAssetsNotPrepared([String])
    }

    /// Native ISound methods; only isPlaying exposes the consumer's Bool to JavaScript.
    public enum SoundCommand: Int, Sendable {
        case play, stop, pause, isPlaying
    }

    /// A snapshot of the existing typed fields at this synchronous native-call boundary.
    public struct SoundFields: Sendable {
        public let volume: Float
        public let minTime: Float?
        public let maxTime: Float?

        public init(volume: Float, minTime: Float?, maxTime: Float?) {
            self.volume = volume
            self.minTime = minTime
            self.maxTime = maxTime
        }
    }

    public struct ConstantKey: Hashable, Sendable {
        public var pass: WPEParityMaterialPassKey
        public var name: String

        public init(pass: WPEParityMaterialPassKey, name: String) {
            self.pass = pass
            self.name = name
        }
    }

    /// The final shader material table, including constants absent from scene JSON. Values use native stored units.
    public struct MaterialConstant: Sendable {
        public var value: SIMD4<Float>
        public var components: Int
        public var angle: Bool

        public init(value: SIMD4<Float>, components: Int, angle: Bool = false) {
            self.value = value
            self.components = components
            self.angle = angle
        }
    }

    /// An optional product storage provider. The script bridge serializes on set and parses a new value on get.
    /// Its lifetime and screen/project identity are the provider's responsibility, not inferred by this engine.
    public struct Storage {
        public enum Location: Sendable { case global, screen }
        public var get: (String, Location) -> String?
        public var set: (String, String, Location) -> Void
        public var delete: (String, Location) -> Bool
        public var clear: (Location) -> Bool

        public init(get: @escaping (String, Location) -> String?,
                    set: @escaping (String, String, Location) -> Void,
                    delete: @escaping (String, Location) -> Bool, clear: @escaping (Location) -> Bool) {
            self.get = get
            self.set = set
            self.delete = delete
            self.clear = clear
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
        public var materialConstants: [ConstantKey: MaterialConstant]
        /// Resource records from the existing ProgramScene parser. Missing metadata does not imply zero native
        /// passes and must never be reconstructed from authored overrides or the constants a shader exposes.
        public var resolvedEffectRecords: [WPEParitySceneState.EffectKey: [WPEParityEffectPassRecord]]
        /// Native/parsed field seeds; scene fields have objectID "", video fields use "video.name".
        public var fieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue]
        /// Extend/replace registered descriptors by (owner, name), including computed flag-2 fields.
        public var propertyOverrides: [WPEParityScriptProperty]
        public var storage: Storage?
        public var modelData: WPEParityScriptModelDataProvider?
        /// Prepares value-state only. The engine validates the returned config/identity before committing the
        /// candidate; this callback must not publish external resource side effects. Product resource preparation
        /// and retirement are not connected by this optional hook.
        public var createLayer: ((String, inout WPEParitySceneState) -> CreatedLayer?)?
        /// Called at the deferred deletion phase, after that layer's destroy events.
        public var destroyLayer: ((String, inout WPEParitySceneState) -> Bool)?
        /// Product admission for classes whose resource consumer can currently remove them.
        public var canDestroyLayer: ((String, UInt32?) -> Bool)?
        public var sortLayer: ((String, Int, inout WPEParitySceneState) -> Bool)?
        /// Pauses the existing video consumer of this layer. The result is internal readiness, not a JS return.
        public var pauseVideoTexture: ((String) -> Bool)?
        /// Executes against the current renderer's material-function resources, including module-body calls.
        public var executeMaterialFunction: ((WPEParitySceneState.EffectKey, String) -> Void)?
        /// Level 0 log, 1 warn, 2 error.
        public var log: (Int, String) -> Void
        public var openUserShortcut: (String) -> Bool

        public init(assets: WPEParityProgramAssets, canvasSize: SIMD2<Float>, screenResolution: SIMD2<Float>,
                    userPropertiesJSON: String = "{}", angleConstants: Set<ConstantKey> = [],
                    materialConstants: [ConstantKey: MaterialConstant] = [:],
                    resolvedEffectRecords: [WPEParitySceneState.EffectKey: [WPEParityEffectPassRecord]] = [:],
                    fieldDefaults: [WPEParitySceneState.ScriptFieldKey: WPEParitySceneState.ScriptValue] = [:],
                    propertyOverrides: [WPEParityScriptProperty] = [], storage: Storage? = nil,
                    modelData: WPEParityScriptModelDataProvider? = nil,
                    createLayer: ((String, inout WPEParitySceneState) -> CreatedLayer?)? = nil,
                    destroyLayer: ((String, inout WPEParitySceneState) -> Bool)? = nil,
                    canDestroyLayer: ((String, UInt32?) -> Bool)? = nil,
                    sortLayer: ((String, Int, inout WPEParitySceneState) -> Bool)? = nil,
                    pauseVideoTexture: ((String) -> Bool)? = nil,
                    executeMaterialFunction: ((WPEParitySceneState.EffectKey, String) -> Void)? = nil,
                    log: @escaping (Int, String) -> Void = { _, _ in },
                    openUserShortcut: @escaping (String) -> Bool = { _ in false }) {
            self.assets = assets
            self.canvasSize = canvasSize
            self.screenResolution = screenResolution
            self.userPropertiesJSON = userPropertiesJSON
            self.angleConstants = angleConstants
            self.materialConstants = materialConstants
            self.resolvedEffectRecords = resolvedEffectRecords
            self.fieldDefaults = fieldDefaults
            self.propertyOverrides = propertyOverrides
            self.storage = storage
            self.modelData = modelData
            self.createLayer = createLayer
            self.destroyLayer = destroyLayer
            self.canDestroyLayer = canDestroyLayer
            self.sortLayer = sortLayer
            self.pauseVideoTexture = pauseVideoTexture
            self.executeMaterialFunction = executeMaterialFunction
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

    /// Actual binding identity, distinct from a reusable module filename shared by several objects.
    public struct AssetContext: Equatable, Sendable {
        public let bindingIndex: Int
        public let objectID: String
        public let propertyPath: String
        public let modulePath: String
        /// Temporary projection of the one Binding array, not an asset cache or additional owner.
        public let registeredAssets: [RegisteredAsset]
        public let assetsPrepared: Bool
    }

    public struct RegisteredAsset: Equatable, Sendable {
        public let path: String
        /// Strict native boolean byte. Its downstream meaning remains a separately verified loader contract.
        public let flag: Bool
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

        public var assetContext: AssetContext {
            AssetContext(bindingIndex: bindingIndex, objectID: objectID, propertyPath: path,
                         modulePath: "scripts/\(name).js", registeredAssets: registeredAssets, assetsPrepared: assetsPrepared)
        }

        fileprivate let bindingIndex: Int
        public fileprivate(set) var registeredAssets: [RegisteredAsset] = []
        fileprivate var assetsPrepared = true
        fileprivate let script: Int
        fileprivate let userKeys: [String: [String]]
    }

    public struct CreatedLayer: Sendable {
        public let id: String
        public let configJSON: String

        public init(id: String, configJSON: String) {
            self.id = id
            self.configJSON = configJSON
        }
    }

    private struct Slot {
        var layer: Int32
        var descriptor: Int32
        var effect: Int32 = -1
        var materialPass: WPEParityMaterialPassKey?
    }

    private enum Refresh {
        case object(slot: Int, objectID: String, WPEParitySceneState.Property)
        case effect(slot: Int, key: WPEParitySceneState.EffectKey)
        case constant(slot: Int, key: WPEParityMaterialPassKey, name: String)
        case field(slot: Int, objectID: String, name: String)
    }

    private struct Layer {
        let id: String
        let kind: WPEParityScriptLayerKind
        let base: Int
        let config: WPESceneJSONValue
        let hasVideo: Bool
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
    public private(set) var audioResolutions: Set<Int> = []
    /// Rebound when a renderer takes over this engine; accepted calls belong to that consumer's queue.
    public var materialFunctionHandler: ((WPEParitySceneState.EffectKey, String) -> Void)?

    /// Rebound with the current renderer's prepared artifacts before init and when a renderer takes over.
    public var modelDataAdmissionHandler: ((WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws
        -> (any WPEParityModelDataPreparedShape)?)?

    private let context: JSContext
    private let configuration: Configuration
    private var host: JSValue!
    private var tickFunction: JSValue!
    private var floats: UnsafeMutablePointer<Float>
    private var integers: UnsafeMutablePointer<Int32>
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
    private var clock: Float = 0
    private var preparedFrame = false
    private var wasDown = false
    private var dispatchCounts = [Int](repeating: 0, count: WPEParityScriptEvent.allCases.count)
    private let sourceObjects: [WPESceneJSONValue]
    private var activeState: UnsafeMutablePointer<WPEParitySceneState>?
    private var mirroredMembershipGeneration: Int?
    private var soundVolumeConsumer: ((String, SoundFields) -> Void)?
    private var soundCommandConsumer: ((String, SoundCommand, SoundFields) -> Bool)?

    /// Consumers may capture the actor's scene RNG only for this synchronous body. Nested scopes restore it.
    public func withSoundConsumers<Result>(volume: (String, SoundFields) -> Void,
                                           command: (String, SoundCommand, SoundFields) -> Bool,
                                           body: () throws -> Result) rethrows -> Result {
        try withoutActuallyEscaping(volume) { volume in
            try withoutActuallyEscaping(command) { command in
                let previousVolume = soundVolumeConsumer, previousCommand = soundCommandConsumer
                soundVolumeConsumer = volume
                soundCommandConsumer = command
                defer {
                    soundVolumeConsumer = previousVolume
                    soundCommandConsumer = previousCommand
                }
                return try body()
            }
        }
    }

    /// Compatibility entry point for callers without synchronous sound consumers.
    public convenience init(document: WPESceneDocument, state: WPEParitySceneState,
                            configuration: Configuration) throws {
        try self.init(layoutOf: document, state: state, configuration: configuration)
        mirror(state)
        compileBindings(document: document)
    }

    /// Constructs one VM/layout and compiles module globals against the caller's canonical mutable state.
    /// The caller next prepares registered assets, then scopes consumers around start/init and later events.
    public static func prepare(document: WPESceneDocument, state: inout WPEParitySceneState,
                               configuration: Configuration, volume: (String, SoundFields) -> Void,
                               command: (String, SoundCommand, SoundFields) -> Bool) throws -> WPEParityScriptEngine {
        let engine = try WPEParityScriptEngine(layoutOf: document, state: state, configuration: configuration)
        engine.withSoundConsumers(volume: volume, command: command) {
            engine.seedMissingFields(state: &state)
            engine.run(state: &state) {
                engine.compileBindings(document: document)
            }
        }
        return engine
    }

    /// Initializes the existing VM/metadata once; no authored module body executes before its caller's scope.
    private init(layoutOf document: WPESceneDocument, state: WPEParitySceneState, configuration: Configuration) throws {
        self.configuration = configuration
        materialFunctionHandler = configuration.executeMaterialFunction
        modelDataAdmissionHandler = configuration.modelData?.admitShape
        context = JSContext()
        sourceObjects = WPEParityProgramScene.array(document.sourceJSON["objects"])
        capacity = 0
        floats = .allocate(capacity: 1)
        integers = .allocate(capacity: 1)
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
        installHost(state: state)
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

    /// Runs the existing product loader once per unprepared binding. No VM or mutable State borrow spans await.
    /// The caller keeps this engine on its owning actor and validates its existing load generation before attach.
    public nonisolated(nonsending) func prepareRegisteredAssets(
        using prepare: (AssetContext, [RegisteredAsset]) async throws -> Void
    ) async throws {
        for index in bindings.indices where bindings[index].compiled && !bindings[index].assetsPrepared {
            try Task.checkCancellation()
            try await prepare(bindings[index].assetContext, bindings[index].registeredAssets)
            try Task.checkCancellation()
            bindings[index].assetsPrepared = true
        }
    }

    /// Event 0 to every binding that exports `init`, once, after all objects loaded (140186c90.c:689-738).
    @discardableResult
    public func start(state: inout WPEParitySceneState) -> Failure? {
        guard !started else { return nil }
        let pending = bindings.filter { $0.compiled && !$0.assetsPrepared }.flatMap { $0.registeredAssets.map(\.path) }
        guard pending.isEmpty else {
            configuration.log(2, "SceneScript dependencies were not prepared before init: \(pending.joined(separator: ", "))")
            return .registeredAssetsNotPrepared(pending)
        }
        started = true
        seedMissingFields(state: &state)
        run(state: &state) {
            count(.initialize)
            host.invokeMethod("init", withArguments: [0])
        }
        return nil
    }

    /// One frame of the manager tick's script step (140171440.c:888-896): timers, then event 1 in binding order.
    /// Animations and media events of the frame must already be in `state`.
    public func tick(dt: Float, input: Input = Input(), state: inout WPEParitySceneState) {
        if !preparedFrame {
            clock += dt
            if clock > Self.runtimeWrap {
                clock = 0
            }
            prepareFrame(frame: frame &+ 1, dt: dt, runtime: clock, input: input)
        }
        preparedFrame = false
        run(state: &state) {
            count(.update)
            var exception: JSValueRef?
            JSObjectCallAsFunction(context.jsGlobalContextRef, tickFunction.jsValueRef, nil, 0, nil, &exception)
            if let exception {
                record(JSValue(jsValueRef: exception, in: context).toString())
            }
        }
    }

    /// Inject the scene's frame clock and sampled input before cursor, media and animation events.
    /// The following tick consumes these values; its fallback dt/input apply only when no frame was prepared.
    public func prepareFrame(frame: UInt64, dt: Float, runtime: Float, input: Input) {
        self.frame = frame
        frametime = dt
        self.runtime = runtime
        clock = runtime
        globals[0] = dt
        globals[1] = runtime
        globals[14] = dt * 1000
        write(input)
        preparedFrame = true
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

    /// Any other event with its payload JSON: media fields, `[w, h]` for resizeScreen, and the authored event's
    /// JSON text for animationEvent (whose second argument is the current property). `target` limits the object.
    public func dispatch(_ event: WPEParityScriptEvent, payloadJSON: String?, target: String? = nil,
                         state: inout WPEParitySceneState) {
        let index = target.flatMap { id in layers.firstIndex { $0.id == id } } ?? -1
        run(state: &state) {
            count(event)
            host.invokeMethod("dispatch", withArguments: [event.rawValue, index, payloadJSON ?? NSNull()])
        }
    }

    /// Refresh both sizes before resizeScreen observes them; the payload is the screen size.
    public func resize(canvasSize: SIMD2<Float>, screenResolution: SIMD2<Float>,
                       state: inout WPEParitySceneState) {
        (globals[3], globals[4]) = (canvasSize.x, canvasSize.y)
        (globals[5], globals[6]) = (screenResolution.x, screenResolution.y)
        dispatch(.resizeScreen, payloadJSON: "[\(screenResolution.x),\(screenResolution.y)]", state: &state)
    }

    /// The user-property path after the descriptor bindings (1401731d0.c:238-840): engine.userProperties takes
    /// `mergedJSON`, bound scriptproperties take the changed values, then event 4 projects only typed entries.
    public func applyUserProperties(changedJSON: String, mergedJSON: String, state: inout WPEParitySceneState) {
        let changed = (try? JSONSerialization.jsonObject(with: Data(changedJSON.utf8))) as? [String: Any] ?? [:]
        // 1401731d0 requires both members. System thumbnail changes deliberately have only `value`;
        // they still reach the merged engine properties and bound observers before the media callback.
        let typed = changed.filter { _, entry in
            guard let property = entry as? [String: Any] else { return false }
            return property["value"] != nil && property["type"] != nil
        }
        let eventJSON = (try? JSONSerialization.data(withJSONObject: typed, options: .sortedKeys))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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
                                                          eventJSON])
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
        mirror(state)
        withUnsafeMutablePointer(to: &state) { pointer in
            let previous = activeState
            activeState = pointer
            defer { activeState = previous }
            body()
        }
        flushWrites(to: &state)
    }

    private func flushWrites(to state: inout WPEParitySceneState) {
        let count = Int(dirty[0])
        guard count > 0 else { return }
        for entry in 1 ... count {
            let slot = Int(dirty[entry])
            dirtyFlags[slot] = 0
            apply(slot: slot, to: &state)
        }
        dirty[0] = 0
    }

    private func mirror(_ state: WPEParitySceneState) {
        if mirroredMembershipGeneration != state.membershipGeneration {
            // A temporary projection of the existing wrapper slots; neither State nor Engine slots are reordered.
            let indices = Dictionary(layers.enumerated().map { ($0.element.id, $0.offset) }) { first, _ in first }
            host.invokeMethod("setCommonOrder", withArguments: [state.commonOrder.compactMap { indices[$0] }])
            mirroredMembershipGeneration = state.membershipGeneration
        }
        for entry in refresh {
            switch entry {
            case let .object(slot, objectID, property):
                if let value = state.value(property, of: objectID) {
                    store(value, at: slot)
                }
            case let .effect(slot, key):
                if let visible = state.isEffectVisible(key.effectID, of: key.objectID) {
                    floats[slot * 4] = visible ? 1 : 0
                }
            case let .constant(slot, key, name):
                if let constant = state.constant(name, of: key) {
                    store(constant.value, at: slot)
                }
            case let .field(slot, objectID, name):
                if let value = state.scriptField(name, of: objectID) {
                    store(value, at: slot)
                }
            }
        }
    }

    private func store(_ value: SIMD4<Float>, at slot: Int) {
        let base = floats + slot * 4
        base[0] = value.x
        base[1] = value.y
        base[2] = value.z
        base[3] = value.w
    }

    private func store(_ value: WPEParitySceneState.ScriptValue, at slot: Int) {
        switch value {
        case let .vector(vector): store(vector, at: slot)
        case let .integer(integer): integers[slot] = integer
        case let .string(string):
            if host != nil {
                let descriptor = descriptors[Int(slots[slot].descriptor)]
                let values: Any = descriptor.stringValues.map { $0 as Any } ?? NSNull()
                host.invokeMethod("setString", withArguments: [slot, string, values])
            }
        }
    }

    private func seedMissingFields(state: inout WPEParitySceneState, first: Int = 0) {
        for (slotIndex, value) in initialValues.dropFirst(first) {
            let slot = slots[slotIndex]
            let descriptor = descriptors[Int(slot.descriptor)]
            guard descriptor.target == .field else { continue }
            let objectID = slot.layer < 0 ? "" : layers[Int(slot.layer)].id
            guard state.scriptField(descriptor.fieldName, of: objectID) == nil else { continue }
            state.setScriptField(descriptor.fieldName, of: objectID, to: value, invalidating: descriptor.invalidation)
        }
    }

    private func apply(slot index: Int, to state: inout WPEParitySceneState) {
        let slot = slots[index]
        let descriptor = descriptors[Int(slot.descriptor)]
        let base = floats + index * 4
        let value = SIMD4(base[0], base[1], base[2], base[3])
        let layer = slot.layer >= 0 ? layers[Int(slot.layer)] : nil
        guard layer.map({ state.isAlive($0.id) }) ?? true else { return }
        switch descriptor.target {
        case let .object(property):
            if let id = layer?.id, let stateIndex = state.index(of: id) {
                state.set(property, at: stateIndex, to: value)
            }
        case .effectVisible:
            if slot.effect >= 0 {
                let key = effectKeys[Int(slot.effect)]
                state.setEffect(key.effectID, of: key.objectID, visible: value.x != 0)
            }
        case .constant:
            if let key = slot.materialPass {
                state.setConstant(descriptor.name, of: key,
                                  to: WPEParitySceneState.Constant(value: value,
                                                                   count: descriptor.type.componentCount))
            }
        case .field:
            let stored: WPEParitySceneState.ScriptValue = switch descriptor.type {
            case .string: .string(host.invokeMethod("getString", withArguments: [index]).toString())
            case .int: .integer(integers[index])
            default: .vector(value)
            }
            state.setScriptField(descriptor.fieldName, of: layer?.id ?? "", to: stored,
                                 invalidating: descriptor.invalidation)
        }
    }

    /// Uses this layer's existing descriptor layout, not a second sound/slot registry.
    private func soundFields(layer index: Int) -> SoundFields? {
        let layer = layers[index]
        guard layer.kind == .sound else { return nil }
        let fields = fields(layer.kind)
        func value(_ name: String) -> Float? {
            guard let relative = fields.firstIndex(where: {
                $0.owner == .sound && $0.name == name && $0.type == .float && $0.target == .field
            }) else { return nil }
            return floats[(layer.base + relative) * 4]
        }
        guard let volume = value("volume") else { return nil }
        return SoundFields(volume: volume, minTime: value("mintime"), maxTime: value("maxtime"))
    }

    private func soundVolumeWritten(slot value: Double) {
        guard let consume = soundVolumeConsumer, let slot = Self.checkedLayerIndex(value, count: slots.count),
              descriptors[Int(slots[slot].descriptor)].isSoundVolumeWrite,
              let layer = Self.checkedLayerIndex(Double(slots[slot].layer), count: layers.count),
              let state = activeState, state.pointee.isAlive(layers[layer].id) else { return }
        // The accepted setter already stored its Float, including equal writes. Prior writes must be visible
        // to the native hook, while this flush must not synthesize additional accepted-write events.
        flushWrites(to: &state.pointee)
        guard let fields = soundFields(layer: layer) else { return }
        consume(layers[layer].id, fields)
    }

    private func soundCommand(layer value: Double, command raw: Double) -> Bool {
        guard let layer = Self.checkedLayerIndex(value, count: layers.count), layers[layer].kind == .sound,
              let raw = Int(exactly: raw), let command = SoundCommand(rawValue: raw) else { return false }
        if let state = activeState {
            guard state.pointee.isAlive(layers[layer].id) else { return false }
            flushWrites(to: &state.pointee)
        }
        guard let consume = soundCommandConsumer, let fields = soundFields(layer: layer) else {
            configuration.log(1, "ISound methods are unsupported without a synchronous product sound consumer")
            return false
        }
        return consume(layers[layer].id, command, fields)
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

    private func registered(_ fields: [WPEParityScriptProperty]) -> [WPEParityScriptProperty] {
        fields.map { field in
            configuration.propertyOverrides.first { $0.owner == field.owner && $0.name == field.name } ?? field
        } + configuration.propertyOverrides.filter { override in
            fields.contains { $0.owner == override.owner } && !fields.contains { $0.owner == override.owner && $0.name == override.name }
        }
    }

    private func fields(_ kind: WPEParityScriptLayerKind) -> [WPEParityScriptProperty] {
        registered(WPEParityScriptProperty.layer(kind) + (kind == .image ? WPEParityScriptProperty.video : []))
    }

    private var sceneFields: [WPEParityScriptProperty] {
        registered(WPEParityScriptProperty.scene)
    }

    private static func kind(of id: String, object: WPESceneJSONValue,
                             document: WPESceneDocument) -> WPEParityScriptLayerKind {
        WPEParityScriptLayerKind.classify(id: id, object: object, document: document)
    }

    private var initialValues: [(slot: Int, value: WPEParitySceneState.ScriptValue)] = []

    private func layout(document: WPESceneDocument, state: WPEParitySceneState) {
        for object in document.resolvedObjectsJSON {
            guard let id = WPEParitySceneAnimations.id(object) else { continue }
            addLayer(id: id, kind: Self.kind(of: id, object: object, document: document), config: object, state: state,
                     document: document)
        }
        sceneBase = slots.count
        for descriptor in sceneFields {
            let slot = slots.count
            slots.append(Slot(layer: -1, descriptor: index(of: descriptor)))
            refresh.append(.field(slot: slot, objectID: "", name: descriptor.fieldName))
            let key = WPEParitySceneState.ScriptFieldKey(objectID: "", name: descriptor.fieldName)
            if let value = configuration.fieldDefaults[key]
                ?? Self.parse(document.resolvedGeneralJSON[descriptor.name.lowercased()], descriptor)
                ?? Self.generalDefault(descriptor) {
                initialValues.append((slot, value))
            }
        }
        grow(to: slots.count + 256)
        for (slot, value) in initialValues {
            store(value, at: slot)
        }
    }

    @discardableResult
    private func addLayer(id: String, kind: WPEParityScriptLayerKind, config: WPESceneJSONValue,
                          state: WPEParitySceneState?, document: WPESceneDocument? = nil) -> Int {
        let layerIndex = Int32(layers.count)
        let base = slots.count
        let stateIndex = state?.index(of: id)
        let hasVideo = config["video"] != nil || ["video.rate", "video.loop", "video.duration"].contains {
            configuration.fieldDefaults[.init(objectID: id, name: $0)] != nil || state?.scriptField($0, of: id) != nil
        }
        layers.append(Layer(id: id, kind: kind, base: base, config: config, hasVideo: hasVideo))
        for descriptor in fields(kind) {
            let slot = slots.count
            slots.append(Slot(layer: layerIndex, descriptor: index(of: descriptor)))
            if case let .object(property) = descriptor.target, stateIndex != nil {
                refresh.append(.object(slot: slot, objectID: id, property))
                continue
            }
            let raw: WPESceneJSONValue? = switch descriptor.owner {
            case .particleInstance: config["instanceoverride"]?[descriptor.name]
            case .video: config["video"]?[descriptor.name]
            default: config[descriptor.name]
            }
            refresh.append(.field(slot: slot, objectID: id, name: descriptor.fieldName))
            let key = WPEParitySceneState.ScriptFieldKey(objectID: id, name: descriptor.fieldName)
            if let value = configuration.fieldDefaults[key] ?? (descriptor.flags.contains(.notFromJSON) ? nil : Self.parse(raw, descriptor))
                ?? Self.fallback(descriptor, objectID: id, document: document) {
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
                refresh.append(.effect(slot: slot, key: state.effects[effectIndex]))
            }
            slots.append(entry)
            effectSlots[Int(layerIndex), default: []].append((effectID, slot))
            for (pass, values) in WPEParityProgramScene.array(effect["passes"]).enumerated() {
                addConstants(values["constantshadervalues"], layer: layerIndex,
                             pass: WPEParityMaterialPassKey(objectID: id, effectID: effectID, pass: pass), state: state)
            }
            for pass in Set(configuration.materialConstants.keys.filter { $0.pass.objectID == id && $0.pass.effectID == effectID }.map(\.pass)) {
                addConstants(nil, layer: layerIndex, pass: pass, state: state)
            }
        }
        addConstants(config["instance"]?["constantshadervalues"], layer: layerIndex,
                     pass: WPEParityMaterialPassKey(objectID: id), state: state)
        for pass in Set(configuration.materialConstants.keys.filter { $0.pass.objectID == id && $0.pass.effectID == nil }.map(\.pass)) {
            addConstants(nil, layer: layerIndex, pass: pass, state: state)
        }
        return Int(layerIndex)
    }

    private var constantSlots: [WPEParityMaterialPassKey: [String: Int]] = [:]
    /// Each layer's effect visible slots in effect order.
    private var effectSlots: [Int: [(id: String, slot: Int)]] = [:]

    private func addConstants(_ values: WPESceneJSONValue?, layer: Int32, pass key: WPEParityMaterialPassKey,
                              state: WPEParitySceneState) {
        guard state.passIndex(of: key) != nil else { return }
        if let effectID = key.effectID {
            if let records = configuration.resolvedEffectRecords[.init(objectID: key.objectID, effectID: effectID)],
               !records.contains(where: { $0.materialPass == key }) {
                return
            }
        }
        let entries: [String: WPESceneJSONValue] = if case let .object(raw)? = values {
            raw
        } else {
            [:]
        }
        let passIndex = state.passIndex(of: key)
        let native = passIndex.map { state.constants(pass: $0) } ?? [:]
        let metadata = configuration.materialConstants.filter { $0.key.pass == key }
        let names = Set(entries.keys).union(native.keys).union(metadata.keys.map(\.name)).sorted()
        for name in names {
            guard constantSlots[key]?[name] == nil else { continue }
            let raw = entries[name]
            let info = metadata[ConstantKey(pass: key, name: name)]
            let components = info?.components ?? native[name]?.count ?? raw.map { Self.components($0["value"] ?? $0).count } ?? 0
            let angle = info?.angle ?? configuration.angleConstants.contains(ConstantKey(pass: key, name: name))
            guard let descriptor = WPEParityScriptProperty.material(name: name, components: components, angle: angle)
            else { continue }
            let slot = slots.count
            slots.append(Slot(layer: layer, descriptor: index(of: descriptor), materialPass: key))
            constantSlots[key, default: [:]][name] = slot
            refresh.append(.constant(slot: slot, key: key, name: name))
            if let value = native[name]?.value ?? info?.value ?? raw.map({ Self.vector(Self.components($0["value"] ?? $0)) }) {
                initialValues.append((slot, .vector(value)))
            }
        }
    }

    private func grow(to count: Int) {
        guard count > capacity else { return }
        let newCapacity = max(count, capacity * 2)
        let newFloats = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity * 4)
        newFloats.initialize(repeating: 0, count: newCapacity * 4)
        let newIntegers = UnsafeMutablePointer<Int32>.allocate(capacity: newCapacity)
        newIntegers.initialize(repeating: 0, count: newCapacity)
        let newFlags = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newFlags.initialize(repeating: 0, count: newCapacity)
        let newDirty = UnsafeMutablePointer<Int32>.allocate(capacity: newCapacity + 1)
        newDirty.initialize(repeating: 0, count: newCapacity + 1)
        if capacity > 0 {
            newFloats.update(from: floats, count: capacity * 4)
            newIntegers.update(from: integers, count: capacity)
            newFlags.update(from: dirtyFlags, count: capacity)
            newDirty.update(from: dirty, count: capacity + 1)
        } else {
            floats.deallocate()
            integers.deallocate()
            dirtyFlags.deallocate()
            dirty.deallocate()
        }
        // The old buffers belong to their typed arrays, which free them when collected.
        (floats, integers, dirtyFlags, dirty, capacity) = (newFloats, newIntegers, newFlags, newDirty, newCapacity)
        guard host != nil else { return }
        host.invokeMethod("rebind", withArguments: [typedArray(.float32, floats, newCapacity * 16),
                                                    typedArray(.int32, integers, newCapacity * 4),
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

    /// Host indices originate in JS; conversion must not trap before checking an existing wrapper's bounds.
    static func checkedLayerIndex(_ value: Double, count: Int) -> Int? {
        guard let index = Int(exactly: value), index >= 0, index < count else { return nil }
        return index
    }

    private func installHost(state: WPEParitySceneState) {
        let host = JSValue(newObjectIn: context)!
        func set(_ key: String, _ value: Any) {
            host.setObject(value, forKeyedSubscript: key as NSString)
        }
        set("floats", typedArray(.float32, floats, capacity * 16))
        set("integers", typedArray(.int32, integers, capacity * 4))
        set("dirtyFlags", typedArray(.uint8, dirtyFlags, capacity))
        set("dirty", typedArray(.int32, dirty, (capacity + 1) * 4))
        set("globals", typedArray(.float32, globals, 64, owned: false))
        set("audio", typedArray(.float32, audio, 336 * 4, owned: false))
        set("eventNames", WPEParityScriptEvent.allCases.map { $0.functionName ?? NSNull() as Any })
        set("kinds", WPEParityScriptLayerKind.allCases.map { kind in
            fields(kind).enumerated().map { rel, field in Self.fieldInfo(field, rel: rel) }
        })
        set("sceneFields", sceneFields.enumerated().map { rel, field in
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
        let canDestroy: @convention(block) (Double) -> Bool = { [weak self] index in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  configuration.destroyLayer != nil else { return false }
            let id = layers[index].id
            let token = activeState?.pointee.object(id)?.modelDataToken
            let admitted = configuration.canDestroyLayer?(id, token) ?? true
            if !admitted {
                configuration.log(1, "destroyLayer is unsupported for this product resource consumer")
            }
            return admitted
        }
        let destroyed: @convention(block) (Double) -> Bool = { [weak self] index in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count), let state = activeState,
                  let destroy = configuration.destroyLayer else { return false }
            let id = layers[index].id
            flushWrites(to: &state.pointee)
            guard destroy(id, &state.pointee) else {
                record("destroyLayer transaction failed for \(id)")
                return false
            }
            destroyedObjectIDs.append(id)
            return true
        }
        let sort: @convention(block) (Double, Double) -> Bool = { [weak self] index, position in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  let position = Int(exactly: position), let state = activeState,
                  let sort = configuration.sortLayer else { return false }
            flushWrites(to: &state.pointee)
            return sort(layers[index].id, position, &state.pointee)
        }
        let registerAudio: @convention(block) (Double) -> Void = { [weak self] resolution in
            self?.audioResolutions.insert(Int(resolution))
        }
        let initialConfig: @convention(block) (Double) -> String? = { [weak self] index in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  case var .object(entries) = layers[index].config else { return nil }
            entries["id"] = nil
            return Self.jsonText(.object(entries))
        }
        let soundVolumeWritten: @convention(block) (Double) -> Void = { [weak self] slot in
            self?.soundVolumeWritten(slot: slot)
        }
        let soundCommand: @convention(block) (Double, Double) -> Bool = { [weak self] layer, command in
            self?.soundCommand(layer: layer, command: command) ?? false
        }
        let pauseVideo: @convention(block) (Double) -> Void = { [weak self] index in
            guard let self else { return }
            guard let index = Self.checkedLayerIndex(index, count: layers.count), layers[index].hasVideo else {
                configuration.log(1, "video.pause is unsupported for an invalid video owner")
                return
            }
            guard let pause = configuration.pauseVideoTexture, pause(layers[index].id) else {
                configuration.log(1, "video.pause is unsupported without an existing product video consumer")
                return
            }
        }
        let executeMaterialFunction: @convention(block) (Double, String) -> Void = { [weak self] slot, name in
            guard let self, let slot = Self.checkedLayerIndex(slot, count: slots.count),
                  let effect = Self.checkedLayerIndex(Double(slots[slot].effect), count: effectKeys.count) else { return }
            guard let handler = materialFunctionHandler else {
                configuration.log(1, "executeMaterialFunction is unsupported without a product resource consumer")
                return
            }
            handler(effectKeys[effect], name)
        }
        let layerIndexByID: @convention(block) (String) -> Double = { [weak self] id in
            Double(self?.layers.firstIndex { $0.id == id } ?? -1)
        }
        let lookAtAngles: @convention(block) (Double, Double, Double, Double, Double, Double,
                                              Double, Double, Double, Double, Double) -> NSArray? = { ox, oy, oz, tx, ty, tz, ux, uy, uz, camera, yawOnly in
            guard let angles = WPEParityLayerTransform.lookAtAngles(
                origin: SIMD3(Float(ox), Float(oy), Float(oz)), target: SIMD3(Float(tx), Float(ty), Float(tz)),
                up: SIMD3(Float(ux), Float(uy), Float(uz)), camera: camera != 0, yawOnly: yawOnly != 0
            ) else { return nil }
            return [NSNumber(value: angles.x), NSNumber(value: angles.y), NSNumber(value: angles.z)] as NSArray
        }
        let create: @convention(block) (String) -> Double = { [weak self] json in
            self?.createLayer(json: json) ?? -1
        }
        let createModel: @convention(block) (JSValue, Double) -> JSValue? = { [weak self] input, binding in
            self?.modelData(input, token: nil, replacing: false, bindingIndex: binding)
        }
        let updateModel: @convention(block) (Double, JSValue, Bool, Double) -> JSValue? = { [weak self] token, input, replacing, binding in
            guard let token = UInt32(exactly: token) else { return nil }
            return self?.modelData(input, token: token, replacing: replacing, bindingIndex: binding)
        }
        let releaseModel: @convention(block) (Double) -> Void = { [weak self] token in
            guard let self, let token = UInt32(exactly: token), let state = activeState else { return }
            state.pointee.releaseModelData(token)
        }
        set("resolve", resolve)
        set("load", load)
        set("error", error)
        set("log", log)
        set("openUserShortcut", shortcut)
        set("destroyed", destroyed)
        set("canDestroyLayer", canDestroy)
        set("sortLayer", sort)
        let registerAsset: @convention(block) (Double, String, Bool) -> Bool = { [weak self] binding, path, flag in
            guard let self, let index = Int(exactly: binding), bindings.indices.contains(index) else { return false }
            guard !bindings[index].registeredAssets.contains(where: { $0.path.utf8.elementsEqual(path.utf8) }) else { return false }
            bindings[index].registeredAssets.append(.init(path: path, flag: flag))
            bindings[index].assetsPrepared = false
            return true
        }
        set("registerAsset", registerAsset)
        set("registerAudio", registerAudio)
        set("initialConfig", initialConfig)
        set("pauseVideoTexture", pauseVideo)
        set("soundVolumeWritten", soundVolumeWritten)
        set("soundCommand", soundCommand)
        set("soundKind", WPEParityScriptLayerKind.sound.rawValue)
        set("executeMaterialFunction", executeMaterialFunction)
        set("lookAtAngles", lookAtAngles)
        set("cameraKind", WPEParityScriptLayerKind.camera.rawValue)
        set("layerIndexByID", layerIndexByID)
        set("createLayer", create)
        set("createModelData", createModel)
        set("updateModelData", updateModel)
        set("releaseModelData", releaseModel)
        set("storageEnabled", configuration.storage != nil)
        let storageGet: @convention(block) (String, Double) -> String? = { [weak self] key, location in
            self?.configuration.storage?.get(key, location == 0 ? .global : .screen)
        }
        let storageSet: @convention(block) (String, String, Double) -> Void = { [weak self] key, value, location in
            self?.configuration.storage?.set(key, value, location == 0 ? .global : .screen)
        }
        let storageDelete: @convention(block) (String, Double) -> Bool = { [weak self] key, location in
            self?.configuration.storage?.delete(key, location == 0 ? .global : .screen) ?? false
        }
        let storageClear: @convention(block) (Double) -> Bool = { [weak self] location in
            self?.configuration.storage?.clear(location == 0 ? .global : .screen) ?? false
        }
        set("storageGet", storageGet)
        set("storageSet", storageSet)
        set("storageDelete", storageDelete)
        set("storageClear", storageClear)
        context.evaluateScript(WPEParityScriptPrelude.source, withSourceURL: URL(string: "parity-host.js"))
            .call(withArguments: [host])
        self.host = host
        tickFunction = host.forProperty("tick")
        for (index, layer) in layers.enumerated() {
            addHostLayer(index, layer, state: state)
        }
        for (slot, value) in initialValues {
            if case let .string(string) = value {
                store(.string(string), at: slot)
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
                "readonly": field.flags.contains(.notFromJSON), "soundVolume": field.isSoundVolumeWrite, "rel": rel, "owner": owner]
    }

    private func addHostLayer(_ index: Int, _ layer: Layer, state: WPEParitySceneState) {
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
            let records = configuration.resolvedEffectRecords[.init(objectID: layer.id, effectID: effectID)]
            func resolvedMaterialKey(_ record: WPEParityEffectPassRecord) -> WPEParityMaterialPassKey? {
                guard let key = record.materialPass, record.filePassIndex >= 0,
                      key.objectID == layer.id, key.effectID == effectID, key.pass == record.filePassIndex,
                      state.passIndex(of: key) != nil else { return nil }
                return key
            }
            let materialKeys = (records.map { Set($0.compactMap(resolvedMaterialKey)) }
                ?? Set(constantSlots.keys.filter { $0.objectID == layer.id && $0.effectID == effectID }))
                .filter { state.passIndex(of: $0) != nil }
                .sorted { $0.pass < $1.pass }
            let passes = materialKeys.map(materialInfo)
            let recordMaterials: [[String: Any]] = records?.map { record in
                ["pass": resolvedMaterialKey(record).flatMap { materialKeys.firstIndex(of: $0) } ?? -1,
                 "path": record.materialPath.map { $0 as Any } ?? NSNull(),
                 "hasMaterial": record.materialPass != nil || record.materialPath != nil]
            } ?? []
            effects.append(["slot": slot, "name": WPEParityProgramScene.string(effect["name"]) ?? effectID,
                            "passes": passes, "records": recordMaterials,
                            "metadataKnown": records != nil])
        }
        let baseMaterials = constantSlots.keys.filter {
            $0.objectID == layer.id && $0.effectID == nil && state.passIndex(of: $0) != nil
        }
        .sorted { $0.pass < $1.pass }.map(materialInfo)
        host.invokeMethod("addLayer", withArguments: [index, layer.kind.rawValue, layer.base, parent, effects, baseMaterials, layer.hasVideo])
    }

    private func materialInfo(_ key: WPEParityMaterialPassKey) -> [String: Any] {
        var constants: [String: Any] = [:]
        for (name, constantSlot) in constantSlots[key] ?? [:] {
            let descriptor = descriptors[Int(slots[constantSlot].descriptor)]
            constants[name] = ["slot": constantSlot, "type": descriptor.type.rawValue,
                               "angle": descriptor.flags.contains(.angle), "readonly": descriptor.flags.contains(.notFromJSON)]
        }
        return constants
    }

    private func modelData(_ input: JSValue, token: UInt32?, replacing: Bool, bindingIndex: Double) -> JSValue? {
        guard let provider = configuration.modelData, let admitShape = modelDataAdmissionHandler, let state = activeState else {
            configuration.log(1, "ModelData is unsupported without the product resource owner")
            return nil
        }
        flushWrites(to: &state.pointee)
        // Getter failures remain ordinary catchable JS values; the converter must not count them as uncaught.
        let exceptionHandler = context.exceptionHandler
        context.exception = nil
        context.exceptionHandler = { context, exception in context?.exception = exception }
        defer { context.exceptionHandler = exceptionHandler }
        let assetContext = Int(exactly: bindingIndex).flatMap { bindings.indices.contains($0) ? bindings[$0].assetContext : nil }
        return WPEParityScriptModels.perform(input, token: token, assetContext: assetContext,
                                             provider: provider) { patch in
            // No State inout borrow spans VM getters/material conversion; the owned patch is now complete.
            if let token {
                try state.pointee.updateModelData(token, patch: patch, replacing: replacing, admitShape: admitShape)
                return nil
            }
            return try state.pointee.createModelData(patch, admitShape: admitShape)
        }
    }

    private func createLayer(json: String) -> Double {
        guard let create = configuration.createLayer, let state = activeState else {
            configuration.log(1, "createLayer is unsupported without a product resource transaction")
            return -1
        }
        flushWrites(to: &state.pointee)
        var candidate = state.pointee
        guard let created = create(json, &candidate),
              let object = try? JSONSerialization.jsonObject(with: Data(created.configJSON.utf8)),
              let config = WPESceneJSONValue(jsonValue: object), case .object = config,
              !created.id.isEmpty, Self.preparedIdentity(config) == created.id,
              state.pointee.index(of: created.id) == nil,
              candidate.index(of: created.id) != nil,
              candidate.ids.count == state.pointee.ids.count + 1,
              Array(candidate.ids.dropLast()) == state.pointee.ids,
              Array(candidate.objects.dropLast()) == state.pointee.objects,
              Array(candidate.commonOrder.dropLast()) == state.pointee.commonOrder,
              !layers.contains(where: { $0.id == created.id }),
              hasCreatedMaterialConsumers(id: created.id, config: config, state: candidate) else {
            configuration.log(1, "createLayer candidate is invalid or unsupported; no state was committed")
            return -1
        }
        if case let .number(number)? = config["model"] {
            guard let token = UInt32(exactly: number), candidate.modelData(token) != nil else {
                configuration.log(1, "createLayer numeric model has no canonical prepared State consumer")
                return -1
            }
            if candidate.object(created.id)?.modelDataToken == nil {
                do { try candidate.retainModelData(token, for: created.id) } catch {
                    configuration.log(1, "createLayer could not retain its canonical ModelData")
                    return -1
                }
            } else if candidate.object(created.id)?.modelDataToken != token {
                configuration.log(1, "createLayer candidate retained a different ModelData token")
                return -1
            }
        }
        state.pointee = candidate
        let kind: WPEParityScriptLayerKind = config["text"] != nil ? .text
            : config["particle"] != nil ? .particle : config["sound"] != nil ? .sound : .image
        let start = initialValues.count
        let firstBinding = bindings.filter(\.compiled).count
        let index = addLayer(id: created.id, kind: kind, config: config, state: state.pointee)
        grow(to: slots.count)
        for (slot, value) in initialValues[start...] {
            store(value, at: slot)
        }
        seedMissingFields(state: &state.pointee, first: start)
        mirror(state.pointee)
        addHostLayer(index, layers[index], state: state.pointee)
        compileLayerBindings(index, source: config)
        host.invokeMethod("init", withArguments: [firstBinding])
        createdLayers.append(created)
        return Double(index)
    }

    /// Authored constant writes may only register a real prepared pass, just like loaded layers. This validates
    /// candidate value-state; it does not infer resources, native handles, or descriptors from authored JSON.
    private func hasCreatedMaterialConsumers(id: String, config: WPESceneJSONValue, state: WPEParitySceneState) -> Bool {
        func hasConstants(_ value: WPESceneJSONValue?) -> Bool {
            if case let .object(entries)? = value {
                return !entries.isEmpty
            }
            return false
        }
        if hasConstants(config["instance"]?["constantshadervalues"]),
           state.passIndex(of: .init(objectID: id)) == nil {
            return false
        }
        for effect in WPEParityProgramScene.array(config["effects"]) {
            guard let effectID = Self.preparedIdentity(effect),
                  state.effects.contains(.init(objectID: id, effectID: effectID)) else { return false }
            let records = configuration.resolvedEffectRecords[.init(objectID: id, effectID: effectID)]
            for (pass, value) in WPEParityProgramScene.array(effect["passes"]).enumerated() {
                guard hasConstants(value["constantshadervalues"]) else { continue }
                let key = WPEParityMaterialPassKey(objectID: id, effectID: effectID, pass: pass)
                guard state.passIndex(of: key) != nil else { return false }
                if let records, !records.contains(where: { $0.materialPass == key }) {
                    return false
                }
            }
        }
        return true
    }

    /// A host-prepared config carries its assigned ID. Unlike authored name lookup, this never falls back to a
    /// name or truncates an out-of-range/fractional number while validating a candidate that may be rejected.
    private static func preparedIdentity(_ config: WPESceneJSONValue) -> String? {
        if case let .string(id)? = config["id"], !id.isEmpty {
            return id
        }
        if case let .number(number)? = config["id"], let id = Int(exactly: number) {
            return String(id)
        }
        return nil
    }

    // MARK: Bindings

    private func compileBindings(document: WPESceneDocument) {
        if case let .object(entries) = document.resolvedGeneralJSON {
            let supported = Set(sceneFields.map(\.name))
            for (name, value) in entries where value["script"] != nil && !supported.contains(name) {
                configuration.log(1, "general.\(name) script is unsupported: no registered descriptor consumer")
            }
        }
        for (rel, descriptor) in sceneFields.enumerated() {
            guard !descriptor.flags.contains(.notFromJSON) else { continue }
            addBinding(layerIndex: -1, path: descriptor.name.lowercased(), slot: sceneBase + rel,
                       descriptor: descriptor, className: "general", source: document.sourceJSON["general"],
                       root: document.resolvedGeneralJSON)
        }
        for (layerIndex, layer) in layers.enumerated() {
            let source = sourceObjects.first { WPEParitySceneAnimations.id($0) == layer.id }
            compileLayerBindings(layerIndex, source: source)
        }
    }

    private func compileLayerBindings(_ layerIndex: Int, source: WPESceneJSONValue?) {
        let layer = layers[layerIndex]
        if case let .object(entries) = layer.config {
            let supported = Set(fields(layer.kind).filter { !$0.flags.contains(.notFromJSON) }
                .filter { $0.owner != .video && $0.owner != .particleInstance }.map(\.name))
            for (name, value) in entries where value["script"] != nil && !supported.contains(name) {
                configuration.log(1, "\(layer.id).\(name) script is unsupported: no registered writable descriptor")
            }
        }
        for (rel, descriptor) in fields(layer.kind).enumerated() {
            guard !descriptor.flags.contains(.notFromJSON) else { continue }
            let path = descriptor.owner == .particleInstance ? "instanceoverride/\(descriptor.name)"
                : descriptor.owner == .video ? "video/\(descriptor.name)" : descriptor.name
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
                       descriptor: descriptors[Int(slots[slot].descriptor)], className: "material", source: source)
        }
    }

    private func addBinding(layerIndex: Int, path: String, slot: Int, descriptor: WPEParityScriptProperty,
                            className: String, source: WPESceneJSONValue?, root: WPESceneJSONValue? = nil) {
        let components = path.split(separator: "/").map(String.init)
        let config = root ?? (layerIndex >= 0 ? layers[layerIndex].config : nil)
        let resolved = components.reduce(config) { node, key in
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
        let bindingIndex = bindings.count
        let assetContext = AssetContext(bindingIndex: bindingIndex, objectID: layerIndex < 0 ? "" : layers[layerIndex].id,
                                        propertyPath: path, modulePath: "scripts/\(name).js", registeredAssets: [], assetsPrepared: true)
        bindings.append(Binding(objectID: assetContext.objectID, path: path, name: name, compiled: false,
                                exportBits: 0, bindingIndex: bindingIndex, script: -1, userKeys: userKeys))
        let before = exceptionCount
        let function = context.evaluateScript(WPEParityScriptModule.lower(script),
                                              withSourceURL: URL(string: "scripts/\(name).js"))
        var bits = -1
        var handle = -1
        if exceptionCount == before, let function, function.isObject {
            bits = Int(host.invokeMethod("addBinding", withArguments: [
                function, name, assetContext.modulePath, bindingIndex, layerIndex, slot, descriptor.type.rawValue,
                descriptor.flags.contains(.angle), descriptor.flags.contains(.notFromJSON), vars, descriptor.isSoundVolumeWrite,
            ]).toInt32())
            if bits >= 0 {
                handle = bindings.filter { $0.script >= 0 }.count
            }
        }
        let registered = bindings[bindingIndex]
        bindings[bindingIndex] = Binding(objectID: assetContext.objectID, path: path, name: name, compiled: handle >= 0,
                                         exportBits: max(bits, 0), bindingIndex: bindingIndex,
                                         registeredAssets: registered.registeredAssets, assetsPrepared: registered.assetsPrepared,
                                         script: handle, userKeys: userKeys)
    }

    // MARK: JSON

    private static func fallback(_ descriptor: WPEParityScriptProperty, objectID: String,
                                 document: WPESceneDocument?) -> WPEParitySceneState.ScriptValue? {
        if descriptor.owner == .object, descriptor.name == "parallaxDepth", let document {
            let object = document.resolvedObjectsJSON.first { WPEParitySceneAnimations.id($0) == objectID }
            let raw = object?["parallaxDepth"] ?? object?["parallaxdepth"]
            let depth = raw.map { components($0["value"] ?? $0) } ?? [1, 1]
            let x = depth.first ?? 0
            return .vector(SIMD4(x, depth.count > 1 ? depth[1] : x, 0, 0))
        }
        if descriptor.owner == .text, let text = document?.textObjects.first(where: { $0.id == objectID }) {
            switch descriptor.name {
            case "text": return .string(text.text)
            case "font": return .string(text.fontRelativePath ?? "systemfont_arial")
            case "pointsize": return .vector(SIMD4(Float(text.pointSize), 0, 0, 0))
            case "horizontalalign": return .string(text.horizontalAlignment)
            case "verticalalign": return .string(text.verticalAlignment)
            case "padding": return .vector(SIMD4(32, 32, 0, 0))
            case "spacing": return .vector(SIMD4(Float(text.spacing.x), Float(text.spacing.y), 0, 0))
            case "limituseellipsis": return .vector(SIMD4(text.limitUseEllipsis ? 1 : 0, 0, 0, 0))
            case "maxwidth": return .vector(SIMD4(500, 0, 0, 0))
            case "maxrows": return .integer(1)
            default: break
            }
        }
        if descriptor.owner == .sound, let sound = document?.soundObjects.first(where: { $0.id == objectID }) {
            switch descriptor.name {
            case "volume": return .vector(SIMD4(Float(sound.volume), 0, 0, 0))
            case "mintime": return .vector(SIMD4(Float(sound.minTime), 0, 0, 0))
            case "maxtime": return .vector(SIMD4(Float(sound.maxTime), 0, 0, 0))
            default: break
            }
        }
        switch (descriptor.owner, descriptor.name) {
        case (.object, "solid"): return .vector(SIMD4(1, 0, 0, 0))
        case (.object, "sortorder"): return .integer(0)
        case (.particleInstance, "colorn"):
            let authoredColor = document?.particleObjects.first { $0.id == objectID }?.instanceOverride?.color
            let color = authoredColor.map { SIMD3<Float>($0 / 255) } ?? .one
            return .vector(SIMD4(color, 0))
        case let (.particleInstance, name) where name.hasPrefix("controlpoint"):
            return .vector(SIMD4(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude,
                                 Float.greatestFiniteMagnitude, 0))
        case (.particleInstance, _): return .vector(SIMD4(1, 0, 0, 0))
        // Camera constructor in 14018ff60.c: fov=0x42480000, zoom=0x3f800000.
        case (.camera, "fov"): return .vector(SIMD4(50, 0, 0, 0))
        case (.camera, "zoom"): return .vector(SIMD4(1, 0, 0, 0))
        case (.camera, "queuemode"): return .string("random")
        // Inline light constructor, 14018ff60.c:203-218, before authored descriptor values are loaded.
        case (.light, "intensity"): return .vector(.zero)
        case (.light, "radius"): return .vector(SIMD4(1, 0, 0, 0))
        case (.light, "exponent"): return .vector(SIMD4(2, 0, 0, 0))
        case (.light, "innercone"): return .vector(SIMD4(20, 0, 0, 0))
        case (.light, "outercone"): return .vector(SIMD4(30, 0, 0, 0))
        case (.light, "controlpoint"): return .vector(SIMD4(2, 0, 0, 0))
        case (.text, "pointsize"): return .vector(SIMD4(32, 0, 0, 0))
        case (.text, "font"): return .string("systemfont_arial")
        case (.text, "padding"): return .vector(SIMD4(32, 32, 0, 0))
        case (.text, "spacing"): return .vector(.zero)
        case (.text, "maxwidth"): return .vector(SIMD4(500, 0, 0, 0))
        case (.text, "maxrows"): return .integer(1)
        // 140256ae0: background scale=1; block-align bit0x20 is absent from initial flags=1.
        case (.text, "backgroundbrightness"): return .vector(SIMD4(1, 0, 0, 0))
        case (.text, "blockalign"): return .vector(.zero)
        case (.text, "horizontalalign"): return .string("center")
        case (.text, "verticalalign"): return .string("middle")
        case (.text, "limitwidth"), (.text, "limitrows"), (.text, "limituseellipsis"): return .vector(.zero)
        default: return descriptor.type == .string ? .string("") : nil
        }
    }

    private static func generalDefault(_ descriptor: WPEParityScriptProperty) -> WPEParitySceneState.ScriptValue? {
        switch descriptor.name {
        case "ambientcolor", "skylightcolor": .vector(.zero)
        case "bloomstrength": .vector(SIMD4(2, 0, 0, 0))
        case "bloomthreshold": .vector(SIMD4(0.65, 0, 0, 0))
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
            return WPEParityProgramScene.string(value).map { .string(descriptor.canonicalString($0, fromJSON: true)) }
        }
        if descriptor.type == .int {
            let number: Double? = switch value {
            case let .number(raw): raw
            case let .string(raw): Double(raw)
            default: nil
            }
            guard let number, number.isFinite, number >= Double(Int32.min), number <= Double(Int32.max) else { return nil }
            return .integer(Int32(number.rounded(.towardZero)))
        }
        let components = Self.components(value)
        guard !components.isEmpty else { return nil }
        if components.count == 1, descriptor.type.componentCount > 1 {
            var result = SIMD4<Float>.zero
            for lane in 0 ..< descriptor.type.componentCount {
                result[lane] = components[0]
            }
            return .vector(result)
        }
        return .vector(vector(components))
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
