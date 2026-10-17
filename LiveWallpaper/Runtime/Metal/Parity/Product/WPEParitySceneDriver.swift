#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore

/// Present readiness, written by command-buffer completion handlers on Metal's callback threads.
final class WPEParityPresentState: Sendable {
    private struct Readiness {
        var generation = 0
        var completed: Int?
        var failed: Int?
        var inFlight = 0
    }

    private let readiness = OSAllocatedUnfairLock(initialState: Readiness())

    var completedGeneration: Int? {
        readiness.withLock(\.completed)
    }

    var failedGeneration: Int? {
        readiness.withLock(\.failed)
    }

    var inFlight: Int {
        readiness.withLock(\.inFlight)
    }

    func reset(generation: Int) {
        readiness.withLock { $0 = Readiness(generation: generation, inFlight: $0.inFlight) }
    }

    func begin() {
        readiness.withLock { $0.inFlight += 1 }
    }

    func end() {
        readiness.withLock { $0.inFlight -= 1 }
    }

    /// A completion from an earlier load is dropped; a later failure never revokes a ready generation.
    func record(generation: Int, succeeded: Bool) {
        readiness.withLock { state in
            guard state.generation == generation else { return }
            if succeeded {
                state.completed = generation
                state.failed = nil
            } else if state.completed != generation {
                state.failed = generation
            }
        }
    }
}

