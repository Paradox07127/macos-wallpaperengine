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
    let executor: WPEMetalRenderExecutor
    private(set) var renderer: WPEParityFrameRenderer?
    private(set) var didLoad = false
    /// Bumped on load and cleanup, so presents of an older load never count as ready.
    private(set) var loadGeneration = 0
    private(set) var loadDiagnostics: SceneLoadDiagnostic?
    /// Draws whose program did not resolve, compile or link.
    private(set) var shaderErrorSummary: (count: Int, entries: [(shader: String, reason: String)]) = (0, [])
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

    init(device: MTLDevice) throws {
        self.device = device
        executor = try WPEMetalRenderExecutor(device: device)
    }

    /// `document` already carries the user property values. Compiles every program (seconds when the disk cache is
    /// cold); a load superseded by `cleanup()` throws `CancellationError`.
    func load(document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings,
              drawableSize: CGSize, pixelFormat: MTLPixelFormat, compiler: WPEParityHelperShaderCompiler,
              diskCache: WPEParityShaderDiskCache = WPEParityShaderDiskCache()) async throws {
        loadGeneration &+= 1
        let generation = loadGeneration
        presentState.reset(generation: generation)
        didLoad = false
        renderer = nil
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
        do {
            let plan = try await Self.makePlan(document: document, assets: assets, settings: settings,
                                               width: Int(drawableSize.width), height: Int(drawableSize.height))
            let store = WPEParityShaderStore(compiler: compiler, diskCache: diskCache)
            let renderer = try await WPEParityFrameRenderer(
                plan: plan, device: device, queue: executor.textureSourceCommandQueue,
                shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                    bindingABIVersion: 1)
            )
            guard generation == loadGeneration else { throw CancellationError() }
            // Built here so the first present does not compile its pipeline on the frame path.
            _ = try executor.renderPipeline(
                vertexName: "wpe_present_vertex",
                fragmentName: WPEMetalRenderExecutor.presentFragment(source: renderer.backbuffer.pixelFormat),
                colorPixelFormat: pixelFormat
            )
            let shaderErrors = renderer.skipped.sorted { $0.key < $1.key }.compactMap { index, skip in
                switch skip {
                case .program, .noShader, .pipeline:
                    (shader: plan.programs[index]?.shader ?? "operation \(index)", reason: skip.description)
                default:
                    nil
                }
            }
            shaderErrorSummary = (shaderErrors.count, shaderErrors)
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

    /// Renders one frame and presents it stretched into `layer`'s next drawable. `timestamp` is the display link's;
    /// `pointer` is drawable UV with a top-left origin. Returns the committed present command buffer, or nil when
    /// nothing was presented.
    @discardableResult
    func renderAndPresentFrame(layer: CAMetalLayer, timestamp: CFTimeInterval, pointer: SIMD2<Double>,
                               buttonDown: Bool = false, audio: AudioSpectrumFrame? = nil,
                               date: Date = Date()) -> MTLCommandBuffer? {
        guard didLoad, let renderer else { return nil }
        // The first frame after load or resume steps by zero, so a stopped display link's gap is not scene time.
        let elapsed = lastTimestamp.map { max(timestamp - $0, 0) } ?? 0
        lastTimestamp = timestamp
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
                texture: backbuffer, layer: layer, fitMode: .stretch,
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
        if !paused {
            lastTimestamp = nil
        }
    }

    /// Drops the renderer and its video players; frames already on the GPU finish but no longer mark readiness.
    func cleanup() {
        didLoad = false
        loadGeneration &+= 1
        presentState.reset(generation: loadGeneration)
        renderer = nil
        lastTimestamp = nil
        loadDiagnostics = nil
        shaderErrorSummary = (0, [])
        executor.releaseTransientResources()
    }

    @concurrent
    private static func makePlan(document: WPESceneDocument, assets: WPEParityProgramAssets,
                                 settings: WPEParityProgramSettings, width: Int,
                                 height: Int) async throws -> sending WPEParityFramePlan {
        try WPEParityFramePlan(document: document, assets: assets, settings: settings, width: width, height: height)
    }

    private func logFrameFailure(_ error: Error) {
        guard !didLogFrameFailure else { return }
        didLogFrameFailure = true
        Logger.warning("Parity scene frame render/present failed: \(error)", category: .wpeRender)
    }
}
#endif
