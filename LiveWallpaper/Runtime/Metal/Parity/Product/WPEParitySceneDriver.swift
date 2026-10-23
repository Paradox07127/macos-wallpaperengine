#if !LITE_BUILD
import CoreFoundation
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore

/// Present readiness, written by command-buffer completion handlers on Metal's callback threads.
final class WPEParityPresentState: Sendable {
    struct CadenceCounts: Sendable {
        var sceneCompleted = 0
        var sceneFailed = 0
        var presentCompleted = 0
        var presentFailed = 0
        var staleCompletions = 0
    }

    private struct Readiness {
        var generation = 0
        var completed: Int?
        var failed: Int?
        var inFlight = 0
        var sceneFailed = false
        var gpuErrorCount = 0
        var gpuErrorLast: String?
        var cadence: CadenceCounts?
    }

    private let readiness = OSAllocatedUnfairLock(initialState: Readiness())

    var completedGeneration: Int? {
        readiness.withLock(\.completed)
    }

    var failedGeneration: Int? {
        readiness.withLock(\.failed)
    }

    var gpuErrors: (count: Int, last: String?) {
        readiness.withLock { ($0.gpuErrorCount, $0.gpuErrorLast) }
    }

    /// Scene and presentation buffers complete separately; a successful present cannot repair failed scene work.
    func recordGPUFailure(generation: Int, reason: String) {
        readiness.withLock { state in
            guard state.generation == generation else { return }
            state.sceneFailed = true
            state.gpuErrorCount += 1
            state.gpuErrorLast = reason
            if state.completed != generation {
                state.failed = generation
            }
        }
    }

    var inFlight: Int {
        readiness.withLock(\.inFlight)
    }

    func reset(generation: Int) {
        readiness.withLock { state in
            state = Readiness(generation: generation, inFlight: state.inFlight, cadence: state.cadence)
        }
    }

    func enableCadenceDiagnostics() {
        readiness.withLock { $0.cadence = .init() }
    }

    var cadenceCounts: CadenceCounts? {
        readiness.withLock(\.cadence)
    }

    /// Reuses the existing scene completion callback; contains no command buffer or renderer ownership.
    func recordCadenceScene(generation: Int, succeeded: Bool) {
        readiness.withLock { state in
            guard state.cadence != nil else { return }
            guard state.generation == generation else {
                state.cadence?.staleCompletions += 1
                return
            }
            if succeeded {
                state.cadence?.sceneCompleted += 1
            } else {
                state.cadence?.sceneFailed += 1
            }
        }
    }

    func begin() {
        readiness.withLock { $0.inFlight += 1 }
    }

    func end() {
        readiness.withLock { $0.inFlight -= 1 }
    }

    /// A completion from an earlier load is dropped; a later failure never revokes a ready generation.
    func record(generation: Int, succeeded: Bool, cadencePresent: Bool = false) {
        readiness.withLock { state in
            guard state.generation == generation else {
                if cadencePresent {
                    state.cadence?.staleCompletions += 1
                }
                return
            }
            if cadencePresent {
                if succeeded, !state.sceneFailed {
                    state.cadence?.presentCompleted += 1
                } else {
                    state.cadence?.presentFailed += 1
                }
            }
            if succeeded, !state.sceneFailed {
                state.completed = generation
                state.failed = nil
            } else if state.completed != generation {
                state.failed = generation
            }
        }
    }
}

/// Runs one scene on the parity renderer and presents its backbuffer to a layer. Confined to the render actor
/// that owns it; only `WPEParityPresentState` is touched from other threads.
final class WPEParitySceneDriver {
    /// Metal status is thread-safe; this immutable handle is read only after later work on the same queue completes.
    private struct SubmittedBuffer: @unchecked Sendable {
        let buffer: MTLCommandBuffer?
        var succeeded: Bool {
            buffer?.status == .completed
        }
    }

    /// The backbuffer a fit mode renders and how the present maps it onto the drawable.
    struct RenderTarget: Equatable {
        let width: Int
        let height: Int
        let alignment: WPEParityCameraAlignment
        let presentFit: WPEPresentFitMode
        var physicalSize: SIMD2<Int>?
        var pixelScale: Double = 1

        var pixelSize: SIMD2<Int> {
            physicalSize ?? SIMD2(width, height)
        }
    }

    /// What `load` planned from, so a new size or fit mode re-plans without reloading.
    private struct PlanSource {
        let document: WPESceneDocument
        /// The scene as loaded; its material-file constants keep their load-time watches across commits.
        let scene: WPEParityProgramScene
        /// Immutable authored preparation for this document revision; never a renderer's live scene.
        var preparedScene: WPEParityProgramScene?
        let assets: WPEParityProgramAssets
        let settings: WPEParityProgramSettings
        let shaders: WPEParityFrameShaderSource
        let workshopID: String?
        let sceneSize: SIMD2<Float>
        let pixelFormat: MTLPixelFormat
        let renderScale: Double
        let textureCompression: WPEParityTextureCompression?
    }

    var excludedObjectIDs: Set<String> = [] {
        didSet { renderer?.instance.state.excludedObjectIDs = excludedObjectIDs }
    }

    let executor: WPEMetalPresenter
    private(set) var renderer: WPEParityFrameRenderer?
    var didLoad: Bool {
        renderer != nil
    }

    private(set) var drawableSize = CGSize.zero
    private(set) var fitMode = WPEPresentFitMode.cover
    private(set) var mouseInteractionEnabled = true
    private(set) var userPreferredFPS = WPESceneRenderPolicy.defaultPreferredFPS
    private(set) var adaptiveThrottleActive = false
    /// The scene flag or a program reading `g_AudioSpectrum*` enables audio processing.
    private var shaderRequiresAudio = false
    var requiresSystemAudioCapture: Bool {
        guard let renderer else { return false }
        return shaderRequiresAudio || renderer.instance.script?.engine.audioResolutions.isEmpty == false
    }

    private var planSource: PlanSource?
    /// A live property commit supersedes candidate plans without replacing the load generation.
    private var planRevision = 0
    private var preparingVideoID: UUID?

    var pendingVideoAdmissionID: UUID? {
        renderer?.pendingVideoAdmission?.id
    }

    #if DEBUG
    enum VideoAdmissionCheckpoint { case beforePreparation, beforeCommit }
    var videoAdmissionCheckpoint: ((VideoAdmissionCheckpoint) async throws -> Void)?
    var videoAdmissionPreparedForTesting: ((WPEParityVideoTextures) -> Void)?
    #endif

    /// Called between frames on this driver's owning actor. A stale temporary owner retires only its new players.
    nonisolated(nonsending) func preparePendingVideos() async throws -> Bool {
        guard let renderer, let request = renderer.pendingVideoAdmission,
              preparingVideoID != request.id else { return false }
        let generation = loadGeneration
        let revision = planRevision
        preparingVideoID = request.id
        defer {
            if preparingVideoID == request.id {
                preparingVideoID = nil
            }
        }
        do {
            try Task.checkCancellation()
            #if DEBUG
            try await videoAdmissionCheckpoint?(.beforePreparation)
            #endif
            let prepared = try await renderer.prepareVideos(request)
            #if DEBUG
            videoAdmissionPreparedForTesting?(prepared)
            try await videoAdmissionCheckpoint?(.beforeCommit)
            #endif
            try Task.checkCancellation()
            guard self.renderer === renderer, loadGeneration == generation, planRevision == revision,
                  renderer.pendingVideoAdmission?.id == request.id else { return false }
            return try renderer.acceptVideos(prepared, for: request)
        } catch {
            if error is CancellationError || Task.isCancelled {
                if self.renderer === renderer, renderer.pendingVideoAdmission?.id == request.id {
                    renderer.cancelVideoAdmission()
                }
                throw CancellationError()
            }
            guard self.renderer === renderer, loadGeneration == generation, planRevision == revision,
                  renderer.pendingVideoAdmission?.id == request.id else { return false }
            renderer.cancelVideoAdmission()
            runtimeFailure = "WPE video admission failed: \(error.localizedDescription)"
            soundRuntime?.stop()
            logFrameFailure(error)
            throw error
        }
    }

