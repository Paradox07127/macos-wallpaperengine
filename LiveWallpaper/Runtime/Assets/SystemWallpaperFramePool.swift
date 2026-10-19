import CoreVideo
import Foundation
import Metal

/// IOSurface buffers shared by GPU export and live extension rendering; the caller owns pacing.
final class SystemWallpaperFramePool {
    enum Failure: Error { case bufferUnavailable, poolExhausted }
    struct Frame {
        let buffer: CVPixelBuffer
        let cachedTexture: CVMetalTexture
        let texture: any MTLTexture
    }

    private let size: CGSize
    private let pool: CVPixelBufferPool
    private let cache: CVMetalTextureCache

    init(size: CGSize, device: any MTLDevice) throws {
        self.size = size
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw Failure.bufferUnavailable }
        self.pool = pool
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw Failure.bufferUnavailable }
        self.cache = cache
    }

    func makeFrame() throws -> Frame {
        var buffer: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey as String: 3] as CFDictionary
        var result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &buffer)
        if result == kCVReturnWouldExceedAllocationThreshold {
            // Cached Metal views can retain otherwise-idle buffers beyond the completed GPU write.
            CVMetalTextureCacheFlush(cache, 0)
            result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &buffer)
        }
        if result == kCVReturnWouldExceedAllocationThreshold {
            throw Failure.poolExhausted
        }
        guard result == kCVReturnSuccess,
              let buffer else { throw Failure.bufferUnavailable }
        var cached: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage as String: MTLTextureUsage.renderTarget.rawValue | MTLTextureUsage.shaderRead.rawValue]
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, buffer, attributes as CFDictionary, .bgra8Unorm_srgb, Int(size.width), Int(size.height), 0, &cached
        ) == kCVReturnSuccess, let cached, let texture = CVMetalTextureGetTexture(cached)
        else { throw Failure.bufferUnavailable }
        return Frame(buffer: buffer, cachedTexture: cached, texture: texture)
    }

    /// Encoder/display ownership can outlive append; wait for a buffer instead of growing the pool.
    @MainActor
    func nextFrame() async throws -> Frame {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while true {
            try Task.checkCancellation()
            do {
                return try makeFrame()
            } catch Failure.poolExhausted {
                guard clock.now < deadline else { throw Failure.poolExhausted }
                try await clock.sleep(for: .milliseconds(2))
            }
        }
    }
}
