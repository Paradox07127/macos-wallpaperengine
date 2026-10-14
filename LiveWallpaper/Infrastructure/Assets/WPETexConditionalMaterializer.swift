#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Applies the reader's selected records once at load/reload, before the existing immutable GPU upload.
/// The source spans stay mapped; the resulting mip bytes are released by the existing loader after upload.
enum WPETexConditionalMaterializer {
    static func images(info: WPETexInfo, bitmap: WPETexBitmapBlock, selection: WPETexConditionalSelection,
                       decode: (WPETexMipmap) throws -> Data,
                       inflatePatch: (WPETexConditionalVariantMipmap, WPETexMipmap) throws -> Data) throws -> [[WPETexTextureMipmap]] {
        guard !info.isVolume, !bitmap.isVideoPayload, !bitmap.usesEncodedImagePayload,
              let format = info.format, [.rgba8888, .rg88, .r8].contains(format) else {
            throw WPETexDecodeError.decodeFailed(mipmap: 0, detail: "Unsupported conditional texture format")
        }
        guard let bpp = format.bytesPerPixel else {
            throw WPETexDecodeError.unsupportedFormat(code: info.textureFormatCode)
        }
        let recordsByImage = Dictionary(grouping: bitmap.conditionalRecords, by: \.imageIndex)
        var total = 0
        // Bound the entire materialization before decoding a base mip or allocating a destination.
        for levels in bitmap.frames {
            for mip in levels {
                let count = try WPETexMipValidation.layout(format: format, width: mip.width, height: mip.height).byteCount
                let (next, overflow) = total.addingReportingOverflow(count)
                guard !overflow, next <= WPETexCompressedMipmap.maxDecompressedByteCount else {
                    throw WPETexDecodeError.decodeFailed(mipmap: mip.index, detail: "Conditional texture exceeds decoded byte budget")
                }
                total = next
            }
        }
        return try bitmap.frames.enumerated().map { imageIndex, levels in
            let recordsByMip = Dictionary(grouping: recordsByImage[imageIndex] ?? [], by: \.mipIndex)
            return try levels.map { mip in
                var bytes = try decode(mip)
                let selected = (recordsByMip[mip.index] ?? []).compactMap { record -> (record: WPETexConditionalVariantMipmap, flags: UInt32)? in
                    selection.flagsByVariantID[record.variantID].map { (record, $0) }
                }
                // Native replacement checks byte&2 and the raw patch primitive byte&1. Preserve the
                // complete authored flags; higher bits do not reject an otherwise supported raw patch.
                // Native 15d824..15d875 trims to one record before the last replacement, then its
                // forward loop stops at the first replacement in that suffix. Adjacent replacements
                // therefore do not have simple last-wins semantics.
                let last = selected.lastIndex { $0.flags & 2 != 0 }
                let start = last.map { max($0 - 1, 0) } ?? 0
                for (record, flags) in selected.dropFirst(start) {
                    if flags & 2 != 0 {
                        // Replacement takes the raw span and stops; its rectangle is not consulted.
                        guard record.payload.count >= bytes.count else {
                            throw WPETexDecodeError.decodeFailed(mipmap: mip.index, detail: "Truncated conditional replacement")
                        }
                        bytes = record.payload.prefix(bytes.count).materializedData()
                        break
                    }
                    // The original reader ignores zero/out-of-bounds patch rectangles before decoding.
                    guard record.width > 0, record.height > 0,
                          record.x <= mip.width, record.y <= mip.height,
                          record.width <= mip.width - record.x, record.height <= mip.height - record.y else { continue }
                    // The packed blend primitive has no branch for non-RGBA TEX formats.
                    if flags & 1 != 0, format != .rgba8888 {
                        continue
                    }
                    let source = try inflatePatch(record, mip)
                    let expected = try WPETexMipValidation.layout(format: format, width: record.width, height: record.height).byteCount
                    guard source.count >= expected else {
                        throw WPETexDecodeError.decodeFailed(mipmap: mip.index, detail: "Truncated conditional patch")
                    }
                    apply(record, source: source, to: &bytes, baseWidth: mip.width, bpp: bpp, blend: flags & 1 != 0)
                }
                return WPETexTextureMipmap(index: mip.index, width: mip.width, height: mip.height, bytes: bytes)
            }
        }
    }

    private static func apply(_ record: WPETexConditionalVariantMipmap, source: Data, to bytes: inout Data,
                              baseWidth: Int, bpp: Int, blend: Bool) {
        bytes.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { input in
                for row in 0 ..< record.height {
                    let target = ((record.y + row) * baseWidth + record.x) * bpp
                    let origin = row * record.width * bpp
                    if !blend {
                        destination.baseAddress!.advanced(by: target).copyMemory(
                            from: input.baseAddress!.advanced(by: origin), byteCount: record.width * bpp
                        )
                    } else {
                        for column in 0 ..< record.width {
                            let src = UInt32(littleEndian: input.loadUnaligned(fromByteOffset: origin + column * 4, as: UInt32.self))
                            let dst = UInt32(littleEndian: destination.loadUnaligned(fromByteOffset: target + column * 4, as: UInt32.self))
                            destination.storeBytes(of: blendRGBA(src, dst).littleEndian, toByteOffset: target + column * 4, as: UInt32.self)
                        }
                    }
                }
            }
        }
    }

    /// The original packed UInt32 arithmetic intentionally wraps subtraction and multiplication.
    private static func blendRGBA(_ src: UInt32, _ dst: UInt32) -> UInt32 {
        let alpha = src >> 24
        let rb = (((((src & 0x00FF_00FF) &- (dst & 0x00FF_00FF)) &* alpha) >> 8) &+ (dst & 0x00FF_00FF)) & 0x00FF_00FF
        let g = (((((src & 0x0000_FF00) &- (dst & 0x0000_FF00)) &* alpha) >> 8) &+ (dst & 0x0000_FF00)) & 0x0000_FF00
        return rb | g | (max(alpha, dst >> 24) << 24)
    }
}
#endif