    let reusesPreparedScene: Bool
    private var plannedTarget: RenderTarget?
    /// The target the last re-plan of this load failed to build; not retried until the target changes.
    private var failedReplanTarget: RenderTarget?
    /// The loaded scene's user-property bindings; `.incremental` ones apply without a reload.
    var userPropertyBindings: [String: [WPEScenePropertyBinding]] {
        guard let renderer, let planSource else { return [:] }
        return WPEParityUserProperties.bindings(document: planSource.document)
            .merging(WPEParityUserProperties.bindings(scene: planSource.scene), uniquingKeysWith: +)
            .merging(renderer.conditionalPropertyBindings, uniquingKeysWith: +)
    }

    /// A change `prepareUserProperties` accepted, parsed with its new values, waiting for its commit.
    private var pendingUserProperties: (patch: WPEScenePropertyPatch, document: WPESceneDocument)?
    /// engine.userProperties as last applied: project.json's properties with the user's values.
    private var scriptUserProperties = "{}"
    private var mediaMailbox: WPESceneMediaEventMailbox?
    /// Bumped on load and cleanup, so presents of an older load never count as ready.
    private(set) var loadGeneration = 0
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    /// Draws whose program did not resolve, compile or link.
    private(set) var shaderErrorSummary: (count: Int, entries: [(shader: String, reason: String)]) = (0, [])
    /// The scene's sound layers under WPE's rules; started by `load`, stopped by `cleanup()`.
    private(set) var soundRuntime: WPESoundRuntime?
    /// Kept so mute and volume set before the runtime exists apply once it starts.
    private(set) var audioMuted = false
    private(set) var audioVolume = 1.0
    private var audioPreset: WPEEngineAudioSettings?
    /// Set on a span group's hidden producer: frames go to the members' presenters instead of a drawable.
    var spanFrames: WPESceneSpanFrames?
    private var spanFrameSequence: UInt64 = 0
    private let device: MTLDevice
    private let presentState = WPEParityPresentState()

    struct CadenceSubmissions: Sendable {
        var rendererRevision = 0
        var attempts = 0
        var sceneCommitted = 0
        var sceneSkipped = 0
        var sceneErrors = 0
        var presentCommitted = 0
        var presentScheduled = 0
        var drawableMisses = 0
        var presentErrors = 0
    }

    static let cadenceDiagnosticsEnvironmentKey = "LOOMSCREEN_PARITY_CADENCE_DIAGNOSTICS"

    static func resolveCadenceDiagnostics(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch environment[cadenceDiagnosticsEnvironmentKey]?.lowercased() {
        case "1", "true": true
        default: false
        }
    }

    private(set) var cadenceSubmissions: CadenceSubmissions?

    func enableCadenceDiagnostics() {
        cadenceSubmissions = .init()
        presentState.enableCadenceDiagnostics()
    }

    var cadenceCompletions: WPEParityPresentState.CadenceCounts? {
        cadenceSubmissions == nil ? nil : presentState.cadenceCounts
    }

    private var paused = false
    /// The left button as the edges handed to the renderer left it; also the frame's button state.
    private var edgeButtonDown = false
    /// Backbuffer UV of the script cursor when it differs from the shader pointer; nil = the shader pointer.
    private var scriptPointer: SIMD2<Double>?
    private var lastTimestamp: CFTimeInterval?
    private var didLogFrameFailure = false
    private var submittedSceneBuffer: MTLCommandBuffer?
    private(set) var runtimeFailure: String?
    private var sceneScriptLanguage: String?
    private var deliveredScriptLanguage: String?
    var gpuErrorSummary: (count: Int, last: String?) {
        presentState.gpuErrors
    }

    /// CPU time in `encodeFrame` since the load, for the QA mean.
    private var encodeSeconds = 0.0
    private var encodeCount = 0

    /// The loaded scene changes its frame on its own, or plays
    /// sound, whose random intervals count down by frame time.
    var needsContinuousFrames: Bool {
        didLoad && runtimeFailure == nil && (renderer?.isStatic == false || soundRuntime != nil)
    }

    var diagnostics: WPEParityRuntimeDiagnostics? {
        guard let renderer else { return nil }
        return WPEParityRuntimeDiagnostics(
            loadGeneration: loadGeneration, drawCount: renderer.drawCount,
            encodedDrawCount: renderer.lastFrameDraws.count,
            skippedDraws: renderer.skipped.values.reduce(into: [:]) { $0[$1.category, default: 0] += 1 },
            encodeFrameCPUMeanMilliseconds: encodeCount == 0 ? nil : encodeSeconds / Double(encodeCount) * 1000,
            arenaBytes: renderer.arenaBytes, heapBytes: renderer.heapBytes,
            dedicatedTextureBytes: renderer.dedicatedTextureBytes, isStatic: renderer.isStatic,
            shaderCache: planSource?.shaders.store.statistics
        )
    }

    var completedPresentGeneration: Int? {
        presentState.completedGeneration
    }

    var failedPresentGeneration: Int? {
        presentState.failedGeneration
    }

    var hasPresentedFrame: Bool {
        didLoad && completedPresentGeneration == loadGeneration
    }

    /// Some script of the loaded scene exports a media handler.
    var scriptHandlesMedia: Bool {
        renderer?.instance.script?.handlesMedia == true
    }

    var hasMediaTextureDemand: Bool {
        renderer?.hasMediaTextureDemand == true
    }

    /// Present command buffers committed and not yet completed.
    var inFlightCount: Int {
        presentState.inFlight
    }

    var drawableAcquisitionSeconds: TimeInterval {
        executor.drawableAcquisitionSeconds
    }

    var isPaused: Bool {
        paused
    }

    /// Suspended while the pause ramp still moves scene time; the frame that ends it is skipped (140110630.c:671-707).
    var isPauseRamping: Bool {
        paused && (renderer?.instance.clock.pauseRamp ?? 0) > 0
    }

    /// Applies the user ceiling and adaptive throttle floor.
    var effectiveFPS: Int {
        guard adaptiveThrottleActive else { return userPreferredFPS }
        return min(userPreferredFPS, max(WPESceneRenderPolicy.adaptiveFrameRateFloor, userPreferredFPS / 2))
    }

    /// The loaded plan no longer matches the drawable size or fit mode.
    var needsReplan: Bool {
        guard didLoad, let planSource else { return false }
        let target = currentTarget(sceneSize: planSource.sceneSize,
                                   isHDR: WPEParityProgramScene.hdrEnabled(document: planSource.document,
                                                                           settings: planSource.settings),
                                   pixelFormat: planSource.pixelFormat, renderScale: planSource.renderScale).target
        return target != plannedTarget && target != failedReplanTarget
    }

    #if DEBUG
    /// Test seam: remaining `load` calls that throw at once.
    nonisolated(unsafe) static var remainingForcedLoadFailuresForTesting = 0 // serial XCTest sets it before any load
    struct ForcedLoadFailure: Error {}
    /// Test seam: remaining `replan` builds that throw at once.
    nonisolated(unsafe) static var remainingForcedReplanFailuresForTesting = 0 // serial XCTest sets it before replan
    struct ForcedReplanFailure: Error {}
    #endif

    /// Process-scoped rollback: the app and wallpaper extension each read their own appScoped defaults domain.
    static let preparedSceneReuseDefaultsKey = "loomscreen.wallpapers.parityReusePreparedScene.v1"
    static let preparedSceneReuseEnvironmentKey = "LOOMSCREEN_PARITY_REUSE_PREPARED_SCENE"

