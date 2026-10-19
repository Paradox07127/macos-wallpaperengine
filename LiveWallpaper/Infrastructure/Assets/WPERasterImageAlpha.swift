#if !LITE_BUILD
import Foundation

/// External raster images publish straight RGB and coverage alpha to WPE shaders.
/// Raw TEX data and render targets bypass this boundary.
enum WPERasterImageAlpha {
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
