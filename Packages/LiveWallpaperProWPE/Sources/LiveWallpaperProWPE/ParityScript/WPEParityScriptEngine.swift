import Foundation
import JavaScriptCore
import simd

/// One scene's SceneScript engine: a JSContext with WPE's baseclasses.js, every property script of the
/// scene compiled as a module in binding order, and the host objects. Confined to its owner's thread.
public final class WPEParityScriptEngine {
    public enum ExecutionOperation: String, Sendable {
        case setup, initialize, update, event, destroy
    }

    public struct ExecutionLimits: Sendable {
        public let setupSeconds: TimeInterval
        public let callbackSeconds: TimeInterval

        public init(setupSeconds: TimeInterval = 5, callbackSeconds: TimeInterval = 0.25) {
            precondition(setupSeconds.isFinite && setupSeconds > 0)
            precondition(callbackSeconds.isFinite && callbackSeconds > 0)
            self.setupSeconds = setupSeconds
            self.callbackSeconds = callbackSeconds
        }
    }

    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case missingBaseClasses
        case executionLimitUnavailable
        case executionTimedOut(operation: ExecutionOperation, seconds: TimeInterval)

        public var errorDescription: String? {
            switch self {
            case .missingBaseClasses: "SceneScript base classes are missing."
            case .executionLimitUnavailable: "SceneScript execution limits are unavailable on this system."
            case let .executionTimedOut(operation, seconds):
                "SceneScript \(operation.rawValue) exceeded its \(seconds)s execution budget and was disabled."
            }
        }
    }

    /// A timed-out VM is permanently disabled. The product stops this scene and keeps its last presented frame.
    public internal(set) var executionFailure: Failure?
    public var isExecutionDisabled: Bool {
        executionFailure != nil
    }

    /// Native ISound methods; only isPlaying exposes the consumer's Bool to JavaScript.
    public enum SoundCommand: Int, Sendable {
        case play, stop, pause, isPlaying
    }

    /// Native IVideoTexture methods other than pause (140214050.c:107-208).
    public enum VideoCommand: Int, Sendable {
        case play, stop, isPlaying, getCurrentTime, setCurrentTime
    }

    /// Native ITextureAnimation members (1402131a0.c:39-284); the Prelude's op numbers are these raw values.
    public enum TextureAnimationCommand: Int, Sendable {
        case play, pause, stop, isPlaying, getFrame, setFrame, join, getRate, setRate, frameCount, duration
    }

    /// Native IAnimationLayer methods (14026c980.c:256-457); the Prelude's op numbers are these raw values.
    public enum AnimationLayerCommand: Int, Sendable {
        case play, pause, stop, isPlaying, setFrame, getFrame, fps, frameCount, duration
    }

    /// Native IParticleSystem methods (14024cb00.c:94-205); the Prelude's op numbers are these raw values.
    public enum ParticleCommand: Int, Sendable {
        case play, pause, stop, isPlaying, emitParticles
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
        /// CPU execution limits for the whole setup or one callback batch, including nested imported scripts.
        public var executionLimits: ExecutionLimits
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
        /// Unix ms that JS `Date.now()` and argument-less `Date()` read at engine.runtime 0; nil = JS Date reads the
        /// wall clock.
        public var dateEpochMillis: Double?
        /// Explicit replay only. nil preserves JavaScriptCore's native Math.random; zero is a valid seed.
        public var randomSeed: UInt32?

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
                    openUserShortcut: @escaping (String) -> Bool = { _ in false }, dateEpochMillis: Double? = nil,
                    randomSeed: UInt32? = nil,
                    executionLimits: ExecutionLimits = .init()) {
            self.assets = assets
            self.executionLimits = executionLimits
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
            self.dateEpochMillis = dateEpochMillis
            self.randomSeed = randomSeed
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
    }

    public struct RegisteredAsset: Equatable, Sendable {
        public let path: String
        /// Strict native boolean byte.
        public let flag: Bool
    }

    /// A property script in binding order. A failed compile keeps its place with no exports (140175880.c:366-382).
    public struct Binding: Sendable {
        public let objectID: String
        /// The property's path under the object, such as `origin` or `effects/0/passes/0/constantshadervalues/k`.
        public let path: String
        /// WPE's compile name, "class_property".
        public let name: String
        public let exportBits: Int
        public var compiled: Bool {
            script >= 0
        }

        let bindingIndex: Int
        /// Read only by the editor's precache export; the runtime never loads from it (0x181655810.c:258-271).
        public internal(set) var registeredAssets: [RegisteredAsset] = []
        let script: Int
        /// User key → its scriptproperties; an empty condition takes the value as is.
        let userKeys: [String: [(name: String, condition: String)]]
    }

    public struct CreatedLayer: Sendable {
        public let id: String
        public let configJSON: String

        public init(id: String, configJSON: String) {
            self.id = id
            self.configJSON = configJSON
        }
    }

    struct Slot {
        var layer: Int32
        var descriptor: Int32
        var effect: Int32 = -1
        var materialPass: WPEParityMaterialPassKey?
        /// The layer's `animationlayers` index; -1 = not an animation-layer field.
        var animationLayer: Int32 = -1
    }

    enum Refresh {
        case object(slot: Int, objectID: String, WPEParitySceneState.Property)
        case effect(slot: Int, key: WPEParitySceneState.EffectKey)
        case constant(slot: Int, key: WPEParityMaterialPassKey, name: String)
        case field(slot: Int, objectID: String, name: String)

        var slot: Int {
            switch self {
            case let .object(slot, _, _), let .effect(slot, _), let .constant(slot, _, _), let .field(slot, _, _): slot
            }
        }
    }

    struct Layer {
        let id: String
        let kind: WPEParityScriptLayerKind
        let base: Int
        let config: WPESceneJSONValue
        let hasVideo: Bool
    }

    /// Exceeding it resets the script clock to 0 (DAT_14049296c, 14017fa70.c:216-223).
    public static let runtimeWrap: Float = 432_000

    public internal(set) var bindings: [Binding] = []
    public private(set) var frame: UInt64 = 0
    public internal(set) var exceptionCount = 0
    /// The first 32 exception messages.
    public internal(set) var exceptions: [String] = []
    public internal(set) var destroyedObjectIDs: [String] = []
    public internal(set) var createdLayers: [CreatedLayer] = []
    public private(set) var started = false
    public internal(set) var audioResolutions: Set<Int> = []
    /// Rebound when a renderer takes over this engine; accepted calls belong to that consumer's queue.
    public var materialFunctionHandler: ((WPEParitySceneState.EffectKey, String) -> Void)?
    /// Rebound like materialFunctionHandler. Arguments: owner layer ID, command, setCurrentTime seconds (else 0).
    /// Returns 1/0 for isPlaying, seconds for getCurrentTime, 0 otherwise; nil = no product video consumer.
    public var videoTextureHandler: ((String, VideoCommand, Double) -> Double?)?
    /// Rebound like materialFunctionHandler. Arguments: image layer ID, command, setFrame frame or setRate rate
    /// (else 0). Returns 1/0 for isPlaying, a getter's value, 0 otherwise; nil = the layer's texture has no sprite sheet.
    public var textureAnimationHandler: ((String, TextureAnimationCommand, Double) -> Double?)?
    /// Rebound like materialFunctionHandler. Arguments: image layer ID, `animationlayers` index, command, setFrame
    /// frame (else 0). Returns 1/0 for isPlaying, a getter's value, 0 otherwise; nil = no such puppet layer.
    public var animationLayerHandler: ((String, Int, AnimationLayerCommand, Double) -> Double?)?
    /// Rebound like materialFunctionHandler. Arguments: particle layer ID, command, emitParticles count (else 0).
    /// Returns 1/0 for isPlaying, 0 otherwise; nil = no loaded particle system for the layer.
    public var particleSystemHandler: ((String, ParticleCommand, Int32) -> Double?)?
    /// Rebound like materialFunctionHandler. Arguments: owner layer ID, material pass (nil = the layer), name.
    public var propertyAnimationLookup: ((String?, WPEParityMaterialPassKey?, String) -> WPEParityPropertyAnimation?)?
    /// Rebound like materialFunctionHandler. Arguments: layer ID, kind, the callback's flushed state; returns the
    /// native vfunc+0x80 matrix (images W′, others W), nil = no transform owner for the layer.
    public var transformMatrixHandler: ((String, WPEParityScriptLayerKind, WPEParitySceneState) -> simd_float4x4?)?
    /// Rebound like materialFunctionHandler. Runs the body on the image layer's puppet; false = the layer has none.
    public var puppetHandler: ((String, (inout WPEParityPuppetAnimator) -> Void) -> Bool)?

    /// Rebound with the current renderer's prepared artifacts before init and when a renderer takes over.
    public var modelDataAdmissionHandler: ((WPEParitySceneModelData.Shape, WPEParityModelDataMutation) throws
        -> (any WPEParityModelDataPreparedShape)?)?

    let context: JSContext
    let executionLimiter: WPEParityScriptExecutionLimiter
    let configuration: Configuration
    var host: JSValue!
    var tickFunction: JSValue!
    var setStringsFunction: JSValue!
    /// String slot writes `sendStrings` has not yet delivered.
    var pendingStrings: [(slot: Int, value: String)] = []
    var floats: UnsafeMutablePointer<Float>
    var integers: UnsafeMutablePointer<Int32>
    var dirtyFlags: UnsafeMutablePointer<UInt8>
    var dirty: UnsafeMutablePointer<Int32>
    var capacity: Int
    let globals: UnsafeMutablePointer<Float>
    let audio: UnsafeMutablePointer<Float>
    var slots: [Slot] = []
    var descriptors: [WPEParityScriptProperty] = []
    var descriptorIndex: [WPEParityScriptProperty: Int] = [:]
    var layers: [Layer] = []
    var refresh: [Refresh] = [] {
        didSet { mirrorPlan = nil }
    }

    var mirrorPlan: MirrorPlan?
    /// State's effect, constant and field generations when those slots last matched it; nil = mirror them all.
    var mirroredGenerations: MirroredGenerations?
    /// State object revisions, by object index, when that object's slots last matched it; -1 or absent = mirror it.
    var mirroredObjectRevisions: [Int] = []
    var flushedSlots: [Int] = []
    /// Refresh entries the last mirror visited.
    var mirroredEntries = 0
    var effectKeys: [WPEParitySceneState.EffectKey] = []
    var sceneBase = 0
    private var clock: Float = 0
    private var preparedFrame = false
    private var wasDown = false
    /// While set, the context's exception handler stores exceptions in `context.exception` instead of recording them.
    var capturesExceptionsAsValues = false
    var dispatchCounts = [Int](repeating: 0, count: WPEParityScriptEvent.allCases.count)
    let materialConstantsByPass: [WPEParityMaterialPassKey: [ConstantKey: MaterialConstant]]
    /// Material passes with constants, by owner: pass index 0, effectID nil = the layer's own material.
    let materialPassesByOwner: [WPEParityMaterialPassKey: Set<WPEParityMaterialPassKey>]
    var activeState: UnsafeMutablePointer<WPEParitySceneState>?
    var mirroredMembershipGeneration: Int?
    var soundVolumeConsumer: ((String, SoundFields) -> Void)?
    var soundCommandConsumer: ((String, SoundCommand, SoundFields) -> Bool)?
    /// IAnimation handles: one per binding found, by identity; the JS wrapper for handle i is cached at index i.
    var animationHandles: [WPEParityPropertyAnimation] = []

    /// The Prelude's `host.animationCommand` op numbers.
    enum AnimationCommand: Int {
        case play, pause, stop, isPlaying, setFrame, getFrame, getRate, setRate, fps, frameCount, duration
    }

    /// Native IImageLayer bone and blend-shape methods except the physics pair (140211070.c:332-698); the Prelude's
    /// `host.puppetCommand` op numbers are these raw values.
    enum PuppetCommand: Int {
        case boneCount, boneIndex, boneParentIndex, boneTransform, setBoneTransform, localBoneTransform
        case setLocalBoneTransform, localBoneAngles, setLocalBoneAngles, localBoneOrigin, setLocalBoneOrigin
        case blendShapeIndex, blendShapeWeight, setBlendShapeWeight
    }

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
        withExecutionBudget(.setup) {
            mirror(state)
            if !executionLimiter.didTimeOut {
                compileBindings(document: document)
            }
        }
        if let executionFailure {
            throw executionFailure
        }
    }

    /// Constructs one VM/layout and compiles module globals against the caller's canonical mutable state.
    /// The caller next prepares registered assets, then scopes consumers around start/init and later events.
    public static func prepare(document: WPESceneDocument, state: inout WPEParitySceneState,
                               configuration: Configuration, volume: (String, SoundFields) -> Void,
                               command: (String, SoundCommand, SoundFields) -> Bool) throws -> WPEParityScriptEngine {
        let engine = try WPEParityScriptEngine(layoutOf: document, state: state, configuration: configuration)
        engine.withSoundConsumers(volume: volume, command: command) {
            engine.seedMissingFields(state: &state)
            engine.run(state: &state, operation: .setup) {
                engine.compileBindings(document: document)
            }
        }
        if let failure = engine.executionFailure {
            throw failure
        }
        return engine
    }

    /// Initializes the existing VM/metadata once; no authored module body executes before its caller's scope.
    private init(layoutOf document: WPESceneDocument, state: WPEParitySceneState, configuration: Configuration) throws {
        self.configuration = configuration
        executionLimiter = try WPEParityScriptExecutionLimiter()
        materialFunctionHandler = configuration.executeMaterialFunction
        modelDataAdmissionHandler = configuration.modelData?.admitShape
        context = JSContext()
        var byPass: [WPEParityMaterialPassKey: [ConstantKey: MaterialConstant]] = [:]
        var byOwner: [WPEParityMaterialPassKey: Set<WPEParityMaterialPassKey>] = [:]
        for (key, constant) in configuration.materialConstants {
            byPass[key.pass, default: [:]][key] = constant
            byOwner[WPEParityMaterialPassKey(objectID: key.pass.objectID, effectID: key.pass.effectID), default: []]
                .insert(key.pass)
        }
        (materialConstantsByPass, materialPassesByOwner) = (byPass, byOwner)
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
        // Never read this handler back to restore it: each Swift read/write round trip wraps it in one more block,
        // and releasing a chain thousands deep overflows the stack.
        context.exceptionHandler = { [weak self] context, exception in
            guard let self, !executionLimiter.didTimeOut else { return }
            if capturesExceptionsAsValues {
                context?.exception = exception
            } else {
                recordException(exception)
            }
        }
        withExecutionBudget(.setup) {
            if let seed = configuration.randomSeed {
                _ = callJavaScript(evaluateScript(Self.randomShim, withSourceURL: URL(string: "parity-random.js")),
                                   withArguments: [Double(seed)])
            }
            guard !executionLimiter.didTimeOut else { return }
            evaluateScript(String(bytes: baseClasses, encoding: .utf8) ?? "",
                           withSourceURL: URL(string: "scripts/jsclasses/baseclasses.js"))
            guard !executionLimiter.didTimeOut else { return }
            layout(document: document, state: state)
            installHost(state: state)
            guard !executionLimiter.didTimeOut else { return }
            if let epoch = configuration.dateEpochMillis {
                _ = callJavaScript(evaluateScript(Self.dateShim, withSourceURL: URL(string: "parity-date.js")),
                                   withArguments: [host.forProperty("globals") as Any, epoch])
            }
        }
        if let executionFailure {
            throw executionFailure
        }
    }

    /// One stream per context, installed before module globals and init callbacks. Nothing is added to globalThis.
    /// UInt32 LCG arithmetic also advances from seed zero; the divisor keeps every result in [0, 1).
    private static let randomShim = #"""
    (function (seed) {
    'use strict';
    let state = seed >>> 0;
    Math.random = function random() {
      state = (Math.imul(state, 1664525) + 1013904223) >>> 0;
      return state / 4294967296;
    };
    })
    """#

    /// G[1] is engine.runtime; each read adds 1 µs so busy-wait loops on Date.now() still advance.
    private static let dateShim = #"""
    (function (G, epoch) {
    'use strict';
    const NativeDate = Date;
    let calls = 0;
    const now = () => epoch + G[1] * 1000 + ++calls * 0.001;
    function ParityDate(...args) {
      if (!new.target) return new NativeDate(now()).toString();
      return Reflect.construct(NativeDate, args.length ? args : [now()], new.target);
    }
    ParityDate.prototype = NativeDate.prototype;
    ParityDate.now = now;
    ParityDate.UTC = NativeDate.UTC;
    ParityDate.parse = NativeDate.parse;
    globalThis.Date = ParityDate;
    })
    """#

    deinit {
        context.exceptionHandler = nil
        globals.deallocate()
        audio.deallocate()
    }

    public func dispatchCount(_ event: WPEParityScriptEvent) -> Int {
        dispatchCounts[event.rawValue]
    }

    /// The `left`, `right` and `average` bins registerAudioBuffers(resolution) hands out, contiguous; nil for any
    /// resolution but 16, 32 and 64.
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

    /// Refreshes the registerAudioBuffers bins from the frame's 128 spectrum bins (left 64, then right 64).
    /// 32 and 16 pairwise-max the whole left|right|average buffer, so `average` pools the 64-bin mean
    /// (140110630.c:1704-2147).
    public func updateAudio(_ bins: [Float]) {
        guard bins.count == 128, let full = audioBuffer(resolution: 64),
              let half = audioBuffer(resolution: 32), let quarter = audioBuffer(resolution: 16) else { return }
        for index in 0 ..< 64 {
            (full[index], full[64 + index]) = (bins[index], bins[64 + index])
            full[128 + index] = (bins[index] + bins[64 + index]) * 0.5
        }
        for index in 0 ..< 96 {
            half[index] = max(full[2 * index], full[2 * index + 1])
        }
        for index in 0 ..< 48 {
            quarter[index] = max(half[2 * index], half[2 * index + 1])
        }
    }

    public func assetContext(of index: Int) -> AssetContext? {
        guard bindings.indices.contains(index) else { return nil }
        let binding = bindings[index]
        return AssetContext(bindingIndex: binding.bindingIndex, objectID: binding.objectID, propertyPath: binding.path,
                            modulePath: "scripts/\(binding.name).js")
    }

    /// Event 0 to every binding that exports `init`, once, after all objects loaded (140186c90.c:689-738).
    public func start(state: inout WPEParitySceneState) throws {
        if let executionFailure {
            throw executionFailure
        }
        guard !started else { return }
        started = true
        seedMissingFields(state: &state)
        run(state: &state, operation: .initialize) {
            count(.initialize)
            invokeHost("init", withArguments: [0])
        }
        if let executionFailure {
            throw executionFailure
        }
        // Windows load order: every init, then one applyUserProperties per script with the full table, then update.
        applyUserProperties(changedJSON: configuration.userPropertiesJSON, mergedJSON: configuration.userPropertiesJSON,
                            state: &state)
        if let executionFailure {
            throw executionFailure
        }
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
        run(state: &state, operation: .update) {
            count(.update)
            var exception: JSValueRef?
            guard executionLimiter.prepareInvocation(in: context) else { return }
            JSObjectCallAsFunction(context.jsGlobalContextRef, tickFunction.jsValueRef, nil, 0, nil, &exception)
            if let exception, !executionLimiter.didTimeOut {
                recordException(JSValue(jsValueRef: exception, in: context))
            }
        }
    }

    /// Inject the scene's frame clock and sampled input before cursor, media and animation events.
    /// The following tick consumes these values; its fallback dt/input apply only when no frame was prepared.
    public func prepareFrame(frame: UInt64, dt: Float, runtime: Float, input: Input) {
        self.frame = frame
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
        // Without events no JS runs, so the mirror and flush of `run` are left to the next entry this frame.
        if !dispatches.isEmpty {
            let payload = "{\"world\":[\(input.cursorWorld.x),\(input.cursorWorld.y),\(input.cursorWorld.z)],"
                + "\"local\":[\(input.cursorWorld.x),\(input.cursorWorld.y),\(input.cursorWorld.z)],\"hitBox\":null}"
            run(state: &state) {
                for dispatch in dispatches {
                    guard !executionLimiter.didTimeOut else { break }
                    guard let target = layers.firstIndex(where: { $0.id == dispatch.id }) else { continue }
                    count(dispatch.event)
                    invokeHost("dispatch", withArguments: [dispatch.event.rawValue, target, payload])
                }
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
            invokeHost("dispatch", withArguments: [event.rawValue, index, payloadJSON ?? NSNull()])
        }
    }

    /// Runs the addEndedCallback callbacks of each video owner whose player reached its end once this frame.
    public func videoEnded(ownerIDs: some Sequence<String>, state: inout WPEParitySceneState) {
        let indices = ownerIDs.compactMap { id in layers.firstIndex { $0.id == id && $0.hasVideo } }
        guard !indices.isEmpty else { return }
        run(state: &state) {
            for index in indices {
                guard !executionLimiter.didTimeOut else { break }
                invokeHost("videoEnded", withArguments: [index])
            }
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
            invokeHost("setUserProperties", withArguments: [mergedJSON])
            for binding in bindings where binding.compiled {
                guard !executionLimiter.didTimeOut else { break }
                var vars: [String: Any] = [:]
                for (key, properties) in binding.userKeys {
                    guard let value = (changed[key] as? [String: Any])?["value"] else { continue }
                    for (name, condition) in properties {
                        vars[name] = condition.isEmpty ? value : Self.asString(value).map { $0 == condition } ?? value
                    }
                }
                guard !vars.isEmpty, let data = try? JSONSerialization.data(withJSONObject: vars) else { continue }
                invokeHost("applyScriptProperties",
                           withArguments: [binding.script, String(bytes: data, encoding: .utf8) ?? "{}"])
            }
            guard !executionLimiter.didTimeOut else { return }
            count(.applyUserProperties)
            invokeHost("dispatch", withArguments: [WPEParityScriptEvent.applyUserProperties.rawValue, -1,
                                                   eventJSON])
        }
    }

    /// jsoncpp asString of a changed value (140085cc0.c:12-37); nil for arrays and objects, which a conditional
    /// scriptproperty takes as is (1401731d0.c:336-342).
    private static func asString(_ value: Any) -> String? {
        switch value {
        case is NSNull: return ""
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let type = String(cString: number.objCType)
            guard type == "f" || type == "d" else { return number.stringValue }
            // valueToString(double, precision 17) appends ".0" to a mantissa-only result.
            let text = String(format: "%.17g", number.doubleValue)
            return text.contains(where: { $0 == "." || $0 == "e" }) ? text : text + ".0"
        default: return nil
        }
    }

    /// Event 3 to every binding, which then stops (140176f70.c:400-426).
    public func destroy(state: inout WPEParitySceneState) {
        run(state: &state, operation: .destroy) {
            count(.destroy)
            invokeHost("destroyAll", withArguments: [])
            guard !executionLimiter.didTimeOut else { return }
            invokeHost("clearVideoEnded", withArguments: [])
        }
    }

    var initialValues: [(slot: Int, value: WPEParitySceneState.ScriptValue)] = []

    var constantSlots: [WPEParityMaterialPassKey: [String: Int]] = [:]
    /// Each layer's effect visible slots in effect order.
    var effectSlots: [Int: [(id: String, slot: Int)]] = [:]
    /// Each image layer's first animation-layer field slot, by `animationlayers` index.
    var animationLayerBases: [Int: [Int]] = [:]
}