    static func resolvePreparedSceneReuse(defaults: UserDefaults = .appScoped(),
                                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let value = environment[preparedSceneReuseEnvironmentKey]?.lowercased() {
            if ["1", "true"].contains(value) {
                return true
            }
            if ["0", "false"].contains(value) {
                return false
            }
        }
        guard let number = defaults.object(forKey: preparedSceneReuseDefaultsKey) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return true }
        return number.boolValue
    }

    init(device: MTLDevice, reusePreparedScene: Bool? = nil) throws {
        self.device = device
        reusesPreparedScene = reusePreparedScene ?? Self.resolvePreparedSceneReuse()
        executor = try WPEMetalPresenter(device: device)
    }

    /// `document` already carries the user property values. Compiles every program (seconds when the disk cache is
    /// cold); a load superseded by `cleanup()` throws `CancellationError`. Runs on the caller's actor, which owns the
    /// driver.
    nonisolated(nonsending) func load(
        document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings,
        drawableSize: CGSize, pixelFormat: MTLPixelFormat, compiler: (any WPEParityShaderCompiling)?,
        diskCache: WPEParityShaderDiskCache = .shared,
        compilerIdentity: String? = nil, shaderOptions: WPEParityShaderCompileOptions = .init(),
        bindingABIVersion: Int = 1, shaderPolicy: WPEParityShaderPolicy = .compileAllowed,
        requireCompleteShaders: Bool = false, renderScaleOverride: Double? = nil,
        textureCompression: WPEParityTextureCompression? = .resolve(),
        soundResolver: WPEMultiRootResourceResolver? = nil, audioPreset: WPEEngineAudioSettings? = nil,
        workshopID: String? = nil, scriptHost: WPEParitySceneScript.Host = .init(),
        userShortcutIcons: WPEUserShortcutIconStore? = nil,
        particleSeed: UInt32 = WPEParityParticleScene.productSeed(),
        reuseDirectTextExtentLayouts: Bool? = nil
    ) async throws {
        #if DEBUG
        if Self.remainingForcedLoadFailuresForTesting > 0 {
            Self.remainingForcedLoadFailuresForTesting -= 1
            throw ForcedLoadFailure()
        }
        #endif
        mediaMailbox?.invalidateParityGeneration(loadGeneration)
        loadGeneration &+= 1
        let generation = loadGeneration
        mediaMailbox = scriptHost.media
        mediaMailbox?.beginParityGeneration(generation)
        presentState.reset(generation: generation)
        runtimeFailure = nil
        spanFrames?.reset(generation: generation)
        renderer?.destroyScript()
        renderer?.cancelVideoAdmission()
        renderer = nil
        deliveredScriptLanguage = nil
        executor.lastPresentPass = nil
        planSource = nil
        plannedTarget = nil
        failedReplanTarget = nil
        executor.upscalePlan = .inactive
        executor.lastPresentedDrawableSize = .zero
        _ = executor.takePresentSideDemotion()
        pendingUserProperties = nil
        shaderRequiresAudio = false
        loadDiagnostics = nil
        runtimeFailure = nil
        submittedSceneBuffer = nil
        shaderErrorSummary = (0, [])
        (encodeSeconds, encodeCount) = (0, 0)
        soundRuntime?.stop()
        soundRuntime = nil
        self.audioPreset = audioPreset
        updateSurfaceGeometry(drawableSize: drawableSize)
        var preparedSound: WPESoundRuntime?
        do {
            let sceneSize = WPEParityCamera(document: document, renderTargetSize: SIMD2(1, 1)).size
            let renderScale = renderScaleOverride ?? WPEMetalFXSpatialUpscaler.renderScale
            let selection = currentTarget(sceneSize: sceneSize,
                                          isHDR: WPEParityProgramScene.hdrEnabled(document: document, settings: settings),
                                          pixelFormat: pixelFormat, renderScale: renderScale)
            let target = selection.target
            let plan = try await Self.makePlan(document: document, assets: assets, settings: settings, target: target)
            var identity = compilerIdentity
            #if !SYSTEM_WALLPAPER_EXTENSION
            if identity == nil {
                identity = (compiler as? WPEParityHelperShaderCompiler)?.compilerIdentity
            }
            #endif
            guard let identity, !identity.isEmpty else {
                throw WPEParityFrameRenderError.requiredShaderUnavailable("Compiler identity is missing")
            }
            let store = WPEParityShaderStore(compiler: compiler, diskCache: diskCache, policy: shaderPolicy, inFlight: .shared)
            let shaders = WPEParityFrameShaderSource(store: store, compilerIdentity: identity,
                                                     bindingABIVersion: bindingABIVersion, options: shaderOptions,
                                                     requireAllPrograms: requireCompleteShaders || shaderPolicy == .precompiledOnly)
            let renderer = try await WPEParityFrameRenderer(
                plan: plan, device: device, queue: executor.textureSourceCommandQueue, shaders: shaders,
                particleSeed: particleSeed, workshopID: workshopID, userPropertiesJSON: scriptHost.userPropertiesJSON,
                textureCompression: textureCompression, reuseDirectTextExtentLayouts: reuseDirectTextExtentLayouts
            )
            guard generation == loadGeneration else { throw CancellationError() }
            renderer.instance.state.excludedObjectIDs = excludedObjectIDs
            if paused {
                renderer.applyPerformanceProfile(.suspended)
            }
            renderer.instance.userShortcutIcons = userShortcutIcons
            // Built here so the first present does not compile its pipeline on the frame path.
            _ = try executor.renderPipeline(
                vertexName: "wpe_present_vertex",
                fragmentName: WPEMetalPresenter.presentFragment(source: renderer.backbuffer.pixelFormat,
                                                                colorTransfer: renderer.colorTransfer),
                colorPixelFormat: pixelFormat
            )
            if let soundResolver, !document.soundObjects.isEmpty {
                let runtime = WPESoundRuntime(resolver: soundResolver)
                preparedSound = runtime
                await Self.prepareSound(runtime, sounds: document.soundObjects)
                guard generation == loadGeneration else {
                    runtime.stop()
                    throw CancellationError()
                }
                runtime.setMuted(audioMuted)
                runtime.setMasterVolume(effectiveAudioVolume)
                soundRuntime = runtime
                if paused {
                    runtime.pause()
                } else {
                    runtime.play()
                }
            }
            let shaderErrors = renderer.skipped.sorted { $0.key < $1.key }.compactMap { index, skip in
                switch skip {
                case .program, .noShader, .pipeline:
                    (shader: plan.programs[index]?.shader ?? "operation \(index)", reason: skip.description)
                default:
                    nil
                }
            }
            shaderErrorSummary = (shaderErrors.count, shaderErrors)
            shaderRequiresAudio = Self.readsAudio(plan)
            planSource = PlanSource(document: document, scene: plan.scene,
                                    preparedScene: reusesPreparedScene ? plan.scene : nil,
                                    assets: assets, settings: settings,
                                    shaders: shaders, workshopID: workshopID, sceneSize: sceneSize,
                                    pixelFormat: pixelFormat, renderScale: renderScale, textureCompression: textureCompression)
            plannedTarget = target
            adoptUpscalePlan(selection.upscale)
            scriptUserProperties = scriptHost.userPropertiesJSON
            renderer.attachMedia(mediaMailbox, generation: generation)
            let precached = Self.precacheMaterialPaths(document.resolvedGeneralJSON)
            // Unverified whether WPE fails the scene on a precache entry (1401515b0); the entry is skipped.
            try await preloadMaterials(precached, source: "precache", renderer: renderer, shaders: shaders,
                                       generation: generation)
            if WPEParitySceneScript.hasScripts(document) {
                do {
                    var connectedHost = scriptHost
                    connectedHost.pauseVideoTexture = renderer.scriptVideoPause
                    connectedHost.executeMaterialFunction = renderer.scriptMaterialFunction
                    connectedHost.canDestroyLayer = renderer.scriptLayerRemovalAdmission
                    connectedHost.createLayer = WPEParityModelDataLayerAdmission.create(
                        plan: plan, removable: renderer.scriptLayerRemovalAdmission
                    )
                    connectedHost.destroyLayer = { id, state in
                        guard state.removeObject(id) else { return false }
                        state.releaseLayerModelData(id)
                        return true
                    }
                    connectedHost.sortLayer = { id, position, state in
                        guard let position = Int32(exactly: position) else { return false }
                        return state.sortObject(id, to: position)
                    }
                    if var modelData = connectedHost.modelData {
                        modelData.admitShape = renderer.scriptModelDataAdmission
                        connectedHost.modelData = modelData
                    } else {
                        connectedHost.modelData = renderer.scriptModelDataProvider
                    }
                    let script = try WPEParitySceneScript(
                        document: document, state: renderer.instance.state, assets: assets,
                        canvasSize: renderer.pathCamera.size,
                        screenResolution: SIMD2(Float(target.width), Float(target.height)),
                        materialConstants: plan.materialConstants, resolvedEffectRecords: plan.scene.resolvedEffectRecords,
                        fieldDefaults: renderer.scriptFieldDefaults, host: connectedHost
                    )
                    // Shader compilation is async, so createModelData cannot get-or-load a registered material on demand.
                    var seen = Set(precached)
                    let registered = script.engine.bindings.flatMap(\.registeredAssets).map(\.path).filter {
                        $0.utf8.starts(with: "materials".utf8) && seen.insert($0).inserted
                    }
                    try await preloadMaterials(registered, source: "registered", renderer: renderer, shaders: shaders,
                                               generation: generation)
                    // Neither util model needs a scene template, so a synchronous createLayer finds their programs.
                    if Self.scriptsCreateLayers(document) {
                        for model in ["models/util/solidlayer.json", "models/util/composelayer.json"] {
                            do {
                                try await renderer.precacheCreatedImage(model, shaders: shaders)
                            } catch let error as CancellationError {
                                throw error
                            } catch {
                                Logger.warning("Parity created image \(model) skipped: \(error)", category: .wpeRender)
                            }
                            guard generation == loadGeneration else { throw CancellationError() }
                        }
                    }
                    try withScriptSound(script.engine) { try renderer.attachScript(script) }
                    try deliverScriptLanguage(to: renderer)
                } catch let error as CancellationError {
                    throw error
                } catch let error as WPEParityScriptEngine.Failure where error != .missingBaseClasses || requireCompleteShaders || shaderPolicy == .precompiledOnly {
                    throw error
                } catch {
                    loadDiagnostics = .other(layer: "scripts", message: String(describing: error))
                    Logger.warning("Parity scene scripts unavailable: \(error)", category: .wpeRender)
                }
            }
            self.renderer = renderer
            cadenceSubmissions?.rendererRevision += 1
            lastTimestamp = nil
        } catch {
            if let preparedSound {
                preparedSound.stop()
                if soundRuntime === preparedSound {
                    soundRuntime = nil
                }
            }
            if generation == loadGeneration, !(error is CancellationError) {
                if case let WPESceneAssetProviderError.fileMissing(path) = error {
                    loadDiagnostics = .fileMissing(layer: "scene", path: path)
                } else {
                    loadDiagnostics = .other(layer: "scene", message: String(describing: error))
                }
                Logger.warning("Parity scene load failed: \(error)", category: .wpeRender)
            }
            throw error
        }
    }

    /// Builds a renderer for the current drawable size and fit mode and swaps it in between two frames. The scene
    /// clock, engine inputs, puppets and particles carry over and sound keeps playing; the video sources carry over.
    /// False when the build failed or a load or cleanup superseded it.
    @discardableResult
    nonisolated(nonsending) func replan() async -> Bool {
        guard let planSource, let previous = renderer else { return false }
        let generation = loadGeneration
        let revision = planRevision
        let isHDR = WPEParityProgramScene.hdrEnabled(document: planSource.document, settings: planSource.settings)
        while true {
            let selection = currentTarget(sceneSize: planSource.sceneSize, isHDR: isHDR,
                                          pixelFormat: planSource.pixelFormat, renderScale: planSource.renderScale)
            let target = selection.target
            guard target != plannedTarget else { return true }
            do {
                #if DEBUG
                if Self.remainingForcedReplanFailuresForTesting > 0 {
                    Self.remainingForcedReplanFailuresForTesting -= 1
                    throw ForcedReplanFailure()
                }
                #endif
                let plan = try await Self.makePlan(document: planSource.document, assets: planSource.assets,
                                                   settings: planSource.settings, target: target,
                                                   preparedScene: reusesPreparedScene ? planSource.preparedScene : nil)
                let renderer = try await WPEParityFrameRenderer(
                    plan: plan, device: device, queue: executor.textureSourceCommandQueue, shaders: planSource.shaders,
                    workshopID: planSource.workshopID, continuing: previous,
                    userPropertiesJSON: scriptUserProperties, textureCompression: planSource.textureCompression,
                    reuseDirectTextExtentLayouts: previous.reusesDirectTextExtentLayouts
                )
                guard generation == loadGeneration, revision == planRevision, self.renderer === previous else { return false }
                // A present may decline scaling or discover a new drawable while this candidate is building.
                let current = currentTarget(sceneSize: planSource.sceneSize, isHDR: isHDR,
                                            pixelFormat: planSource.pixelFormat, renderScale: planSource.renderScale)
                guard current == selection else { continue }
                try withScriptSound(previous.instance.script?.engine) {
                    try renderer.adoptView(from: previous, userPropertiesJSON: scriptUserProperties)
                }
                self.renderer = renderer
                cadenceSubmissions?.rendererRevision += 1
                if reusesPreparedScene {
                    self.planSource?.preparedScene = plan.scene
                }
                plannedTarget = target
                failedReplanTarget = nil
                adoptUpscalePlan(selection.upscale)
                return true
            } catch {
                if generation == loadGeneration, revision == planRevision {
                    failedReplanTarget = target
                    Logger.warning("Parity scene re-plan at \(target.width)x\(target.height) failed: \(error)",
                                   category: .wpeRender)
                }
                return false
            }
        }
    }

    /// Every changed property binds only targets the renderer updates live; an unbound key still reaches the scripts'
    /// event 4 (140181f30.c:535-539).
    func canApplyUserPropertiesLive(_ patch: WPEScenePropertyPatch) -> Bool {
        let bindingsByKey = userPropertyBindings
        return didLoad && patch.changedKeys.allSatisfy { key in
            bindingsByKey[key, default: []].allSatisfy { $0.action == .incremental }
        }
    }

    /// Accepts `patch` when `document`, the scene parsed with its new values, differs from the loaded one only in
    /// live state, text layouts included while they keep the frame graph; the commit applies it.
    func prepareUserProperties(_ patch: WPEScenePropertyPatch, document: WPESceneDocument) -> Bool {
        guard canApplyUserPropertiesLive(patch), let planSource,
              WPEParityUserPropertyUpdate(from: planSource.document, to: document) != nil else { return false }
        pendingUserProperties = (patch, document)
        return true
    }

    /// Writes the prepared change into the running scene before its next frame; later re-plans build from the new
    /// parse. False when `patch` is not the one prepared last.
    func commitUserProperties(_ patch: WPEScenePropertyPatch) -> Bool {
        guard let pending = pendingUserProperties, pending.patch == patch, let renderer, let planSource,
              var update = WPEParityUserPropertyUpdate(from: planSource.document, to: pending.document) else {
            return false
        }
        pendingUserProperties = nil
        let merged = WPEParitySceneScript.userPropertiesJSON(
            scriptUserProperties, values: patch.newValues.filter { patch.changedKeys.contains($0.key) }
        )
        update.resolveMaterialFiles(of: planSource.scene, values: patch.newValues, changed: patch.changedKeys)
        do {
            try withScriptSound(renderer.instance.script?.engine) {
                try renderer.applyUserProperties(update, changedJSON: WPEParitySceneScript.changedUserPropertiesJSON(
                    merged, keys: patch.changedKeys
                ), mergedJSON: merged)
            }
        } catch {
            Logger.warning("Parity user property preparation failed: \(error)", category: .wpeRender)
            return false
        }
        for write in update.sounds {
            soundRuntime?.setVolume(Double(write.volume), forSoundID: write.id)
        }
        scriptUserProperties = merged
        planRevision &+= 1
        renderer.cancelVideoAdmission()
        self.planSource = PlanSource(document: pending.document, scene: planSource.scene, preparedScene: nil,
                                     assets: planSource.assets,
                                     settings: planSource.settings, shaders: planSource.shaders,
                                     workshopID: planSource.workshopID, sceneSize: planSource.sceneSize,
                                     pixelFormat: planSource.pixelFormat, renderScale: planSource.renderScale,
                                     textureCompression: planSource.textureCompression)
        return true
    }

    /// The cursor follows only with mouse interaction on and over
    /// the picture, else it rests at the centre. Queued left-button edges go to the renderer in order, so a press
    /// and release between two frames both reach the scripts. The position is backbuffer UV with a top-left origin.
    func pointerInput(_ mailbox: WPEPointerMailbox) -> (position: SIMD2<Double>, buttonDown: Bool) {
        let centre = SIMD2<Double>(0.5, 0.5)
        let offScene = SIMD2<Float>(-1000, -1000)
        scriptPointer = nil
        let reading = mailbox.read()
        guard let renderer, let plannedTarget else { return (centre, false) }
        let batch = mailbox.takeButtonEvents(through: reading.buttonCursor)
        let present = WPEPresentUniforms.make(
            fitMode: plannedTarget.presentFit, sourceWidth: plannedTarget.width, sourceHeight: plannedTarget.height,
            targetWidth: Int(drawableSize.width), targetHeight: Int(drawableSize.height)
        )
        if batch.cancelled {
            renderer.buttonEdges.removeAll()
            if edgeButtonDown {
                renderer.buttonEdges.append((offScene, false))
            }
            edgeButtonDown = false
        }
        for edge in batch.edges {
            let inScene = edge.isInsideView ? present.scenePointer(fromDrawablePointer: edge.frame.position) : nil
            let down = edge.frame.isDown && inScene != nil
            guard down != edgeButtonDown else { continue }
            renderer.buttonEdges.append((inScene.map { SIMD2<Float>($0) } ?? offScene, down))
            edgeButtonDown = down
        }
        guard reading.pointerSample.isInsideView,
              let inScene = present.scenePointer(fromDrawablePointer: reading.pointerSample.position)
        else { return (centre, edgeButtonDown) }
        // With follow off, a clicked layer would otherwise see the cursor leave for the centre right after the click.
        scriptPointer = mouseInteractionEnabled || reading.clickCaptureEnabled ? inScene : centre
        return (mouseInteractionEnabled ? inScene : centre, edgeButtonDown)
    }

    /// Drawable-UV bounds (top-left origin) of the layers the last cursor pass found taking the left button; a rect
    /// over 30% of the view is left out.
    func interactiveZones() -> [CGRect] {
        guard let renderer, let plannedTarget,
              let quads = renderer.instance.script?.buttonQuads(state: renderer.instance.state), !quads.isEmpty else { return [] }
        let present = WPEPresentUniforms.make(
            fitMode: plannedTarget.presentFit, sourceWidth: plannedTarget.width, sourceHeight: plannedTarget.height,
            targetWidth: Int(drawableSize.width), targetHeight: Int(drawableSize.height)
        )
        let pixels = SIMD2<Double>(renderer.logicalSize)
        let view = CGRect(x: 0, y: 0, width: 1, height: 1)
        var zones: [CGRect] = []
        for quad in quads {
            let corners = [quad.0, quad.1, quad.2, quad.3].map {
                present.drawablePointer(fromScenePointer: SIMD2<Double>($0) / pixels)
            }
            let low = corners.dropFirst().reduce(corners[0]) { pointwiseMin($0, $1) }
            let high = corners.dropFirst().reduce(corners[0]) { pointwiseMax($0, $1) }
            let zone = CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y).intersection(view)
            let area = zone.isNull ? 0 : zone.width * zone.height
            guard area > 0, area <= 0.30 else { continue }
            zones.append(zone)
        }
        return zones.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// Renders one frame and presents it into `layer`'s next drawable as the fit mode's target asks. `timestamp` is
    /// the display link's; `pointer` is backbuffer UV with a top-left origin. Returns the committed present command
    /// buffer, or nil when nothing was presented.
    @discardableResult
    func renderAndPresentFrame(layer: CAMetalLayer, timestamp: CFTimeInterval, pointer: SIMD2<Double>,
                               buttonDown: Bool = false, audio: AudioSpectrumFrame? = nil,
                               date: Date = Date()) -> MTLCommandBuffer? {
        cadenceSubmissions?.attempts += 1
        guard let renderer, let plannedTarget,
              encodeFrame(renderer, timestamp: timestamp, pointer: pointer, buttonDown: buttonDown, audio: audio,
                          date: date) else { return nil }
        let backbuffer = renderer.backbuffer
        let sceneBuffer = SubmittedBuffer(buffer: submittedSceneBuffer)
        // Same queue as the frame, so the present reads the finished backbuffer.
        guard let commandBuffer = executor.textureSourceCommandQueue.makeCommandBuffer() else { return nil }
        let state = presentState
        let generation = loadGeneration
        state.begin()
        defer {
            // Registered after the present's own handler, so readiness is recorded before the count drops.
            commandBuffer.addCompletedHandler { _ in state.end() }
            commandBuffer.commit()
            cadenceSubmissions?.presentCommitted += 1
            if executor.takePresentSideDemotion() {
                executor.releaseRenderScaleDependentResources()
            }
        }
        do {
            let presented = try executor.encodePresent(
                texture: backbuffer, layer: layer, fitMode: plannedTarget.presentFit,
                colorTransfer: renderer.colorTransfer,
                presentCompletion: { _, present, release in
                    release()
                    if present.status == .error {
                        state.recordGPUFailure(generation: generation, reason: present.error?.localizedDescription ?? "Present command buffer failed")
                    }
                    state.record(generation: generation, succeeded: present.status == .completed && sceneBuffer.succeeded,
                                 cadencePresent: true)
                },
                into: commandBuffer
            )
            didLogFrameFailure = false
            if presented {
                cadenceSubmissions?.presentScheduled += 1
                updateSurfaceGeometry(drawableSize: executor.lastPresentedDrawableSize)
            } else {
                cadenceSubmissions?.drawableMisses += 1
            }
            return presented ? commandBuffer : nil
        } catch {
            cadenceSubmissions?.presentErrors += 1
            logFrameFailure(error)
            return nil
        }
    }

    /// The span producer's frame: renders as `renderAndPresentFrame` does, then copies the backbuffer into a pooled
    /// output texture that `frames` publishes once the copy completes, as `renderAndPublishSpanFrame` of the old
    /// renderer. Returns the committed copy command buffer, or nil when nothing was published.
    @discardableResult
    func renderAndPublishSpanFrame(to frames: WPESceneSpanFrames, timestamp: CFTimeInterval,
                                   pointer: SIMD2<Double>, buttonDown: Bool = false,
                                   audio: AudioSpectrumFrame? = nil, date: Date = Date()) -> MTLCommandBuffer? {
        guard let renderer, let plannedTarget else { return nil }
        let backbuffer = renderer.backbuffer
        let size = CGSize(width: backbuffer.width, height: backbuffer.height)
        executor.currentOutputPixelFormat = backbuffer.pixelFormat
        let output: MTLTexture
        do {
            // Taken before the frame, so a pool full of member reads skips the frame rather than its scene time.
            output = try executor.makeOutputTexture(size: size)
        } catch is WPEMetalFrameInFlightBudgetExhausted {
            return nil
        } catch {
            logFrameFailure(error)
            return nil
        }
        guard encodeFrame(renderer, timestamp: timestamp, pointer: pointer, buttonDown: buttonDown, audio: audio,
                          date: date),
            let commandBuffer = executor.textureSourceCommandQueue.makeCommandBuffer(),
            let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        let sceneBuffer = SubmittedBuffer(buffer: submittedSceneBuffer)
        blit.copy(from: backbuffer, to: output)
        blit.endEncoding()
        spanFrameSequence &+= 1
        let frame = WPESceneSpanFrame(texture: output, generation: loadGeneration, sequence: spanFrameSequence,
                                      sourceSize: size, fitMode: plannedTarget.presentFit,
                                      colorTransfer: renderer.colorTransfer, tracker: executor.presentTracker)
        let state = presentState
        state.begin()
        commandBuffer.addCompletedHandler { commandBuffer in
            if commandBuffer.status == .completed, sceneBuffer.succeeded {
                frames.publish(frame, generation: frame.generation, sequence: frame.sequence)
            } else {
                state.record(generation: frame.generation, succeeded: false)
            }
            state.end()
        }
        commandBuffer.commit()
        didLogFrameFailure = false
        return commandBuffer
    }

    nonisolated(nonsending) func renderMovieFrame(into destination: WPEMetalPresenter.PresentCompletionTexture,
                                                  timestamp: CFTimeInterval) async throws {
        try Task.checkCancellation()
        guard let renderer, let plannedTarget else { throw WPEMetalRenderError.noRenderablePasses }
        var encoded = encodeFrame(renderer, timestamp: timestamp, pointer: SIMD2(0.5, 0.5), buttonDown: false,
                                  audio: nil, date: Date(), forceExternalFrame: true)
        if !encoded, pendingVideoAdmissionID != nil {
            guard try await preparePendingVideos() else { throw CancellationError() }
            try Task.checkCancellation()
            guard self.renderer === renderer else { throw CancellationError() }
            encoded = encodeFrame(renderer, timestamp: timestamp, pointer: SIMD2(0.5, 0.5), buttonDown: false,
                                  audio: nil, date: Date(), forceExternalFrame: true, resumingVideoFrame: true)
        }
        guard encoded else {
            if let runtimeFailure {
                throw WPEParityFrameRenderError.requiredShaderUnavailable(runtimeFailure)
            }
            throw WPEMetalRenderError.commandBufferFailed
        }
        let scene = SubmittedBuffer(buffer: submittedSceneBuffer)
        guard let command = executor.textureSourceCommandQueue.makeCommandBuffer() else {
            throw WPEMetalRenderError.commandBufferFailed
        }
        let upscaled = try executor.encodeUpscaledPresent(source: renderer.backbuffer, target: destination.texture,
                                                          fitMode: plannedTarget.presentFit,
                                                          colorTransfer: renderer.colorTransfer, into: command)
        if !upscaled {
            let size = CGSize(width: destination.texture.width, height: destination.texture.height)
            if executor.upscalePlan.isActive, executor.upscalePlan.declineIsConclusive(forDrawableSize: size) {
                executor.upscalePlan = executor.upscalePlan.demotedToNative()
            }
            try executor.encodePresentPass(source: renderer.backbuffer, target: destination.texture,
                                           fitMode: plannedTarget.presentFit,
                                           worldSourceSize: CGSize(width: plannedTarget.width, height: plannedTarget.height),
                                           uniforms: nil, colorTransfer: renderer.colorTransfer, into: command)
        }
        let state = presentState
        let generation = loadGeneration
        state.begin()
        let succeeded = await withCheckedContinuation { continuation in
            command.addCompletedHandler { buffer in
                let succeeded = buffer.status == .completed && scene.succeeded
                if buffer.status == .error {
                    state.recordGPUFailure(generation: generation, reason: buffer.error?.localizedDescription ?? "Movie frame failed")
                }
                state.record(generation: generation, succeeded: succeeded)
                state.end()
                continuation.resume(returning: succeeded)
            }
            command.commit()
        }
        guard succeeded else { throw WPEMetalRenderError.commandBufferFailed }
        try Task.checkCancellation()
    }

    func recordSpanPresent(_ result: WPEFrameReadinessResult) {
        presentState.record(generation: result.generation, succeeded: result.renderCompleted && result.presentCompleted)
    }

    /// Steps the scene clock and commits one frame into the backbuffer; false when nothing was committed.
    private func encodeFrame(_ renderer: WPEParityFrameRenderer, timestamp: CFTimeInterval, pointer: SIMD2<Double>,
                             buttonDown: Bool, audio: AudioSpectrumFrame?, date: Date,
                             forceExternalFrame: Bool = false, resumingVideoFrame: Bool = false) -> Bool {
        submittedSceneBuffer = nil
        guard runtimeFailure == nil else { return false }
        // The first frame after load or resume steps by zero, so a stopped display link's gap is not scene time.
        let elapsed = lastTimestamp.map { max(timestamp - $0, 0) } ?? 0
        if !resumingVideoFrame {
            lastTimestamp = timestamp
            soundRuntime?.advance(by: elapsed)
        }
        let backbuffer = renderer.backbuffer
        let pixels = SIMD2(Double(backbuffer.width), Double(backbuffer.height))
        let input = WPEParityFrameInput(cursor: SIMD2<Float>(pointer * pixels),
                                        scriptCursor: scriptPointer.map { SIMD2<Float>($0 * pixels) },
                                        buttonDown: buttonDown, audio: audio.map { ($0.left, $0.right) }, date: date)
        do {
            let start = CACurrentMediaTime()
            let state = presentState
            let generation = loadGeneration
            let countsCadence = cadenceSubmissions != nil
            let completion: @Sendable (MTLCommandBuffer) -> Void = { buffer in
                if countsCadence {
                    state.recordCadenceScene(generation: generation, succeeded: buffer.status == .completed)
                }
                if buffer.status == .error {
                    state.recordGPUFailure(generation: generation, reason: buffer.error?.localizedDescription ?? "Scene command buffer failed")
                }
            }
            let submission = try withScriptSound(renderer.instance.script?.engine) {
                if resumingVideoFrame {
                    try renderer.resumeVideoFrame(completion: completion)
                } else {
                    try renderer.encodeFrame(elapsed: elapsed, paused: paused, forceExternalFrame: forceExternalFrame,
                                             input: input, completion: completion)
                }
            }
            encodeSeconds += CACurrentMediaTime() - start
            encodeCount += 1
            if let soundRuntime {
                renderer.takeScriptSoundVolumes { id, volume in
                    soundRuntime.setVolume(Double(volume), forSoundID: id)
                }
                renderer.takeScriptSoundBounds { id, minimum, maximum in
                    soundRuntime.setRandomDelay(minTime: minimum, maxTime: maximum, forSoundID: id)
                }
                renderer.takeSoundVisibility { id, visible in soundRuntime.setVisible(visible, forSoundID: id) }
            }
            guard case let .committed(commandBuffer) = submission else {
                cadenceSubmissions?.sceneSkipped += 1
                return false
            }
            cadenceSubmissions?.sceneCommitted += 1
            submittedSceneBuffer = commandBuffer
            return true
        } catch {
            cadenceSubmissions?.sceneErrors += 1
            if error is WPEParityScriptEngine.Failure {
                recordScriptFailure(error)
            }
            logFrameFailure(error)
            return false
        }
    }

    func setSceneScriptLanguage(_ language: String) {
        guard sceneScriptLanguage != language else { return }
        sceneScriptLanguage = language
        guard let renderer else { return }
        do { try deliverScriptLanguage(to: renderer) } catch { recordScriptFailure(error) }
    }

    private func deliverScriptLanguage(to renderer: WPEParityFrameRenderer) throws {
        guard let language = sceneScriptLanguage, deliveredScriptLanguage != language,
              let script = renderer.instance.script,
              let data = try? JSONSerialization.data(withJSONObject: ["language": language]),
              let payload = String(data: data, encoding: .utf8) else { return }
        withScriptSound(script.engine) {
            script.engine.dispatch(.applyGeneralSettings, payloadJSON: payload, state: &renderer.instance.state)
        }
        if let failure = script.engine.executionFailure {
            throw failure
        }
        deliveredScriptLanguage = language
    }

    private func recordScriptFailure(_ error: any Error) {
        let message = String(describing: error)
        runtimeFailure = message
        loadDiagnostics = .other(layer: "scripts", message: message)
        soundRuntime?.pause()
        presentState.record(generation: loadGeneration, succeeded: false)
    }

    /// ISound calls reach the sound runtime only while `body` runs; script volume writes still drain at frame end.
    private func withScriptSound<Result>(_ engine: WPEParityScriptEngine?, _ body: () throws -> Result) rethrows
        -> Result {
        guard let engine else { return try body() }
        return try engine.withSoundConsumers(volume: { _, _ in }, command: {
            soundRuntime?.setRandomDelay(minTime: $2.minTime.map(Double.init), maxTime: $2.maxTime.map(Double.init),
                                         forSoundID: $0)
            return soundRuntime?.applyScriptSoundCommand($1, forSoundID: $0, volume: $2.volume) ?? false
        }, body: body)
    }

    /// A private copy of the presented backbuffer, encoded on the frame queue so the next frame cannot overwrite it
    /// first; nil before a frame was presented or when the GPU failed.
    nonisolated(nonsending) func copyPresentedBackbuffer() async -> WPEMetalTextureSnapshotter.SnapshotSource? {
        guard hasPresentedFrame else { return nil }
        let span = spanFrames?.latest()
        let presented = span.map { WPEMetalTextureSnapshotter.SnapshotSource(texture: $0.texture,
                                                                             colorTransfer: $0.colorTransfer) }
            ?? executor.lastPresentPass.map { WPEMetalTextureSnapshotter.SnapshotSource(texture: $0.source,
                                                                                        colorTransfer: $0.colorTransfer) }
        guard let presented else { return nil }
        let source = presented.texture
        guard let copy = device.makeTexture(descriptor: Self.copyDescriptor(source)),
              let commandBuffer = executor.textureSourceCommandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        copy.label = "parity.backbufferCopy"
        blit.copy(from: source, to: copy)
        blit.endEncoding()
        let result = WPEMetalTextureSnapshotter.SnapshotSource(texture: copy, colorTransfer: presented.colorTransfer)
        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { commandBuffer in
                withExtendedLifetime(span) {}
                continuation.resume(returning: commandBuffer.status == .completed ? result : nil)
            }
            commandBuffer.commit()
        }
    }

    /// Replays the last present pass into a texture, as `WPEMetalPresenter.encodeDisplayedFrameCapture` does, but
    /// on the frame queue that writes the backbuffer. `completion` runs on a Metal callback thread.
    func captureDisplayedFrame(colorSpace: CGColorSpace?,
                               completion: @escaping @Sendable (WPEDisplayedFrameCapture?) -> Void) {
        guard hasPresentedFrame else {
            completion(nil)
            return
        }
        executor.encodeDisplayedFrameCapture(colorSpace: colorSpace,
                                             queue: executor.textureSourceCommandQueue, completion: completion)
    }

    private static func copyDescriptor(_ source: MTLTexture) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat, width: source.width, height: source.height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .private
        return descriptor
    }

    /// `.suspended` ramps scene time to a hold; `.quality` ramps it back.
    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        paused = profile == .suspended
        renderer?.applyPerformanceProfile(profile)
        if paused {
            soundRuntime?.pause()
        } else {
            lastTimestamp = nil
            soundRuntime?.resume()
        }
    }

    func setAudioMuted(_ muted: Bool) {
        audioMuted = muted
        soundRuntime?.setMuted(muted)
    }

    func setAudioVolume(_ volume: Double) {
        audioVolume = volume
        soundRuntime?.setMasterVolume(effectiveAudioVolume)
    }

    private var effectiveAudioVolume: Double {
        WPEEngineAudioSettings.effectiveVolume(master: audioVolume, preset: audioPreset)
    }

    /// A sizeless report means "not laid out yet", until the surface reports usable geometry.
    func updateSurfaceGeometry(drawableSize: CGSize) {
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }
        self.drawableSize = drawableSize
    }

    func setPresentFitMode(_ mode: WPEPresentFitMode) {
        fitMode = mode
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        mouseInteractionEnabled = enabled
    }

    func setFrameRateCeiling(_ framesPerSecond: Int) {
        userPreferredFPS = max(1, framesPerSecond)
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        adaptiveThrottleActive = active
    }

    /// WPE has no letterbox: cover is its default alignment, which crops the canvas to the target aspect about
    /// its centre, and stretch is mode 2, which never crops. Contain renders the largest fit of the scene's aspect and
    /// center the scene's ortho size; the present boxes or crops them.
    static func renderTarget(fitMode: WPEPresentFitMode, drawableSize: CGSize,
                             sceneSize: SIMD2<Float>) -> RenderTarget {
        let drawable = SIMD2(Double(drawableSize.width), Double(drawableSize.height))
        let scene = SIMD2(Double(sceneSize.x), Double(sceneSize.y))
        func target(_ size: SIMD2<Double>, _ alignment: WPEParityCameraAlignment,
                    _ presentFit: WPEPresentFitMode) -> RenderTarget {
            RenderTarget(width: max(1, Int(size.x.rounded())), height: max(1, Int(size.y.rounded())),
                         alignment: alignment, presentFit: presentFit)
        }
        let fit = min(drawable.x / scene.x, drawable.y / scene.y)
        return switch fitMode {
        case .cover: target(drawable, WPEParityCameraAlignment(mode: 0), .stretch)
        case .stretch: target(drawable, .noCrop, .stretch)
        case .contain: target(scene * fit, .noCrop, .contain)
        case .center: target(scene, .noCrop, .center)
        }
    }

    private func currentTarget(sceneSize: SIMD2<Float>, isHDR: Bool,
                               pixelFormat: MTLPixelFormat, renderScale: Double)
        -> (target: RenderTarget, upscale: WPEMetalUpscalePlan) {
        var target = Self.renderTarget(fitMode: fitMode, drawableSize: drawableSize, sceneSize: sceneSize)
        let fresh = WPEMetalUpscalePlan.make(
            worldCanvas: CGSize(width: target.width, height: target.height), drawableSize: drawableSize,
            fitMode: target.presentFit, isHDR: isHDR, hdrOutputEnabled: pixelFormat == .rgba16Float,
            renderScale: spanFrames == nil ? renderScale : 1,
            deviceSupportsScaler: WPEMetalFXSpatialUpscaler.deviceSupportsSpatialScaler
        )
        let upscale = executor.upscalePlan.adopting(fresh)
        if upscale.isActive {
            target.pixelScale = upscale.renderPixelScale
            let pixels = WPEMetalFXSpatialUpscaler.scaledCanvasSize(
                CGSize(width: target.width, height: target.height), pixelScale: target.pixelScale
            )
            target.physicalSize = SIMD2(Int(pixels.width), Int(pixels.height))
        }
        return (target, upscale)
    }

    /// The allocation verdict and the present consumer capture the same load-time setting.
    private func adoptUpscalePlan(_ plan: WPEMetalUpscalePlan) {
        if plan.isActive {
            if executor.metalFXUpscaler == nil {
                executor.metalFXUpscaler = WPEMetalFXSpatialUpscaler(device: device)
            }
        } else if executor.lastPresentPass?.usedMetalFX != true {
            // An unpresented native replan must still be able to replay the last scaled present for capture.
            executor.metalFXUpscaler = nil
        }
        executor.upscalePlan = plan
    }

    private nonisolated(nonsending) func preloadMaterials(
        _ paths: [String], source: String, renderer: WPEParityFrameRenderer, shaders: WPEParityFrameShaderSource,
        generation: Int
    ) async throws {
        for path in paths {
            do {
                try await renderer.precacheMaterial(path, shaders: shaders)
            } catch let error as CancellationError {
                throw error
            } catch {
                Logger.warning("Parity \(source) material \(path) skipped: \(error)", category: .wpeRender)
            }
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
        }
    }

    static func scriptsCreateLayers(_ document: WPESceneDocument) -> Bool {
        func mentions(_ value: WPESceneJSONValue) -> Bool {
            switch value {
            case let .object(members):
                if case let .string(source)? = members["script"], source.contains("createLayer") {
                    return true
                }
                return members.values.contains(where: mentions)
            case let .array(elements):
                return elements.contains(where: mentions)
            default:
                return false
            }
        }
        return ([document.resolvedGeneralJSON] + document.resolvedObjectsJSON).contains(where: mentions)
    }

    /// String entries of `general.precache` whose first 9 bytes are "materials"; WPE skips the rest (140186c90.c:651-655).
    static func precacheMaterialPaths(_ general: WPESceneJSONValue) -> [String] {
        guard case let .array(entries)? = general["precache"] else { return [] }
        return entries.compactMap { entry in
            guard case let .string(path) = entry, path.utf8.starts(with: "materials".utf8) else { return nil }
            return path
        }
    }

    /// WPE's HLSL carries only the declarations its combos leave live, so a mention is a read.
    static func readsAudio(_ plan: WPEParityFramePlan) -> Bool {
        if plan.document.general.supportsAudioProcessing {
            return true
        }
        let name = Array("g_AudioSpectrum".utf8)
        var searched: Set<WPEHLSLProgram> = []
        return plan.programs.values.contains { program in
            searched.insert(program.hlsl).inserted
                && [program.hlsl.vertex, program.hlsl.geometry, program.hlsl.fragment].contains { stage in
                    stage?.firstRange(of: name) != nil
                }
        }
    }

    /// Drops the renderer and its video players; frames already on the GPU finish but no longer mark readiness.
    func cleanup() {
        mediaMailbox?.invalidateParityGeneration(loadGeneration)
        mediaMailbox = nil
        loadGeneration &+= 1
        presentState.reset(generation: loadGeneration)
        spanFrames?.reset(generation: loadGeneration)
        renderer?.destroyScript()
        renderer?.cancelVideoAdmission()
        renderer = nil
        planSource = nil
        plannedTarget = nil
        failedReplanTarget = nil
        pendingUserProperties = nil
        shaderRequiresAudio = false
        lastTimestamp = nil
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
        edgeButtonDown = false
        scriptPointer = nil
        soundRuntime?.stop()
        soundRuntime = nil
        executor.lastPresentPass = nil
        executor.releaseTransientResources()
    }

    /// Resolving and opening the sound files can stage them out of a package, so it stays off the render actor.
    @concurrent
    private static func prepareSound(_ runtime: WPESoundRuntime, sounds: [WPESceneSoundObject]) async {
        runtime.prepare(sounds: sounds)
    }

    @concurrent
    private static func makePlan(document: WPESceneDocument, assets: WPEParityProgramAssets,
                                 settings: WPEParityProgramSettings,
                                 target: RenderTarget,
                                 preparedScene: WPEParityProgramScene? = nil) async throws -> sending WPEParityFramePlan {
        for image in document.imageObjects {
            let path = image.imageRelativePath
            // The product asset provider admits safe dependency references such as ../<workshop>/models/.
            // Keep lookup admission there rather than treating every dependency path as a local-file escape.
            guard assets.data(path) != nil else { throw WPESceneAssetProviderError.fileMissing(path) }
        }
        return try WPEParityFramePlan(document: document, assets: assets, settings: settings, width: target.width,
                                      height: target.height, alignment: target.alignment,
                                      physicalBackbufferSize: target.pixelSize, pixelScale: target.pixelScale,
                                      preparedScene: preparedScene)
    }

    private func logFrameFailure(_ error: Error) {
        guard !didLogFrameFailure else { return }
        didLogFrameFailure = true
        Logger.warning("Parity scene frame render/present failed: \(error)", category: .wpeRender)
    }
}

