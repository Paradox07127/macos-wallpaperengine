#if !LITE_BUILD
import Accelerate
import CoreGraphics
import Foundation

/// External raster images publish straight RGB and coverage alpha to WPE shaders.
/// Raw TEX data and render targets bypass this boundary.
enum WPERasterImageAlpha {
    enum Failure: Error { case unsupportedImageFormat }

    /// Keep the source color space, component precision and byte order. MetalKit
    /// retains a CGImage's premultiplication; the external-image consumers do not.
    static func straightImage(_ image: CGImage) throws -> CGImage {
        let alpha: CGImageAlphaInfo
        switch image.alphaInfo {
        case .premultipliedFirst: alpha = .first
        case .premultipliedLast: alpha = .last
        default: return image
        }
        guard var format = vImage_CGImageFormat(cgImage: image) else {
            throw Failure.unsupportedImageFormat
        }
        format.bitmapInfo = CGBitmapInfo(rawValue:
            (format.bitmapInfo.rawValue & ~CGBitmapInfo.alphaInfoMask.rawValue) | alpha.rawValue)
        let buffer = try vImage_Buffer(cgImage: image, format: format)
        defer { buffer.free() }
        return try buffer.createCGImage(format: format)
    }

    static func unpremultiplyRGBA8(_ bytes: inout Data) {
        bytes.withUnsafeMutableBytes { unpremultiplyRGBA8($0.bindMemory(to: UInt8.self)) }
    }

    static func unpremultiplyRGBA8(_ bytes: inout [UInt8]) {
        bytes.withUnsafeMutableBytes { unpremultiplyRGBA8($0.bindMemory(to: UInt8.self)) }
    }

    private static func unpremultiplyRGBA8(_ bytes: UnsafeMutableBufferPointer<UInt8>) {
        var offset = 0
        while offset + 3 < bytes.count {
            let alpha = Int(bytes[offset + 3])
            if alpha == 0 {
                bytes[offset] = 0
                bytes[offset + 1] = 0
                bytes[offset + 2] = 0
            } else if alpha < 255 {
                let halfAlpha = alpha / 2
                for channel in 0 ..< 3 {
                    bytes[offset + channel] = UInt8(min(255,
                                                        (Int(bytes[offset + channel]) * 255 + halfAlpha) / alpha))
                }
            }
            offset += 4
        }
    }
}
#endif
