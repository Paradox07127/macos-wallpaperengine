#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import Metal
import MetalPerformanceShaders
import os

/// Reads back the renderer's offscreen `MTLTexture` into an `NSImage` for `SceneDetailView` (without it the detail view falls into `.previewUnavailable`).
/// Runs on a dedicated utility-QoS queue so a 4K mip-chain readback never blocks the main thread on multi-display setups; `@unchecked Sendable` because every owned closure is pure or hops onto the main actor explicitly.
final class WPEMetalTextureSnapshotter: @unchecked Sendable {
    static let shared = WPEMetalTextureSnapshotter()

    struct SnapshotSource: @unchecked Sendable {
        let texture: MTLTexture
    }

    private let queue: DispatchQueue

    init(label: String = "com.livewallpaper.wpe-metal.snapshot-readback") {
        self.queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Posters render at pane size, so a 4K rgba16Float readback (~63 MiB) is
    /// pure waste; frames are GPU-scaled to this max dimension before `getBytes`.
    static let posterMaxDimension = 1440

    /// Full-resolution path: debug-artifacts first-frame capture
    /// (`WPEMetalSceneRenderer+Load.swift`) and format tests.
    func snapshot(from texture: MTLTexture) -> NSImage? {
        Self.makeImage(from: texture, maxDimension: nil)
    }

    /// Poster path (`SceneRenderer+LivePoster`): downsampled before readback.
    func snapshotAsync(from source: SnapshotSource) async -> NSImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(
                    returning: Self.makeImage(from: source.texture, maxDimension: Self.posterMaxDimension)
                )
            }
        }
    }

    private static func makeImage(from texture: MTLTexture, maxDimension: Int?) -> NSImage? {
        guard texture.width > 0, texture.height > 0 else {
            return nil
        }

        var texture = texture
        if let maxDimension,
           max(texture.width, texture.height) > maxDimension,
           let scaled = downsampleOnGPU(texture, maxDimension: maxDimension) {
            texture = scaled
        }
        // Output ring is `.private`; `getBytes` needs a CPU-visible staging copy.
        guard let readable = stagedForCPURead(texture) else {
            Logger.warning(
                "[snapshot] CPU staging blit failed (\(texture.width)x\(texture.height), storageMode=\(texture.storageMode.rawValue)) — no poster",
                category: .wpeRender
            )
            return nil
        }
        texture = readable

        let bytes: [UInt8]
        switch texture.pixelFormat {
        case .rgba8Unorm, .rgba8Unorm_srgb:
            bytes = readRGBA8(texture)
        case .bgra8Unorm, .bgra8Unorm_srgb:
            var swizzled = readRGBA8(texture)
            for index in stride(from: 0, to: swizzled.count, by: 4) {
                swizzled.swapAt(index, index + 2)
            }
            bytes = swizzled
        case .rgba16Float:
            // Linear HDR output (bloom scenes): clamp to SDR and sRGB-encode —
            // the same clamp the unorm drawable applies at present, so the poster
            // matches the frame the user sees.
            bytes = convertRGBA16FloatToSRGB8(texture)
        default:
            Logger.warning(
                "[snapshot] unsupported pixel format \(texture.pixelFormat.rawValue) (\(texture.width)x\(texture.height)) — no poster",
                category: .wpeRender
            )
            return nil
        }

        let bytesPerRow = texture.width * 4
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let cgImage = CGImage(
            width: texture.width,
            height: texture.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: texture.width, height: texture.height)
        )
    }

    /// Bilinear-scales on GPU so the CPU readback and conversion touch a pane-sized frame instead of the full render target; returns nil on any failure so the caller falls back to the full-resolution readback.
    /// sRGB variants are scaled through non-sRGB views (raw encoded bytes): sRGB stores are not writable on every Mac GPU family, and the downstream switch reads raw bytes as sRGB-encoded either way.
    private static func downsampleOnGPU(_ texture: MTLTexture, maxDimension: Int) -> MTLTexture? {
        let device = texture.device
        guard MPSSupportsMTLDevice(device) else { return nil }

        let workingFormat: MTLPixelFormat
        switch texture.pixelFormat {
        case .rgba8Unorm_srgb: workingFormat = .rgba8Unorm
        case .bgra8Unorm_srgb: workingFormat = .bgra8Unorm
        default: workingFormat = texture.pixelFormat
        }
        let source: MTLTexture
        if workingFormat == texture.pixelFormat {
            source = texture
        } else if let view = texture.makeTextureView(pixelFormat: workingFormat) {
            source = view
        } else {
            // Apple documents `.pixelFormatView` as required for a differing-format view, and the renderer's output textures are `[.renderTarget, .shaderRead]`. Measured on this GPU family the view is vended anyway (probe: both usages return non-nil), so the sRGB poster path really does reach the GPU downsample here — but that is undocumented tolerance.
            // The output pool is per-frame 4K on the hot path, and adding a usage flag there can cost lossless compression, so the spec-legal degradation is this nil: the caller falls back to the full-resolution readback, which is slower but correct.
            return nil
        }

        let scale = Double(maxDimension) / Double(max(texture.width, texture.height))
        let width = max(1, Int((Double(texture.width) * scale).rounded()))
        let height = max(1, Int((Double(texture.height) * scale).rounded()))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: workingFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let destination = device.makeTexture(descriptor: descriptor),
              let commandQueue = commandQueue(for: device),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return nil
        }
        destination.label = "WPE Metal poster downsample"

        var transform = MPSScaleTransform(
            scaleX: Double(width) / Double(texture.width),
            scaleY: Double(height) / Double(texture.height),
            translateX: 0,
            translateY: 0
        )
        let kernel = MPSImageBilinearScale(device: device)
        withUnsafePointer(to: &transform) { pointer in
            kernel.scaleTransform = pointer
            kernel.encode(
                commandBuffer: commandBuffer,
                sourceTexture: source,
                destinationTexture: destination
            )
        }
        if destination.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: destination)
            blit.endEncoding()
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return destination
    }

    /// Poster refreshes downsample on every capture; creating an MTLCommandQueue
    /// per capture is measurable churn, so one queue per device is cached for the
    /// process lifetime. Lock-protected because `makeImage` is callable from any
    /// thread (poster path runs on the readback queue, tests call it directly).
    private static let downsampleQueues =
        OSAllocatedUnfairLock<[ObjectIdentifier: MTLCommandQueue]>(initialState: [:])

    #if DEBUG
    /// Cache-miss count. Test seam (internal, not private, like `commandQueue(for:)`):
    /// lets tests prove repeated poster downsamples reuse one queue per device.
    static let downsampleQueueCreationsForTesting = OSAllocatedUnfairLock<Int>(initialState: 0)
    #endif

    static func commandQueue(for device: MTLDevice) -> MTLCommandQueue? {
        downsampleQueues.withLock { cache in
            let key = ObjectIdentifier(device)
            if let cached = cache[key] { return cached }
            // Count and cache only a real queue: assigning nil to the subscript
            // would erase the key, so a failed creation must not pretend to be
            // a cache entry (and must not inflate the creation seam).
            guard let queue = device.makeCommandQueue() else { return nil }
            #if DEBUG
            downsampleQueueCreationsForTesting.withLock { $0 += 1 }
            #endif
            queue.label = "com.livewallpaper.wpe-metal.poster-downsample"
            cache[key] = queue
            return queue
        }
    }

    /// CPU-visible copy of a `.private` texture for `getBytes` / debug decode.
    static func stagedForCPURead(_ texture: MTLTexture) -> MTLTexture? {
        if texture.storageMode == .shared { return texture }
        let device = texture.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead] // debug PNG decode samples this copy
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let staging = device.makeTexture(descriptor: descriptor),
              let commandQueue = commandQueue(for: device),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }
        staging.label = "WPE Metal CPU readback staging"
        blit.copy(from: texture, to: staging)
        if staging.storageMode == .managed {
            blit.synchronize(resource: staging)
        }
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        return staging
    }

    private static func readRGBA8(_ texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }

    /// Internal (not private): the renderer's DEBUG PNG dump path reuses it — the
    /// sampling fallback there renders float targets black.
    static func convertRGBA16FloatToSRGB8(_ texture: MTLTexture) -> [UInt8] {
        let pixelCount = texture.width * texture.height
        var halves = [UInt16](repeating: 0, count: pixelCount * 4)
        texture.getBytes(
            &halves,
            bytesPerRow: texture.width * 8,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        var out = [UInt8](repeating: 0, count: pixelCount * 4)
        for pixel in 0..<pixelCount {
            let base = pixel * 4
            for channel in 0..<3 {
                let linear = clampedUnit(Float(Float16(bitPattern: halves[base + channel])))
                out[base + channel] = UInt8(sRGBEncode(linear) * 255 + 0.5)
            }
            let alpha = clampedUnit(Float(Float16(bitPattern: halves[base + 3])))
            out[base + 3] = UInt8(alpha * 255 + 0.5)
        }
        return out
    }

    /// NaN-safe clamp: a NaN texel would trap the UInt8 conversion.
    private static func clampedUnit(_ value: Float) -> Float {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private static func sRGBEncode(_ linear: Float) -> Float {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
}

struct WPEMetalTextureVisualBounds: Codable, Equatable, Sendable, CustomStringConvertible {
    let minX: Int
    let minY: Int
    let maxX: Int
    let maxY: Int

    var width: Int {
        maxX - minX + 1
    }

    var height: Int {
        maxY - minY + 1
    }

    var description: String {
        "bounds=(\(minX),\(minY))-(\(maxX),\(maxY)) size=\(width)x\(height)"
    }

    func coversFullFrame(width: Int, height: Int) -> Bool {
        minX <= 0 && minY <= 0 && maxX >= width - 1 && maxY >= height - 1
    }
}

struct WPEMetalTextureVisualStats: Codable, Equatable, Sendable, CustomStringConvertible {
    let width: Int
    let height: Int
    let nonBlackPixelCount: Int
    let nonTransparentPixelCount: Int
    let nonBlackBounds: WPEMetalTextureVisualBounds?

    var nonBlackCoversFullFrame: Bool {
        nonBlackBounds?.coversFullFrame(width: width, height: height) ?? false
    }

    var oneLineDescription: String {
        let bounds = nonBlackBounds?.description ?? "bounds=nil"
        return "size=\(width)x\(height) nonBlack=\(nonBlackPixelCount) nonTransparent=\(nonTransparentPixelCount) \(bounds)"
    }

    var description: String {
        """
        width: \(width)
        height: \(height)
        nonBlackPixelCount: \(nonBlackPixelCount)
        nonTransparentPixelCount: \(nonTransparentPixelCount)
        nonBlackBounds: \(nonBlackBounds?.description ?? "nil")
        nonBlackCoversFullFrame: \(nonBlackCoversFullFrame)
        """
    }

    static func analyze(
        texture: MTLTexture,
        colorThreshold: UInt8 = 10,
        alphaThreshold: UInt8 = 0
    ) -> WPEMetalTextureVisualStats? {
        guard texture.width > 0, texture.height > 0 else {
            return nil
        }
        guard texture.pixelFormat == .rgba8Unorm || texture.pixelFormat == .rgba8Unorm_srgb else {
            return nil
        }
        // Scene outputs are `.private`.
        guard let texture = WPEMetalTextureSnapshotter.stagedForCPURead(texture) else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = texture.width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )

        var nonBlackPixelCount = 0
        var nonTransparentPixelCount = 0
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min

        for y in 0..<texture.height {
            for x in 0..<texture.width {
                let index = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = bytes[index]
                let g = bytes[index + 1]
                let b = bytes[index + 2]
                let a = bytes[index + 3]
                if a > alphaThreshold {
                    nonTransparentPixelCount += 1
                }
                guard r > colorThreshold || g > colorThreshold || b > colorThreshold else {
                    continue
                }
                nonBlackPixelCount += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        let bounds = minX == Int.max
            ? nil
            : WPEMetalTextureVisualBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
        return WPEMetalTextureVisualStats(
            width: texture.width,
            height: texture.height,
            nonBlackPixelCount: nonBlackPixelCount,
            nonTransparentPixelCount: nonTransparentPixelCount,
            nonBlackBounds: bounds
        )
    }
}
#endif
