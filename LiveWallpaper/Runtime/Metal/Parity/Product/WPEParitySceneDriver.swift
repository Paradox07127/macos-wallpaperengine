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
    }

    /// What `load` planned from, so a new size or fit mode re-plans without reloading.
    private struct PlanSource {
        let document: WPESceneDocument
        let assets: WPEParityProgramAssets
        let settings: WPEParityProgramSettings
        let shaders: WPEParityFrameShaderSource
        let workshopID: String?
        let sceneSize: SIMD2<Float>
    }

    let executor: WPEMetalRenderExecutor
    private(set) var renderer: WPEParityFrameRenderer?
    private(set) var didLoad = false
    private(set) var drawableSize = CGSize.zero
    private(set) var fitMode = WPEPresentFitMode.cover
    private(set) var mouseInteractionEnabled = true
    private var userPreferredFPS = WPEMetalSceneRenderer.defaultPreferredFPS
    private var adaptiveThrottleActive = false
    /// The scene flag or a program reading `g_AudioSpectrum*`, as `WPEMetalSceneRenderer.sceneSupportsAudioProcessing`.
    private(set) var requiresSystemAudioCapture = false
    private var planSource: PlanSource?
    private var plannedTarget: RenderTarget?
    /// The loaded scene's user-property bindings; `.incremental` ones apply without a reload.
    private(set) var userPropertyBindings: [String: [WPEScenePropertyBinding]] = [:]
    /// A change `prepareUserProperties` accepted, parsed with its new values, waiting for its commit.
    private var pendingUserProperties: (patch: WPEScenePropertyPatch, document: WPESceneDocument)?
    /// Bumped on load and cleanup, so presents of an older load never count as ready.
    private(set) var loadGeneration = 0
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    /// Draws whose program did not resolve, compile or link.
    private(set) var shaderErrorSummary: (count: Int, entries: [(shader: String, reason: String)]) = (0, [])
    /// The scene's sound layers under WPE's rules; started by `load`, stopped by `cleanup()`.
    private(set) var soundRuntime: WPESoundRuntime?
    /// Kept so mute and volume set before the runtime exists apply once it starts.
    private var audioMuted = false
    private var audioVolume = 1.0
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
        guard didLoad, let renderer else { return nil }
        return WPEParityRuntimeDiagnostics(
            loadGeneration: loadGeneration, drawCount: renderer.drawCount,
            encodedDrawCount: renderer.lastFrameDraws.count,
            skippedDraws: renderer.skipped.values.reduce(into: [:]) { $0[$1.category, default: 0] += 1 },
            encodeFrameCPUMeanMilliseconds: encodeCount == 0 ? nil : encodeSeconds / Double(encodeCount) * 1000,
            arenaBytes: renderer.arenaBytes, heapBytes: renderer.heapBytes,
            dedicatedTextureBytes: renderer.dedicatedTextureBytes, isStatic: renderer.isStatic
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

    /// As `WPEMetalSceneRenderer.effectiveFPS`.
    var effectiveFPS: Int {
        guard adaptiveThrottleActive else { return userPreferredFPS }
        return min(userPreferredFPS, max(WPEMetalSceneRenderer.adaptiveThrottleFloorFPS, userPreferredFPS / 2))
    }

    /// The loaded plan no longer matches the drawable size or fit mode.
    var needsReplan: Bool {
        guard didLoad, let planSource else { return false }
        return plannedTarget != currentTarget(sceneSize: planSource.sceneSize)
    }

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
        workshopID: String? = nil
    ) async throws {
        loadGeneration &+= 1
        let generation = loadGeneration
        presentState.reset(generation: generation)
        spanFrames?.reset(generation: generation)
        didLoad = false
        renderer = nil
        planSource = nil
        plannedTarget = nil
        userPropertyBindings = [:]
        pendingUserProperties = nil
        requiresSystemAudioCapture = false
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
        (encodeSeconds, encodeCount) = (0, 0)
        soundRuntime?.stop()
        soundRuntime = nil
        self.audioPreset = audioPreset
        updateSurfaceGeometry(drawableSize: drawableSize)
        do {
            let sceneSize = WPEParityCamera(document: document, renderTargetSize: SIMD2(1, 1)).size
            let target = currentTarget(sceneSize: sceneSize)
            let plan = try await Self.makePlan(document: document, assets: assets, settings: settings, target: target)
            let store = WPEParityShaderStore(compiler: compiler, diskCache: diskCache)
            let shaders = WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                     bindingABIVersion: 1)
            let renderer = try await WPEParityFrameRenderer(
                plan: plan, device: device, queue: executor.textureSourceCommandQueue, shaders: shaders,
                workshopID: workshopID
            )
            guard generation == loadGeneration else { throw CancellationError() }
            // Built here so the first present does not compile its pipeline on the frame path.
            _ = try executor.renderPipeline(
                vertexName: "wpe_present_vertex",
                fragmentName: WPEMetalRenderExecutor.presentFragment(source: renderer.backbuffer.pixelFormat),
                colorPixelFormat: pixelFormat
            )
            if let soundResolver, !document.soundObjects.isEmpty {
                let runtime = WPESoundRuntime(resolver: soundResolver, rules: .wpe)
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
            requiresSystemAudioCapture = Self.readsAudio(plan)
            planSource = PlanSource(document: document, assets: assets, settings: settings, shaders: shaders,
                                    workshopID: workshopID, sceneSize: sceneSize)
            plannedTarget = target
            userPropertyBindings = WPEParityUserProperties.bindings(document: document)
            self.renderer = renderer
            lastTimestamp = nil
            didLoad = true
        } catch {
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
        guard didLoad, let planSource, let previous = renderer else { return false }
        let target = currentTarget(sceneSize: planSource.sceneSize)
        guard target != plannedTarget else { return true }
        let generation = loadGeneration
        do {
            let plan = try await Self.makePlan(document: planSource.document, assets: planSource.assets,
                                               settings: planSource.settings, target: target)
            let renderer = try await WPEParityFrameRenderer(
                plan: plan, device: device, queue: executor.textureSourceCommandQueue, shaders: planSource.shaders,
                workshopID: planSource.workshopID
            )
            guard generation == loadGeneration, self.renderer === previous else { return false }
            renderer.continueScene(from: previous)
            self.renderer = renderer
            plannedTarget = target
            return true
        } catch {
            if generation == loadGeneration {
                Logger.warning("Parity scene re-plan at \(target.width)x\(target.height) failed: \(error)",
                               category: .wpeRender)
            }
            return false
        }
    }

    /// Every changed property is bound, and only to targets the renderer updates live.
    func canApplyUserPropertiesLive(_ patch: WPEScenePropertyPatch) -> Bool {
        didLoad && patch.changedKeys.allSatisfy { key in
            let bindings = userPropertyBindings[key] ?? []
            return !bindings.isEmpty && bindings.allSatisfy { $0.action == .incremental }
        }
    }

    /// Accepts `patch` when `document`, the scene parsed with its new values, differs from the loaded one only in
    /// live state; the commit applies it.
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
              let update = WPEParityUserPropertyUpdate(from: planSource.document, to: pending.document) else {
            return false
        }
        pendingUserProperties = nil
        renderer.applyUserProperties(update)
        self.planSource = PlanSource(document: pending.document, assets: planSource.assets,
                                     settings: planSource.settings, shaders: planSource.shaders,
                                     workshopID: planSource.workshopID, sceneSize: planSource.sceneSize)
        return true
    }

    /// The old renderer's gates (`sampleFrameContext`): the cursor follows only with mouse interaction on and over
    /// the picture, else it rests at the centre; the left button counts only with click capture on. The position is
    /// backbuffer UV with a top-left origin.
    func pointerInput(_ reading: WPEPointerMailbox.Reading) -> (position: SIMD2<Double>, buttonDown: Bool) {
        let centre = SIMD2<Double>(0.5, 0.5)
        guard let renderer, let plannedTarget, reading.pointerSample.isInsideView,
              let inScene = WPEPresentUniforms.make(
                  fitMode: plannedTarget.presentFit, sourceWidth: renderer.backbuffer.width,
                  sourceHeight: renderer.backbuffer.height, targetWidth: Int(drawableSize.width),
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
        guard didLoad, let renderer, let plannedTarget,
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
        }
        do {
            let presented = try executor.encodePresent(
                texture: backbuffer, layer: layer, fitMode: plannedTarget.presentFit,
                presentCompletion: { _, present, release in
                    release()
                    state.record(generation: generation, succeeded: present.status == .completed)
                },
                into: commandBuffer
            )
            didLogFrameFailure = false
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
        guard didLoad, let renderer, let plannedTarget else { return nil }
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
                                      tracker: executor.presentTracker)
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
            let submission = try renderer.encodeFrame(elapsed: elapsed, paused: paused, input: input)
            encodeSeconds += CACurrentMediaTime() - start
            encodeCount += 1
            guard case .committed = submission else { return false }
            return true
        } catch {
            logFrameFailure(error)
            return false
        }
    }

    /// A private copy of the presented backbuffer, encoded on the frame queue so the next frame cannot overwrite it
    /// first; nil before a frame was presented or when the GPU failed.
    nonisolated(nonsending) func copyPresentedBackbuffer() async -> WPEMetalTextureSnapshotter.SnapshotSource? {
        guard hasPresentedFrame, let source = renderer?.backbuffer,
              let copy = device.makeTexture(descriptor: Self.copyDescriptor(source)),
              let commandBuffer = executor.textureSourceCommandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        copy.label = "parity.backbufferCopy"
        blit.copy(from: source, to: copy)
        blit.endEncoding()
        let result = WPEMetalTextureSnapshotter.SnapshotSource(texture: copy)
        return await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { commandBuffer in
                continuation.resume(returning: commandBuffer.status == .completed ? result : nil)
            }
            commandBuffer.commit()
        }
    }

    /// Replays the last present pass into a texture, as `WPEMetalRenderExecutor.encodeDisplayedFrameCapture` does, but
    /// on the frame queue that writes the backbuffer. `completion` runs on a Metal callback thread.
    func captureDisplayedFrame(colorSpace: CGColorSpace?,
                               completion: @escaping @Sendable (WPEDisplayedFrameCapture?) -> Void) {
        guard hasPresentedFrame, let source = renderer?.backbuffer, let pass = executor.lastPresentPass,
              !pass.usedMetalFX else {
            completion(nil)
            return
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pass.targetPixelFormat, width: pass.targetWidth, height: pass.targetHeight, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = executor.textureSourceCommandQueue.makeCommandBuffer() else {
            completion(nil)
            return
        }
        target.label = "wpe.displayedFrameCapture"
        do {
            try executor.encodePresentPass(source: source, target: target, fitMode: pass.fitMode,
                                           worldSourceSize: pass.worldSourceSize, uniforms: pass.uniforms,
                                           into: commandBuffer)
        } catch {
            completion(nil)
            return
        }
        let capture = WPEDisplayedFrameCapture(
            texture: target, pixelFormat: target.pixelFormat, colorSpace: colorSpace,
            isEDR: WPEDisplayHDROutput.isHDROutput(drawablePixelFormat: target.pixelFormat)
        )
        commandBuffer.addCompletedHandler { commandBuffer in
            completion(commandBuffer.status == .completed ? capture : nil)
        }
        commandBuffer.commit()
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

    /// WPE has no letterbox (R8 Q1): cover is its default alignment, which crops the canvas to the target aspect about
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

    private func currentTarget(sceneSize: SIMD2<Float>) -> RenderTarget {
        Self.renderTarget(fitMode: fitMode, drawableSize: drawableSize, sceneSize: sceneSize)
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
        didLoad = false
        loadGeneration &+= 1
        presentState.reset(generation: loadGeneration)
        spanFrames?.reset(generation: loadGeneration)
        renderer = nil
        planSource = nil
        plannedTarget = nil
        userPropertyBindings = [:]
        pendingUserProperties = nil
        requiresSystemAudioCapture = false
        lastTimestamp = nil
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
        soundRuntime?.stop()
        soundRuntime = nil
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
                               height: target.height, alignment: target.alignment)
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

    var qaFields: [String: Any] {
        [
            "loadGeneration": loadGeneration, "drawCount": drawCount, "encodedDrawCount": encodedDrawCount,
            "skippedDraws": skippedDraws, "encodeFrameCPUMeanMs": encodeFrameCPUMeanMilliseconds ?? NSNull(),
            "arenaBytes": arenaBytes, "heapBytes": heapBytes, "dedicatedTextureBytes": dedicatedTextureBytes,
            "static": isStatic,
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
}
#endif
