#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Metal
import Testing

/// Storage values only: no sRGB decode, alpha division, display transfer or HDR clamp.
enum WPEOraclePixelProbe {
    private static func inputError(_ message: String) -> NSError {
        NSError(domain: "WPEOraclePixelProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func sample(texture: MTLTexture, coordinates: [[Int]], commandQueue: MTLCommandQueue) throws -> [String: Any] {
        guard coordinates.count <= 256 else { throw inputError("Pixel probe exceeds 256 coordinates") }
        for point in coordinates {
            guard point.count == 2, point[0] >= 0, point[1] >= 0,
                  point[0] < texture.width, point[1] < texture.height else { throw inputError("Pixel probe coordinate outside final texture") }
        }
        let format: String
        let halfFloat: Bool
        let blueFirst: Bool
        switch texture.pixelFormat {
        case .rgba8Unorm: (format, halfFloat, blueFirst) = ("rgba8Unorm", false, false)
        case .rgba8Unorm_srgb: (format, halfFloat, blueFirst) = ("rgba8Unorm_srgb", false, false)
        case .bgra8Unorm: (format, halfFloat, blueFirst) = ("bgra8Unorm", false, true)
        case .bgra8Unorm_srgb: (format, halfFloat, blueFirst) = ("bgra8Unorm_srgb", false, true)
        case .rgba16Float: (format, halfFloat, blueFirst) = ("rgba16Float", true, false)
        default: throw NSError(domain: "WPEOraclePixelProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported pixel format \(texture.pixelFormat.rawValue)"])
        }
        var samples: [[String: Any]] = []
        if !coordinates.isEmpty {
            let buffer = try #require(texture.device.makeBuffer(length: coordinates.count * 256, options: .storageModeShared))
            let command = try #require(commandQueue.makeCommandBuffer())
            let blit = try #require(command.makeBlitCommandEncoder())
            for (index, point) in coordinates.enumerated() {
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: point[0], y: point[1], z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                          to: buffer, destinationOffset: index * 256, destinationBytesPerRow: 256, destinationBytesPerImage: 256)
            }
            blit.endEncoding()
            command.commit(); command.waitUntilCompleted()
            try #require(command.status == .completed, "Pixel probe GPU blit failed")
            for (index, point) in coordinates.enumerated() {
                let bytes = buffer.contents().advanced(by: index * 256)
                var rgba = (0 ..< 4).map { channel in
                    halfFloat ? Double(Float16(bitPattern: bytes.load(fromByteOffset: channel * 2, as: UInt16.self)))
                        : Double(bytes.load(fromByteOffset: channel, as: UInt8.self)) / 255
                }
                if blueFirst {
                    rgba.swapAt(0, 2)
                }
                samples.append(["x": point[0], "y": point[1], "storageRGBA": rgba])
            }
        }
        return ["interpretation": "storage-no-transfer-or-unpremultiply",
                "format": format, "width": texture.width, "height": texture.height, "samples": samples]
    }

    static func terminalLinearTexture(source: MTLTexture, executor: WPEMetalRenderExecutor) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: source.width, height: source.height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let target = try #require(source.device.makeTexture(descriptor: descriptor))
        target.label = "oracle.terminal-linear"
        let command = try #require(executor.commandQueue.makeCommandBuffer())
        try executor.encodePresentPass(source: source, target: target, fitMode: .stretch,
                                       worldSourceSize: nil, uniforms: nil, into: command)
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed, "Oracle terminal present failed")
        return target
    }

    static func stageEvidence(
        stage: String, texture: MTLTexture, coordinates: [[Int]], commandQueue: MTLCommandQueue,
        frameOrdinal: Int, time: Double
    ) throws -> [String: Any] {
        var evidence = try sample(texture: texture, coordinates: coordinates, commandQueue: commandQueue)
        evidence["stage"] = stage
        evidence["frameOrdinal"] = frameOrdinal
        evidence["time"] = time
        evidence["resource"] = texture.label ?? "unlabeled"
        evidence["transfer"] = stage == "terminal-linear" ? "linear" : "authored-encoded"
        evidence["alpha"] = stage == "terminal-linear" ? "opaque-one" : "scene-coverage"
        evidence["scope"] = "offscreen-native-storage-probes-not-display-capture-or-whole-frame-hash"
        return evidence
    }
}
#endif