/// What QA `runtime.state` reports for a parity screen.
struct WPEParityRuntimeDiagnostics: Sendable, Equatable {
    let loadGeneration: Int
    /// Draw operations of the frame, and the draws the last frame encoded.
    let drawCount: Int
    let encodedDrawCount: Int
    /// Skipped draw operations by `WPEParityFrameSkip.category`.
    let skippedDraws: [String: Int]
    let encodeFrameCPUMeanMilliseconds: Double?
    let arenaBytes: Int
    let heapBytes: Int
    let dedicatedTextureBytes: Int
    let isStatic: Bool
    /// Counts of the loaded scene's shader store, which a resize re-plan keeps.
    let shaderCache: WPEParityShaderStore.Statistics?

    var qaFields: [String: Any] {
        let cache = shaderCache.map { cache in
            ["requests": cache.requests, "memoryHits": cache.memoryHits, "joinedRequests": cache.joinedRequests,
             "diskHits": cache.diskHits, "compilations": cache.compilations,
             "compilationFailures": cache.compilationFailures]
        }
        return [
            "loadGeneration": loadGeneration, "drawCount": drawCount, "encodedDrawCount": encodedDrawCount,
            "skippedDraws": skippedDraws, "encodeFrameCPUMeanMs": encodeFrameCPUMeanMilliseconds ?? NSNull(),
            "arenaBytes": arenaBytes, "heapBytes": heapBytes, "dedicatedTextureBytes": dedicatedTextureBytes,
            "static": isStatic, "shaderCache": cache ?? NSNull(),
        ]
    }
}

