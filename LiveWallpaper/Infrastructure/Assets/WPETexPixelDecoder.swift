#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Output is `kCGImageAlphaLast` so the caller can hand it to `CGImage` / `SKTexture(cgImage:)`.
enum WPETexPixelDecoder {

    static func decodeRGBA8888(
        _ bytes: Data,
        width: Int,
        height: Int,
        mipmap: Int
    ) throws -> DecodedRGBAImage {
        let expected = width * height * 4
        guard bytes.count == expected else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "RGBA8888 byte count mismatch: got \(bytes.count), expected \(expected)"
            )
        }
        return DecodedRGBAImage(width: width, height: height, pixels: bytes)
    }

    static func decodeR8(
        _ bytes: Data,
        width: Int,
        height: Int,
        mipmap: Int
    ) throws -> DecodedRGBAImage {
        let expected = width * height
        guard bytes.count == expected else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "R8 byte count mismatch: got \(bytes.count), expected \(expected)"
            )
        }
        var rgba = Data(count: expected * 4)
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                let src = input.bindMemory(to: UInt8.self).baseAddress!
                let dst = out.bindMemory(to: UInt8.self).baseAddress!
                for i in 0..<expected {
                    let r = src[i]
                    dst[i * 4 + 0] = r
                    dst[i * 4 + 1] = r
                    dst[i * 4 + 2] = r
                    dst[i * 4 + 3] = 255
                }
            }
        }
        return DecodedRGBAImage(width: width, height: height, pixels: rgba)
    }

    /// Default RG88 is `(R, G, 0, 255)` (normal.xy). `alphaChannelPriority` (TEXI `0x80000`) is LUMINANCE_ALPHA and must expand to `(R, R, R, G)`.
    static func decodeRG88(
        _ bytes: Data,
        width: Int,
        height: Int,
        mipmap: Int,
        alphaChannelPriority: Bool = false
    ) throws -> DecodedRGBAImage {
        let expected = width * height * 2
        guard bytes.count == expected else {
            throw WPETexDecodeError.decodeFailed(
                mipmap: mipmap,
                detail: "RG88 byte count mismatch: got \(bytes.count), expected \(expected)"
            )
        }
        let pixelCount = width * height
        var rgba = Data(count: pixelCount * 4)
        rgba.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            bytes.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                let src = input.bindMemory(to: UInt8.self).baseAddress!
                let dst = out.bindMemory(to: UInt8.self).baseAddress!
                for i in 0..<pixelCount {
                    let r = src[i * 2 + 0]
                    let g = src[i * 2 + 1]
                    if alphaChannelPriority {
                        dst[i * 4 + 0] = r
                        dst[i * 4 + 1] = r
                        dst[i * 4 + 2] = r
                        dst[i * 4 + 3] = g
                    } else {
                        dst[i * 4 + 0] = r
                        dst[i * 4 + 1] = g
                        dst[i * 4 + 2] = 0
                        dst[i * 4 + 3] = 255
                    }
                }
            }
        }
        return DecodedRGBAImage(width: width, height: height, pixels: rgba)
    }
}
#endif
