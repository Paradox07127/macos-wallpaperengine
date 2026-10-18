#if !LITE_BUILD
import AppleTextureEncoder
import Foundation
import LiveWallpaperProWPE
import os

/// The compressor and disk cache a loader encodes authored RGBA8 textures with.
struct WPEParityTextureCompression: Sendable {
    static let shared = WPEParityTextureCompression(compressor: WPEParityTextureCompressor(),
                                                    cache: WPEParityCompressedTextureCache())

    let compressor: WPEParityTextureCompressor
    let cache: WPEParityCompressedTextureCache

    /// nil when the texture compression preference is off.
    static func resolve(defaults: UserDefaults = .appScoped()) -> Self? {
        WPEParityResourceSaverFlags.resolve(defaults: defaults).textureCompression ? shared : nil
    }
}

/// Encodes straight-alpha RGBA8 mip chains to ASTC 4x4 LDR and rejects chains that lose too much.
final class WPEParityTextureCompressor: Sendable {
    enum AlphaMode: String, Sendable {
        /// Every texel's alpha is 255.
        case opaque
        case straight
    }

    /// Why a texture kept its authored RGBA8 upload.
    enum Reason: String, Sendable {
        case sourceFormat, device, video, pointSampled, small, hiddenColor, quality, failed
    }

    enum Outcome: Hashable, Sendable {
        case encoded, cached
        case kept(Reason)
    }

    enum Failure: Error {
        case encoderUnavailable
        case encode(level: Int, code: Float)
        case decode(level: Int, code: Int)
        #if DEBUG
        case injected
        #endif
    }

    static let minimumPSNR: Double = 40
    /// Mean square error per block (about 36 dB) at which the encoder stops trying further modes.
    static let errorThreshold: Float = 0x1p-12
    static let blockBytes = 16

    #if DEBUG
    private struct Record {
        var encodes = 0
        var outcomes: [Outcome: Int] = [:]
    }

    private let failsEncoding: Bool
    private let record = OSAllocatedUnfairLock(initialState: Record())

    init(failsEncoding: Bool = false) {
        self.failsEncoding = failsEncoding
    }

    /// Chains passed to the encoder, including ones the PSNR gate then rejected.
    var encodeCount: Int {
        record.withLock { $0.encodes }
    }

    var outcomeCounts: [Outcome: Int] {
        record.withLock { $0.outcomes }
    }

    func note(_ outcome: Outcome) {
        record.withLock { $0.outcomes[outcome, default: 0] += 1 }
    }
    #else
    init() {}
    #endif

    static func blockByteCount(width: Int, height: Int) -> Int {
        blocksPerRow(width) * ((height + 3) / 4) * blockBytes
    }

    static func blocksPerRow(_ width: Int) -> Int {
        (width + 3) / 4
    }

    /// One pass over every level; `hidesColor` is true when a texel with alpha 0 has non-zero RGB.
    static func alphaShape(_ levels: [WPETexTextureMipmap]) -> (opaque: Bool, hidesColor: Bool) {
        var opaque = true
        for level in levels {
            let chunks = level.bytes.withUnsafeBytes { raw in
                perChunk(level.width * level.height) { texels -> (opaque: Bool, hidesColor: Bool) in
                    var opaque = true
                    for texel in texels {
                        // Little-endian RGBA8: alpha is the top byte.
                        let word = raw.loadUnaligned(fromByteOffset: texel * 4, as: UInt32.self)
                        let alpha = word >> 24
                        if alpha != 255 {
                            opaque = false
                            if alpha == 0, word & 0x00FF_FFFF != 0 {
                                return (false, true)
                            }
                        }
                    }
                    return (opaque, false)
                }
            }
            if chunks.contains(where: \.hidesColor) {
                return (false, true)
            }
            opaque = opaque && chunks.allSatisfy(\.opaque)
        }
        return (opaque, false)
    }

    private static let chunkTexels = 1 << 18

