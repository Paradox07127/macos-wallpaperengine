#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// The TEX file's regions must describe the mip geometry Metal allocates, even
/// when inflate scope leaves some levels without materialized bytes.
enum WPETexMipValidation {
    struct Invalid: Error, LocalizedError, Sendable {
        let detail: String
        var errorDescription: String? { detail }
    }

    struct Layout: Sendable {
        let bytesPerRow: Int
        let bytesPerImage: Int
        let byteCount: Int
    }

    static func geometry(_ levels: [(index: Int, width: Int, height: Int, depth: Int)]) throws {
        guard let first = levels.first, first.width > 0, first.height > 0, first.depth > 0 else {
            throw Invalid(detail: "Missing or nonpositive base mip geometry")
        }
        var width = first.width
        var height = first.height
        var depth = first.depth
        for (position, level) in levels.enumerated() {
            guard level.index == position, level.width == width, level.height == height, level.depth == depth else {
                throw Invalid(detail: "Invalid mip \(position): expected \(width)x\(height)x\(depth) at index \(position)")
            }
            if width == 1, height == 1, depth == 1, position + 1 < levels.count {
                throw Invalid(detail: "Mip chain continues past 1x1x1")
            }
            width = max(width / 2, 1)
            height = max(height / 2, 1)
            depth = max(depth / 2, 1)
        }
    }

    static func layout(format: WPETexFormat, width: Int, height: Int, depth: Int = 1) throws -> Layout {
        guard width > 0, height > 0, depth > 0 else { throw Invalid(detail: "Nonpositive mip dimensions") }
        let columns: Int
        let rows: Int
        let unitBytes: Int
        if let bytes = format.bytesPerPixel {
            columns = width
            rows = height
            unitBytes = bytes
        } else if let bytes = format.bytesPerBlock {
            // Unlike (width + 3) / 4 this cannot overflow on hostile input.
            columns = (width - 1) / 4 + 1
            rows = (height - 1) / 4 + 1
            unitBytes = bytes
        } else {
            throw Invalid(detail: "Unknown mip storage layout")
        }
        let (stride, strideOverflow) = columns.multipliedReportingOverflow(by: unitBytes)
        let (imageBytes, imageOverflow) = stride.multipliedReportingOverflow(by: rows)
        let (count, countOverflow) = imageBytes.multipliedReportingOverflow(by: depth)
        guard !strideOverflow, !imageOverflow, !countOverflow else { throw Invalid(detail: "Mip byte layout overflows Int") }
        return Layout(bytesPerRow: stride, bytesPerImage: imageBytes, byteCount: count)
    }

    /// Preflight the whole volume before allocating even its first decoded mip. Reuse the existing decompression
    /// ceiling for the complete chain, including raw copies; a large LZ4 header must not allocate before this check.
    static func rawVolume(_ mipmaps: [WPETexMipmap], info: WPETexInfo, format: WPETexFormat) throws {
        try geometry(mipmaps.map { ($0.index, $0.width, $0.height, $0.depth) })
        guard let base = mipmaps.first, base.width == info.width, base.height == info.height, base.depth == info.depth else {
            throw Invalid(detail: "Volume base mip does not match TEXI dimensions")
        }
        var total = 0
        for mip in mipmaps {
            let expected = try layout(format: format, width: mip.width, height: mip.height, depth: mip.depth).byteCount
            let (next, overflow) = total.addingReportingOverflow(expected)
            guard !overflow, next <= WPETexCompressedMipmap.maxDecompressedByteCount else {
                throw Invalid(detail: "Volume mip chain exceeds decoded byte budget")
            }
            guard mip.isCompressed ? (mip.decompressedByteCount ?? 0) >= expected : mip.payload.count >= expected else {
                throw Invalid(detail: "Truncated volume mip \(mip.index)")
            }
            total = next
        }
    }

    static func decoded(_ mipmaps: [WPETexTextureMipmap], format: WPETexFormat) throws {
        try geometry(mipmaps.map { ($0.index, $0.width, $0.height, $0.depth) })
        for mip in mipmaps {
            let expected = try layout(format: format, width: mip.width, height: mip.height, depth: mip.depth).byteCount
            // Empty rows are deliberately retained by restricted inflate scopes.
            guard mip.bytes.isEmpty || mip.bytes.count >= expected else {
                throw Invalid(detail: "Truncated mip \(mip.index): \(mip.bytes.count) bytes, expected \(expected)")
            }
        }
    }

    static func streamingImage(_ image: WPETexCompressedImage) throws {
        try geometry(image.payloads.map { ($0.index, $0.width, $0.height, $0.depth) })
        guard let base = image.payloads.first, base.width == image.width, base.height == image.height,
              base.width <= 16384, base.height <= 16384 else {
            throw Invalid(detail: "Invalid streaming image dimensions")
        }
    }

    static func decodedBytes(_ mip: WPETexCompressedMipmap, format: WPETexFormat) throws -> Data {
        let expected = try layout(format: format, width: mip.width, height: mip.height, depth: mip.depth).byteCount
        guard mip.decompressedByteCount >= expected,
              mip.decompressedByteCount <= WPETexCompressedMipmap.maxDecompressedByteCount else {
            throw Invalid(detail: "Invalid decompressed byte count for mip \(mip.index)")
        }
        if mip.isCompressed {
            guard let bytes = mip.lz4Inflated() else { throw Invalid(detail: "Failed mip decompression") }
            return bytes
        }
        guard mip.compressedBytes.count >= mip.decompressedByteCount else {
            throw Invalid(detail: "Truncated streaming mip \(mip.index)")
        }
        return mip.compressedBytes.prefix(mip.decompressedByteCount).materializedData()
    }
}
#endif