/// Everything the render actor needs to build, load and drive a parity scene on a session's surface.
struct WPEParitySceneInputs: Sendable {
    var descriptor: SceneDescriptor
    let entryResolver: SceneResourceResolver
    /// Holds project.json.
    let projectRoot: URL
    let assets: WPEParityProgramAssets
    let settings: WPEParityProgramSettings
    let compiler: (any WPEParityShaderCompiling)?
    var compilerIdentity: String?
    var sceneScriptLanguage: String?
    var shaderOptions = WPEParityShaderCompileOptions()
    var bindingABIVersion = 1
    var shaderPolicy = WPEParityShaderPolicy.compileAllowed
    var diskCache = WPEParityShaderDiskCache.shared
    var requireCompleteShaders = false
    var textureCompression: Bool?
    var renderScaleOverride: Double?
    let device: any MTLDevice
    let presentLayer: WPEPresentLayer
    let mailbox: WPEPointerMailbox
    let surfaceControl: any WPESurfaceControl
    let drawableSize: CGSize
    let pixelFormat: MTLPixelFormat
    /// Resolves the scene's sound files; nil plays no sound.
    var soundResolver: WPEMultiRootResourceResolver?
    var presentFitMode = WPEPresentFitMode.cover
    /// A span group's producer: where its frames go, and its output pool's cap.
    var span: (frames: WPESceneSpanFrames, outputTextureLimit: Int)?
    /// Called on the render actor when the activity changes.
    var onRuntimeActivityChange: (@Sendable (WPESceneRuntimeActivity) -> Void)?
    /// The usershortcut product link's bridge for this scene: engine.openUserShortcut launches through it.
    var userShortcuts: WPEUserShortcutScriptBridge?
    /// Held for the link, which keeps only a weak reference.
    var userShortcutIcons: WPEUserShortcutIconStore?
    /// The now-playing events, started once a script handles them.
    var media: WPESceneMediaEventDispatcher?