    /// `body`'s results for consecutive texel ranges of `count`, computed concurrently.
    private static func perChunk<Result>(_ count: Int, _ body: (Range<Int>) -> Result) -> [Result] {
        let chunks = max(1, (count + chunkTexels - 1) / chunkTexels)
        return [Result](unsafeUninitializedCapacity: chunks) { buffer, initialized in
            guard let base = buffer.baseAddress else { return }
            withoutActuallyEscaping(body) { body in
                // concurrentPerform joins every iteration before returning; each writes only its own slot.
                nonisolated(unsafe) let (base, body) = (base, body)
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let start = chunk * chunkTexels
                    (base + chunk).initialize(to: body(start ..< min(start + chunkTexels, count)))
                }
            }
            initialized = chunks
        }
    }

    /// Each level's blocks, or nil when any level measures below `minimumPSNR`. `levels` hold tightly packed
    /// RGBA8 rows of at least `width * height * 4` bytes.
    func compress(_ levels: [WPETexTextureMipmap], alpha: AlphaMode) throws -> [Data]? {
        #if DEBUG
        record.withLock { $0.encodes += 1 }
        if failsEncoding {
            throw Failure.injected
        }
        #endif
        guard let encoder = at_encoder_create(at_texel_format_rgba8_unorm, at_alpha_not_premultiplied,
                                              at_block_format_astc_4x4_ldr,
                                              alpha == .opaque ? at_alpha_opaque : at_alpha_not_premultiplied,
                                              nil) else {
            throw Failure.encoderUnavailable
        }
        var output: [Data] = []
        for (position, level) in levels.enumerated() {
            var blocks = Data(count: Self.blockByteCount(width: level.width, height: level.height))
            let mse = try encode(encoder, level, into: &blocks, position: position)
            let error = if alpha == .opaque {
                Double(mse)
            } else {
                try Self.alphaWeightedError(encoder, level, blocks: blocks, position: position)
            }
            if error > 0, -10 * log10(error) < Self.minimumPSNR {
                return nil
            }
            output.append(blocks)
        }
        return output
    }

    private func encode(_ encoder: at_encoder_t, _ level: WPETexTextureMipmap, into blocks: inout Data,
                        position: Int) throws -> Float {
        let mse = level.bytes.withUnsafeBytes { texels in
            blocks.withUnsafeMutableBytes { output -> Float in
                guard let source = texels.baseAddress, let destination = output.baseAddress else { return -1 }
                var region = Self.region(source, level)
                var buffer = Self.buffer(destination, level)
                return at_encoder_compress_texels(encoder, &region, &buffer, Self.errorThreshold, at_flags_default)
            }
        }
        guard mse >= 0 else { throw Failure.encode(level: position, code: mse) }
        return mse
    }

    /// Normalized squared error with each texel's RGB error weighted by its source alpha and alpha error by 1.
    private static func alphaWeightedError(_ encoder: at_encoder_t, _ level: WPETexTextureMipmap, blocks: Data,
                                           position: Int) throws -> Double {
        let count = level.width * level.height
        var decoded = Data(count: count * 4)
        let status = blocks.withUnsafeBytes { input in
            decoded.withUnsafeMutableBytes { output -> at_error_t in
                guard let source = input.baseAddress, let destination = output.baseAddress else {
                    return at_error_invalid_parameter
                }
                var buffer = buffer(UnsafeMutableRawPointer(mutating: source), level)
                var region = region(UnsafeRawPointer(destination), level)
                return at_encoder_decompress_texels(encoder, &buffer, &region, at_flags_default)
            }
        }
        guard status == at_error_success else { throw Failure.decode(level: position, code: Int(status.rawValue)) }
        // Both sums are scaled by 255 so they stay integral: Σ(a·ΣΔc² + 255·Δa²) / (Σ(3a + 255) · 255²).
        let sums = level.bytes.withUnsafeBytes { source in
            decoded.withUnsafeBytes { result in
                perChunk(count) { texels -> (error: Int, weight: Int) in
                    var error = 0
                    var weight = 0
                    for offset in stride(from: texels.lowerBound * 4, to: texels.upperBound * 4, by: 4) {
                        let alpha = Int(source[offset + 3])
                        let red = Int(source[offset]) - Int(result[offset])
                        let green = Int(source[offset + 1]) - Int(result[offset + 1])
                        let blue = Int(source[offset + 2]) - Int(result[offset + 2])
                        let alphaDelta = alpha - Int(result[offset + 3])
                        error += alpha * (red * red + green * green + blue * blue) + 255 * alphaDelta * alphaDelta
                        weight += 3 * alpha + 255
                    }
                    return (error, weight)
                }
            }
        }
        let error = sums.reduce(0) { $0 + $1.error }
        let weight = sums.reduce(0) { $0 + $1.weight }
        return Double(error) / (Double(weight) * 255 * 255)
    }

    private static func region(_ texels: UnsafeRawPointer, _ level: WPETexTextureMipmap) -> at_texel_region_t {
        at_texel_region_t(texels: UnsafeMutableRawPointer(mutating: texels),
                          validSize: at_size_t(x: UInt32(level.width), y: UInt32(level.height), z: 1),
                          rowBytes: level.width * 4, sliceBytes: level.width * level.height * 4)
    }

    private static func buffer(_ blocks: UnsafeMutableRawPointer, _ level: WPETexTextureMipmap) -> at_block_buffer_t {
        at_block_buffer_t(blocks: blocks, rowBytes: blocksPerRow(level.width) * blockBytes,
                          sliceBytes: blockByteCount(width: level.width, height: level.height))
    }
}
#endif