/// Runs one scene on the parity renderer and presents its backbuffer to a layer. Confined to the render actor
/// that owns it, like `WPEMetalSceneRenderer`; only `WPEParityPresentState` is touched from other threads.
final class WPEParitySceneDriver {
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
        let assets: WPEParityProgramAssets
        let settings: WPEParityProgramSettings
        let shaders: WPEParityFrameShaderSource
        let workshopID: String?
        let sceneSize: SIMD2<Float>
        let pixelFormat: MTLPixelFormat
        let renderScale: Double
    }

    let executor: WPEMetalRenderExecutor
    private(set) var renderer: WPEParityFrameRenderer?
    var didLoad: Bool {
        renderer != nil
    }

    private(set) var drawableSize = CGSize.zero
    private(set) var fitMode = WPEPresentFitMode.cover
    private(set) var mouseInteractionEnabled = true
    private(set) var userPreferredFPS = WPEMetalSceneRenderer.defaultPreferredFPS
    private(set) var adaptiveThrottleActive = false
    /// The scene flag or a program reading `g_AudioSpectrum*`, as `WPEMetalSceneRenderer.sceneSupportsAudioProcessing`.
    private var shaderRequiresAudio = false
    var requiresSystemAudioCapture: Bool {
        guard let renderer else { return false }
        return shaderRequiresAudio || renderer.script?.engine.audioResolutions.isEmpty == false
    }

    private var planSource: PlanSource?
    private var plannedTarget: RenderTarget?
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
    private var paused = false
    private var lastTimestamp: CFTimeInterval?
    private var didLogFrameFailure = false
    /// CPU time in `encodeFrame` since the load, for the QA mean.
    private var encodeSeconds = 0.0
    private var encodeCount = 0

    /// The loaded scene changes its frame on its own, as `WPEMetalSceneRenderer.needsContinuousFrames`, or plays
    /// sound, whose random intervals count down by frame time.
    var needsContinuousFrames: Bool {
        didLoad && (renderer?.isStatic == false || soundRuntime != nil)
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
        renderer?.script?.handlesMedia == true
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
        paused && (renderer?.clock.pauseRamp ?? 0) > 0
    }

    /// As `WPEMetalSceneRenderer.effectiveFPS`.
    var effectiveFPS: Int {
        guard adaptiveThrottleActive else { return userPreferredFPS }
        return min(userPreferredFPS, max(WPEMetalSceneRenderer.adaptiveThrottleFloorFPS, userPreferredFPS / 2))
    }

    /// The loaded plan no longer matches the drawable size or fit mode.
    var needsReplan: Bool {
        guard didLoad, let planSource else { return false }
        return plannedTarget != currentTarget(sceneSize: planSource.sceneSize,
                                              isHDR: WPEParityProgramScene.hdrEnabled(document: planSource.document,
                                                                                      settings: planSource.settings),
                                              pixelFormat: planSource.pixelFormat,
                                              renderScale: planSource.renderScale).target
    }

    #if DEBUG
    /// Test seam: remaining `load` calls that throw at once.
    nonisolated(unsafe) static var remainingForcedLoadFailuresForTesting = 0 // serial XCTest sets it before any load
    struct ForcedLoadFailure: Error {}
    #endif

    init(device: MTLDevice) throws {
        self.device = device
        executor = try WPEMetalRenderExecutor(device: device)
    }

    /// `document` already carries the user property values. Compiles every program (seconds when the disk cache is
    /// cold); a load superseded by `cleanup()` throws `CancellationError`. Runs on the caller's actor, which owns the
    /// driver.
    nonisolated(nonsending) func load(
        document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings,
        drawableSize: CGSize, pixelFormat: MTLPixelFormat, compiler: WPEParityHelperShaderCompiler,
        diskCache: WPEParityShaderDiskCache = WPEParityShaderDiskCache(),
        soundResolver: WPEMultiRootResourceResolver? = nil, audioPreset: WPEEngineAudioSettings? = nil,
        workshopID: String? = nil, scriptHost: WPEParitySceneScript.Host = .init(),
        userShortcutIcons: WPEUserShortcutIconStore? = nil,
        particleSeed: UInt32 = WPEParityParticleScene.productSeed()
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
        spanFrames?.reset(generation: generation)
        renderer?.destroyScript()
        renderer = nil
        executor.lastPresentPass = nil
        planSource = nil
        plannedTarget = nil
        executor.upscalePlan = .inactive
        executor.lastPresentedDrawableSize = .zero
        _ = executor.takePresentSideDemotion()
        pendingUserProperties = nil
        shaderRequiresAudio = false
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
        (encodeSeconds, encodeCount) = (0, 0)
        soundRuntime?.stop()
        soundRuntime = nil
        self.audioPreset = audioPreset
        updateSurfaceGeometry(drawableSize: drawableSize)
        var preparedSound: WPESoundRuntime?
        do {
            let sceneSize = WPEParityCamera(document: document, renderTargetSize: SIMD2(1, 1)).size
            let renderScale = WPEMetalFXSpatialUpscaler.renderScale
            let selection = currentTarget(sceneSize: sceneSize,
                                          isHDR: WPEParityProgramScene.hdrEnabled(document: document, settings: settings),
                                          pixelFormat: pixelFormat, renderScale: renderScale)
            let target = selection.target
            let plan = try await Self.makePlan(document: document, assets: assets, settings: settings, target: target)
            let store = WPEParityShaderStore(compiler: compiler, diskCache: diskCache)
            let shaders = WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                     bindingABIVersion: 1)
            let renderer = try await WPEParityFrameRenderer(
                plan: plan, device: device, queue: executor.textureSourceCommandQueue, shaders: shaders,
                particleSeed: particleSeed, workshopID: workshopID, userPropertiesJSON: scriptHost.userPropertiesJSON
            )
            guard generation == loadGeneration else { throw CancellationError() }
            renderer.userShortcutIcons = userShortcutIcons
            // Built here so the first present does not compile its pipeline on the frame path.
            _ = try executor.renderPipeline(
                vertexName: "wpe_present_vertex",
                fragmentName: WPEMetalRenderExecutor.presentFragment(source: renderer.backbuffer.pixelFormat,
                                                                     colorTransfer: renderer.colorTransfer),
                colorPixelFormat: pixelFormat
            )
            if let soundResolver, !document.soundObjects.isEmpty {
                let runtime = WPESoundRuntime(resolver: soundResolver, rules: .wpe)
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
            planSource = PlanSource(document: document, scene: plan.scene, assets: assets, settings: settings,
                                    shaders: shaders, workshopID: workshopID, sceneSize: sceneSize,
                                    pixelFormat: pixelFormat, renderScale: renderScale)
            plannedTarget = target
            adoptUpscalePlan(selection.upscale)
            scriptUserProperties = scriptHost.userPropertiesJSON
            renderer.attachMedia(mediaMailbox, generation: generation)
            if WPEParitySceneScript.hasScripts(document) {
                var hasRegisteredAssets = false
                do {
                    var connectedHost = scriptHost
                    connectedHost.mediaGeneration = generation
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
                        document: document, state: renderer.state, assets: assets,
                        canvasSize: renderer.pathCamera.size,
                        screenResolution: SIMD2(Float(target.width), Float(target.height)),
                        materialConstants: plan.materialConstants, resolvedEffectRecords: plan.scene.resolvedEffectRecords,
                        fieldDefaults: renderer.scriptFieldDefaults, host: connectedHost
                    )
                    hasRegisteredAssets = script.engine.bindings.contains { !$0.registeredAssets.isEmpty }
                    try await script.engine.prepareRegisteredAssets { _, declarations in
                        for declaration in declarations {
                            guard declaration.flag else {
                                throw WPEParityModelDataFailure.safety("registered asset flag consumer is not qualified: \(declaration.path)")
                            }
                            try await renderer.prepareRegisteredModelDataMaterial(declaration.path, shaders: shaders)
                            guard generation == loadGeneration else { throw CancellationError() }
                        }
                    }
                    guard generation == loadGeneration else { throw CancellationError() }
                    // Init waits for the actual registered material/shader preparation (140186c90/172830).
                    try withScriptSound(script.engine) { try renderer.attachScript(script) }
                } catch {
                    if hasRegisteredAssets || error is CancellationError {
                        throw error
                    }
                    loadDiagnostics = .other(layer: "scripts", message: String(describing: error))
                    Logger.warning("Parity scene scripts unavailable: \(error)", category: .wpeRender)
                }
            }
            self.renderer = renderer
            lastTimestamp = nil
        } catch {
            if let preparedSound {
                preparedSound.stop()
                if soundRuntime === preparedSound {
                    soundRuntime = nil
                }
            }
            if generation == loadGeneration, !(error is CancellationError) {
                loadDiagnostics = .other(layer: "scene", message: String(describing: error))
                Logger.warning("Parity scene load failed: \(error)", category: .wpeRender)
            }
            throw error
        }
    }

    /// Builds a renderer for the current drawable size and fit mode and swaps it in between two frames. The scene
    /// clock, engine inputs, puppets and particles carry over and sound keeps playing; video playback restarts.
    /// False when the build failed or a load or cleanup superseded it.
    @discardableResult
    nonisolated(nonsending) func replan() async -> Bool {
        guard let planSource, let previous = renderer else { return false }
        let generation = loadGeneration
        let isHDR = WPEParityProgramScene.hdrEnabled(document: planSource.document, settings: planSource.settings)
        while true {
            let selection = currentTarget(sceneSize: planSource.sceneSize, isHDR: isHDR,
                                          pixelFormat: planSource.pixelFormat, renderScale: planSource.renderScale)
            let target = selection.target
            guard target != plannedTarget else { return true }
            do {
                let plan = try await Self.makePlan(document: planSource.document, assets: planSource.assets,
                                                   settings: planSource.settings, target: target)
                let renderer = try await WPEParityFrameRenderer(
                    plan: plan, device: device, queue: executor.textureSourceCommandQueue, shaders: planSource.shaders,
                    workshopID: planSource.workshopID, continuing: previous,
                    userPropertiesJSON: scriptUserProperties
                )
                guard generation == loadGeneration, self.renderer === previous else { return false }
                // A present may decline scaling or discover a new drawable while this candidate is building.
                let current = currentTarget(sceneSize: planSource.sceneSize, isHDR: isHDR,
                                            pixelFormat: planSource.pixelFormat, renderScale: planSource.renderScale)
                guard current == selection else { continue }
                try withScriptSound(previous.script?.engine) {
                    try renderer.continueScene(from: previous, userPropertiesJSON: scriptUserProperties)
                }
                self.renderer = renderer
                plannedTarget = target
                adoptUpscalePlan(selection.upscale)
                return true
            } catch {
                if generation == loadGeneration {
                    Logger.warning("Parity scene re-plan at \(target.width)x\(target.height) failed: \(error)",
                                   category: .wpeRender)
                }
                return false
            }
        }
    }

    /// Every changed property is bound, and only to targets the renderer updates live.
    func canApplyUserPropertiesLive(_ patch: WPEScenePropertyPatch) -> Bool {
        let bindingsByKey = userPropertyBindings
        return didLoad && patch.changedKeys.allSatisfy { key in
            let bindings = bindingsByKey[key] ?? []
            return !bindings.isEmpty && bindings.allSatisfy { $0.action == .incremental }
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
            try withScriptSound(renderer.script?.engine) {
                try renderer.applyUserProperties(update, changedJSON: WPEParitySceneScript.changedUserPropertiesJSON(
                    merged, keys: patch.changedKeys
                ), mergedJSON: merged)
            }
        } catch {
            Logger.warning("Parity user property preparation failed: \(error)", category: .wpeRender)
            return false
        }
        scriptUserProperties = merged
        self.planSource = PlanSource(document: pending.document, scene: planSource.scene, assets: planSource.assets,
                                     settings: planSource.settings, shaders: planSource.shaders,
                                     workshopID: planSource.workshopID, sceneSize: planSource.sceneSize,
                                     pixelFormat: planSource.pixelFormat, renderScale: planSource.renderScale)
        return true
    }

    /// The old renderer's gates (`sampleFrameContext`): the cursor follows only with mouse interaction on and over
    /// the picture, else it rests at the centre; the left button counts only with click capture on. The position is
    /// backbuffer UV with a top-left origin.
    func pointerInput(_ reading: WPEPointerMailbox.Reading) -> (position: SIMD2<Double>, buttonDown: Bool) {
        let centre = SIMD2<Double>(0.5, 0.5)
        guard renderer != nil, let plannedTarget, reading.pointerSample.isInsideView,
              let inScene = WPEPresentUniforms.make(
                  fitMode: plannedTarget.presentFit, sourceWidth: plannedTarget.width,
                  sourceHeight: plannedTarget.height, targetWidth: Int(drawableSize.width),
                  targetHeight: Int(drawableSize.height)
              ).scenePointer(fromDrawablePointer: reading.pointerSample.position) else { return (centre, false) }
        let buttonDown = reading.clickCaptureEnabled && !reading.buttonsSuppressed && reading.pointerFrame.isDown
        return (mouseInteractionEnabled ? inScene : centre, buttonDown)
    }

    /// Renders one frame and presents it into `layer`'s next drawable as the fit mode's target asks. `timestamp` is
    /// the display link's; `pointer` is backbuffer UV with a top-left origin. Returns the committed present command
    /// buffer, or nil when nothing was presented.
    @discardableResult
    func renderAndPresentFrame(layer: CAMetalLayer, timestamp: CFTimeInterval, pointer: SIMD2<Double>,
                               buttonDown: Bool = false, audio: AudioSpectrumFrame? = nil,
                               date: Date = Date()) -> MTLCommandBuffer? {
        guard let renderer, let plannedTarget,
              encodeFrame(renderer, timestamp: timestamp, pointer: pointer, buttonDown: buttonDown, audio: audio,
                          date: date) else { return nil }
        let backbuffer = renderer.backbuffer
        // Same queue as the frame, so the present reads the finished backbuffer.
        guard let commandBuffer = executor.textureSourceCommandQueue.makeCommandBuffer() else { return nil }
        let state = presentState
        let generation = loadGeneration
        state.begin()
        defer {
            // Registered after the present's own handler, so readiness is recorded before the count drops.
            commandBuffer.addCompletedHandler { _ in state.end() }
            commandBuffer.commit()
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
                    state.record(generation: generation, succeeded: present.status == .completed)
                },
                into: commandBuffer
            )
            didLogFrameFailure = false
            if presented {
                updateSurfaceGeometry(drawableSize: executor.lastPresentedDrawableSize)
            }
            return presented ? commandBuffer : nil
        } catch {
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
        blit.copy(from: backbuffer, to: output)
        blit.endEncoding()
        spanFrameSequence &+= 1
        let frame = WPESceneSpanFrame(texture: output, generation: loadGeneration, sequence: spanFrameSequence,
                                      sourceSize: size, fitMode: plannedTarget.presentFit,
                                      colorTransfer: renderer.colorTransfer, tracker: executor.presentTracker)
        let state = presentState
        state.begin()
        commandBuffer.addCompletedHandler { commandBuffer in
            if commandBuffer.status == .completed {
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

    /// A span member's present of a published frame: readiness, as the old renderer's `recordPresentCompletion`.
    func recordSpanPresent(_ result: WPEFrameReadinessResult) {
        presentState.record(generation: result.generation, succeeded: result.renderCompleted && result.presentCompleted)
    }

    /// Steps the scene clock and commits one frame into the backbuffer; false when nothing was committed.
    private func encodeFrame(_ renderer: WPEParityFrameRenderer, timestamp: CFTimeInterval, pointer: SIMD2<Double>,
                             buttonDown: Bool, audio: AudioSpectrumFrame?, date: Date) -> Bool {
        // The first frame after load or resume steps by zero, so a stopped display link's gap is not scene time.
        let elapsed = lastTimestamp.map { max(timestamp - $0, 0) } ?? 0
        lastTimestamp = timestamp
        soundRuntime?.advance(by: elapsed)
        let backbuffer = renderer.backbuffer
        let cursor = SIMD2<Float>(pointer * SIMD2(Double(backbuffer.width), Double(backbuffer.height)))
        let input = WPEParityFrameInput(cursor: cursor, buttonDown: buttonDown,
                                        audio: audio.map { ($0.left, $0.right) }, date: date)
        do {
            let start = CACurrentMediaTime()
            let submission = try withScriptSound(renderer.script?.engine) {
                try renderer.encodeFrame(elapsed: elapsed, paused: paused, input: input)
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
            guard case .committed = submission else { return false }
            return true
        } catch {
            logFrameFailure(error)
            return false
        }
    }

    /// ISound calls reach the sound runtime only while `body` runs; script volume writes still drain at frame end.
    private func withScriptSound<Result>(_ engine: WPEParityScriptEngine?, _ body: () throws -> Result) rethrows
        -> Result {
        guard let engine else { return try body() }
        return try engine.withSoundConsumers(volume: { _, _ in }, command: {
            soundRuntime?.applyScriptSoundCommand($1, forSoundID: $0, volume: $2.volume) ?? false
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

    /// Replays the last present pass into a texture, as `WPEMetalRenderExecutor.encodeDisplayedFrameCapture` does, but
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

    /// A sizeless report means "not laid out yet", as in `WPEMetalSceneRenderer.updateSurfaceGeometry`.
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
    /// center the scene's ortho size; the present boxes or crops them, as the old renderer does.
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
                executor.metalFXUpscaler = WPEMetalFXSpatialUpscaler(device: device, library: executor.defaultLibrary)
            }
        } else if executor.lastPresentPass?.usedMetalFX != true {
            // An unpresented native replan must still be able to replay the last scaled present for capture.
            executor.metalFXUpscaler = nil
        }
        executor.upscalePlan = plan
    }

    /// WPE's HLSL carries only the declarations its combos leave live, so a mention is a read.
    static func readsAudio(_ plan: WPEParityFramePlan) -> Bool {
        plan.document.general.supportsAudioProcessing || plan.programs.values.contains { program in
            [program.hlsl.vertex, program.hlsl.geometry, program.hlsl.fragment].contains { stage in
                stage.flatMap { String(bytes: $0, encoding: .utf8) }?.contains("g_AudioSpectrum") == true
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
        renderer = nil
        planSource = nil
        plannedTarget = nil
        pendingUserProperties = nil
        shaderRequiresAudio = false
        lastTimestamp = nil
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
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
                                 target: RenderTarget) async throws -> sending WPEParityFramePlan {
        try WPEParityFramePlan(document: document, assets: assets, settings: settings, width: target.width,
                               height: target.height, alignment: target.alignment,
                               physicalBackbufferSize: target.pixelSize, pixelScale: target.pixelScale)
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
    /// Holds project.json, as `WPEMetalSceneRenderer.projectManifestRootURL`.
    let projectRoot: URL
    let assets: WPEParityProgramAssets
    let settings: WPEParityProgramSettings
    let compiler: WPEParityHelperShaderCompiler
    let device: any MTLDevice
    let presentLayer: WPEPresentLayer
    let mailbox: WPEPointerMailbox
    let surfaceControl: any WPESurfaceControl
    let drawableSize: CGSize
    let pixelFormat: MTLPixelFormat
    /// Resolves the scene's sound files, as `WPEMetalSceneRenderer.resourceResolver`; nil plays no sound.
    var soundResolver: WPEMultiRootResourceResolver?
    var presentFitMode = WPEPresentFitMode.cover
    /// A span group's producer: where its frames go, and its output pool's cap as the old renderer's.
    var span: (frames: WPESceneSpanFrames, outputTextureLimit: Int)?
    /// As `WPEMetalSceneRenderer.onRuntimeActivityChange`: called on the render actor when the activity changes.
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
                                         media: media?.mailbox)
    }

    /// project.json's properties with the user's values, as engine.userProperties takes them.
    func scriptUserProperties() -> String {
        WPEParitySceneScript.userPropertiesJSON(
            projectRoot: projectRoot,
            values: WallpaperEngineProjectPropertySchema.effectiveSceneValues(descriptor: descriptor,
                                                                              cacheRootURL: projectRoot)
        )
    }

    /// The entry scene parsed with the user's property values, as `WPEMetalSceneRenderer`'s load does; `patch` replaces
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
