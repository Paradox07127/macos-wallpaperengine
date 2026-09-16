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
        let byteCount: Int
    }

    static func geometry(_ levels: [(index: Int, width: Int, height: Int)]) throws {
        guard let first = levels.first, first.width > 0, first.height > 0 else {
            throw Invalid(detail: "Missing or nonpositive base mip geometry")
        }
        var width = first.width
        var height = first.height
        for (position, level) in levels.enumerated() {
            guard level.index == position, level.width == width, level.height == height else {
                throw Invalid(detail: "Invalid mip \(position): expected \(width)x\(height) at index \(position)")
            }
            if width == 1, height == 1, position + 1 < levels.count {
                throw Invalid(detail: "Mip chain continues past 1x1")
            }
            width = max(width / 2, 1)
            height = max(height / 2, 1)
        }
    }

    static func layout(format: WPETexFormat, width: Int, height: Int) throws -> Layout {
        guard width > 0, height > 0 else { throw Invalid(detail: "Nonpositive mip dimensions") }
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
        let (count, countOverflow) = stride.multipliedReportingOverflow(by: rows)
        guard !strideOverflow, !countOverflow else { throw Invalid(detail: "Mip byte layout overflows Int") }
        return Layout(bytesPerRow: stride, byteCount: count)
    }

    static func decoded(_ mipmaps: [WPETexTextureMipmap], format: WPETexFormat) throws {
        try geometry(mipmaps.map { ($0.index, $0.width, $0.height) })
        for mip in mipmaps {
            let expected = try layout(format: format, width: mip.width, height: mip.height).byteCount
            // Empty rows are deliberately retained by restricted inflate scopes.
            guard mip.bytes.isEmpty || mip.bytes.count >= expected else {
                throw Invalid(detail: "Truncated mip \(mip.index): \(mip.bytes.count) bytes, expected \(expected)")
            }
        }
    }

    static func streamingImage(_ image: WPETexCompressedImage) throws {
        try geometry(image.payloads.map { ($0.index, $0.width, $0.height) })
        guard let base = image.payloads.first, base.width == image.width, base.height == image.height,
              base.width <= 16_384, base.height <= 16_384 else {
            throw Invalid(detail: "Invalid streaming image dimensions")
        }
    }

    static func decodedBytes(_ mip: WPETexCompressedMipmap, format: WPETexFormat) throws -> Data {
        let expected = try layout(format: format, width: mip.width, height: mip.height).byteCount
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
