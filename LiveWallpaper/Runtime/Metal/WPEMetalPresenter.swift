#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Metal
import MetalKit
import os

extension MTLCommandEncoder {
    /// Avoids building diagnostic strings unless pass labels are enabled.
    func applyTraceLabel(_ makeLabel: @autoclosure () -> String) {
        if WPEMetalPresenter.tracePassLabels {
            label = makeLabel()
        }
    }
}

/// Shared terminal presentation and output lifetime for parity frames and span consumers.
final class WPEMetalPresenter {
    /// Off by default and read once. `defaults write com.loomscreen.pro WPETracePassLabels -bool YES`
    static let tracePassLabels: Bool = {
        let key = "WPETracePassLabels"
        for suite in [UserDefaults.appSuite, UserDefaults.appScoped()] where suite.object(forKey: key) != nil {
            return suite.bool(forKey: key)
        }
        return false
    }()

    static let outputPixelFormat = MTLPixelFormat.rgba8Unorm
    /// `.rgba16Float` for HDR so >1 emissive survives to the bloom prefilter (an 8-bit target clamps at scene write); SDR keeps authored channel numbers in 8-bit UNORM.
    var currentOutputPixelFormat: MTLPixelFormat = WPEMetalPresenter.outputPixelFormat

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let defaultLibrary: MTLLibrary
    private let pipelineCache: WPEMetalPipelineCache
    var linearPresentationTexture: MTLTexture?
    lazy var gpuPassProfiler = WPEMetalPassGPUProfiler.makeIfEnabled(device: device)
    lazy var metalFXUpscaler = WPEMetalFXSpatialUpscaler.makeIfEnabled(device: device)
    var outputTexturePool: [MTLTexture] = []
    var spanOutputTextureLimit: Int?
    var recentOutputTextureIDs: [ObjectIdentifier] = []
    let presentTracker = PresentInFlightTracker()
    static let maxFramesInFlight = 2
    #if DEBUG
    var remainingForcedDrawableMissesForTesting = 0
    #endif

    /// Present completion handlers run on Metal's callback threads while the
    /// pool is consulted from the render thread, so the in-flight refcounts
    /// live behind a lock in a Sendable box the handler can capture.
    final class PresentInFlightTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [ObjectIdentifier: Int] = [:]

        func increment(_ id: ObjectIdentifier) {
            lock.lock()
            counts[id, default: 0] += 1
            lock.unlock()
        }

        func decrement(_ id: ObjectIdentifier) {
            lock.lock()
            if let count = counts[id], count > 1 {
                counts[id] = count - 1
            } else {
                counts.removeValue(forKey: id)
            }
            lock.unlock()
        }

        func isInFlight(_ id: ObjectIdentifier) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return (counts[id] ?? 0) > 0
        }
    }

    /// Metal resources are thread-safe handles, but `MTLTexture` is not annotated
    /// `Sendable` in the SDK. Present completion runs on Metal callback threads,
    /// so wrap the source texture before capturing it in the `@Sendable` handler.
    struct PresentCompletionTexture: @unchecked Sendable {
        let texture: MTLTexture
    }

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw WPEMetalRenderError.commandQueueUnavailable
        }
        guard let library = device.makeDefaultLibrary() else {
            throw WPEMetalRenderError.libraryUnavailable
        }
        self.device = device
        device.shouldMaximizeConcurrentCompilation = true
        commandQueue = queue
        defaultLibrary = library
        pipelineCache = WPEMetalPipelineCache(device: device, library: library)
    }

    var textureSourceCommandQueue: MTLCommandQueue {
        commandQueue
    }

    var upscalePlan: WPEMetalUpscalePlan = .inactive
    var lastPresentedDrawableSize: CGSize = .zero
    var lastPresentPass: WPEPresentPassRecord?
    var drawableAcquisitionSeconds: TimeInterval = 0
    private var presentSideDemotionPending = false

    func takePresentSideDemotion() -> Bool {
        defer { presentSideDemotionPending = false }
        return presentSideDemotionPending
    }

    func notePresentSideDemotion() {
        presentSideDemotionPending = true
    }

    func releaseRenderScaleDependentResources() {
        linearPresentationTexture = nil
        outputTexturePool.removeAll()
        recentOutputTextureIDs.removeAll()
        metalFXUpscaler?.releaseCachedScaler()
    }

    func releaseTransientResources() {
        lastPresentPass = nil
        releaseRenderScaleDependentResources()
    }

    func renderPipeline(vertexName: String = "wpe_fullscreen_vertex", fragmentName: String,
                        colorPixelFormat: MTLPixelFormat = WPEMetalPresenter.outputPixelFormat) throws -> MTLRenderPipelineState {
        try pipelineCache.pipelineState(vertexName: vertexName, fragmentName: fragmentName, colorPixelFormat: colorPixelFormat)
    }

    func makeOutputTexture(size: CGSize) throws -> MTLTexture {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        let pixelFormat = currentOutputPixelFormat
        outputTexturePool.removeAll {
            $0.width != width || $0.height != height || $0.pixelFormat != pixelFormat
        }
        // A capped pool never reaches the append-time trim below, so shed one released stall texture per vend;
        // the last reusable one stays, or a producer holding more than the steady count would reallocate every frame.
        if spanOutputTextureLimit != nil, outputTexturePool.count > Self.steadyOutputTexturePoolSize {
            let reusable = outputTexturePool.indices.filter { isOutputTextureReusable(outputTexturePool[$0]) }
            if reusable.count > 1 {
                outputTexturePool.remove(at: reusable[0])
            }
        }
        if let recycled = outputTexturePool.first(where: isOutputTextureReusable) {
            noteVendedOutputTexture(recycled)
            return recycled
        }
        if let limit = spanOutputTextureLimit, outputTexturePool.count >= limit {
            throw WPEMetalFrameInFlightBudgetExhausted()
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        // `.private` keeps lossless framebuffer compression on Apple Silicon; `.shared` would force CPU-coherent uncompressed stores. CPU read-back consumers blit into their own staging.
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw WPEMetalTextureLoaderError.textureAllocationFailed
        }
        texture.label = "WPE Metal executor output"
        outputTexturePool.append(texture)
        if spanOutputTextureLimit == nil, outputTexturePool.count > Self.steadyOutputTexturePoolSize {
            outputTexturePool.removeFirst()
        }
        noteVendedOutputTexture(texture)
        return texture
    }

    /// Steady state needs 3 (in-render + re-presented latest + history); one spare so a transient stall can exist until ARC reaps it.
    private static let steadyOutputTexturePoolSize = 4

    private func isOutputTextureReusable(_ texture: MTLTexture) -> Bool {
        let id = ObjectIdentifier(texture)
        if recentOutputTextureIDs.contains(id) {
            return false
        }
        return !presentTracker.isInFlight(id)
    }

    private func noteVendedOutputTexture(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        recentOutputTextureIDs.removeAll { $0 == id }
        recentOutputTextureIDs.append(id)
        // Keep the last `maxFramesInFlight` vended targets out of reuse (async render may still be running). Keep at least 2 for static-scene re-present even when only 1 frame is in flight.
        let retain = max(2, Self.maxFramesInFlight)
        if recentOutputTextureIDs.count > retain {
            recentOutputTextureIDs.removeFirst(recentOutputTextureIDs.count - retain)
        }
    }
}
#endif