    /// The script host of a load: `userPropertiesJSON` from `scriptUserProperties()`.
    func scriptHost(userPropertiesJSON: String) -> WPEParitySceneScript.Host {
        let bridge = userShortcuts
        return WPEParitySceneScript.Host(userPropertiesJSON: userPropertiesJSON,
                                         openUserShortcut: { bridge?.requestLaunch($0) ?? false },
                                         userShortcuts: bridge, media: media?.mailbox)
    }

    /// project.json's properties with the user's values, as engine.userProperties takes them.
    func scriptUserProperties() -> String {
        WPEParitySceneScript.userPropertiesJSON(
            projectRoot: projectRoot,
            values: WallpaperEngineProjectPropertySchema.effectiveSceneValues(descriptor: descriptor,
                                                                              cacheRootURL: projectRoot)
        )
    }

    /// The entry scene parsed with the user's property values; `patch` replaces
    /// the values of its changed keys.
    func makeDocument(changing patch: WPEScenePropertyPatch? = nil) throws -> WPESceneDocument {
        let data = try entryResolver.data(relativePath: descriptor.entryFile)
        var userValues = WallpaperEngineProjectPropertySchema.effectiveSceneValues(descriptor: descriptor,
                                                                                   cacheRootURL: projectRoot)
        for key in patch?.changedKeys ?? [] {
            userValues[key] = patch?.newValues[key]
        }
        let repaired = (try? WallpaperEngineProjectPropertySchema.read(from: projectRoot, includeSchemeColor: true))
            .map { WPESceneParallaxBindingInference.applying(to: data, schema: $0) } ?? data
        return try WPESceneDocumentParser.parse(data: repaired, userValues: userValues)
    }

    /// `assets` whose material files resolve user envelopes with the values `makeDocument` parses with.
    func makeAssets() -> WPEParityProgramAssets {
        var assets = assets
        assets.userValues = WallpaperEngineProjectPropertySchema.effectiveSceneValues(descriptor: descriptor,
                                                                                      cacheRootURL: projectRoot)
        return assets
    }
}
#endif
