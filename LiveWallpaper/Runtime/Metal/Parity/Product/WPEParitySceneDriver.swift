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
    private let device: MTLDevice
    private let presentState = WPEParityPresentState()
    private var paused = false
    private var lastTimestamp: CFTimeInterval?
    private var didLogFrameFailure = false

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
        didLoad = false
        renderer = nil
        planSource = nil
        plannedTarget = nil
        requiresSystemAudioCapture = false
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
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
        guard didLoad, let renderer, let plannedTarget else { return nil }
        // The first frame after load or resume steps by zero, so a stopped display link's gap is not scene time.
        let elapsed = lastTimestamp.map { max(timestamp - $0, 0) } ?? 0
        lastTimestamp = timestamp
        soundRuntime?.advance(by: elapsed)
        let backbuffer = renderer.backbuffer
        let cursor = SIMD2<Float>(pointer * SIMD2(Double(backbuffer.width), Double(backbuffer.height)))
        let input = WPEParityFrameInput(cursor: cursor, buttonDown: buttonDown,
                                        audio: audio.map { ($0.left, $0.right) }, date: date)
        do {
            guard case .committed = try renderer.encodeFrame(elapsed: elapsed, paused: paused,
                                                             input: input) else { return nil }
        } catch {
            logFrameFailure(error)
            return nil
        }
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
        renderer = nil
        planSource = nil
        plannedTarget = nil
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

/// Everything the render actor needs to build, load and drive a parity scene on a session's surface.
struct WPEParitySceneInputs: Sendable {
    let descriptor: SceneDescriptor
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

    /// The entry scene parsed with the user's property values, as `WPEMetalSceneRenderer`'s load does.
    func makeDocument() throws -> WPESceneDocument {
        let data = try entryResolver.data(relativePath: descriptor.entryFile)
        let userValues = WallpaperEngineProjectPropertySchema.effectiveSceneValues(descriptor: descriptor,
                                                                                   cacheRootURL: projectRoot)
        let repaired = (try? WallpaperEngineProjectPropertySchema.read(from: projectRoot, includeSchemeColor: true))
            .map { WPESceneParallaxBindingInference.applying(to: data, schema: $0) } ?? data
        return try WPESceneDocumentParser.parse(data: repaired, userValues: userValues)
    }
}
#endif
