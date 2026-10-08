#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Object-quad uniform bytes stay pinned", .serialized)
struct WPEObjectQuadUniformsBytePinTests {
    struct PinCase: Sendable, CustomTestStringConvertible {
        let name: String
        let origin: SIMD3<Double>
        let scale: SIMD3<Double>
        let angles: SIMD3<Double>
        let size: CGSize?
        let hex: String
        var testDescription: String {
            name
        }
    }

    private static let sceneSize = CGSize(width: 3840, height: 2160)
    private static let tilt = SIMD3<Double>(2.5, -2.5, 0) * .pi / 180

    /// Identity `cameraOrientation` followed by zero `cameraWorldDepth`: bytes 48..<128 of every case.
    private static let identityCameraTail = "0000803f000000000000000000000000000000000000803f00000000000000000000000000000000"
        + "0000803f000000000000000000000000000000000000803f00000000000000000000000000000000"

    static let cases: [PinCase] = [
        .init(name: "identity", origin: .zero, scale: SIMD3(1, 1, 1), angles: .zero, size: nil,
              hex: "00000000000000000000704500000745000070450000074500000000000000000000803f0000803f0000000000000000"),
        .init(name: "subregion", origin: SIMD3(600, 400, 0), scale: SIMD3(1, 1, 1), angles: .zero,
              size: CGSize(width: 320, height: 180),
              hex: "0000a5c400002ac40000a04300003443000070450000074500000000000000000000803f0000803f0000000000000000"),
        .init(name: "tilted full cover", origin: SIMD3(1920, 1080, 0), scale: SIMD3(1, 1, 1), angles: SIMD3(0.1, 0.1, 0),
              size: sceneSize,
              hex: "00000000000000000ecd6e4558530645000070450000074500000000000000000000803f0000803f0000000000000000"),
        .init(name: "mirrored", origin: SIMD3(1000, 700, 0), scale: SIMD3(-1.5, 1, 1), angles: .zero,
              size: CGSize(width: 400, height: 300),
              hex: "000066c40000bec3000016440000964300007045000007450000000000000000000080bf0000803f0000000000000000"),
        .init(name: "z rotation", origin: SIMD3(2200, 900, 0), scale: SIMD3(1, 1, 1), angles: SIMD3(0, 0, 0.6),
              size: CGSize(width: 500, height: 250),
              hex: "00008c43000034c30000fa4300007a4300007045000007459a99193f000000000000803f0000803f0000000000000000"),
        .init(name: "2077 zero angles", origin: SIMD3(1920, 1080, 0), scale: SIMD3(1.3, 1.3, 1.5), angles: .zero,
              size: sceneSize,
              hex: "000000000000000000009c4500802f45000070450000074500000000000000000000803f0000803f0000000000000000"),
        .init(name: "2077 tilt orthographic", origin: SIMD3(1920, 1080, 0), scale: SIMD3(1.3, 1.3, 1.5), angles: tilt,
              size: sceneSize,
              hex: "0000000000000000fdd99b453d552f45000070450000074500000000000000000000803f0000803f0000000000000000"),
    ]

    @Test("objectQuadUniforms output bytes are unchanged", arguments: WPEObjectQuadUniformsBytePinTests.cases)
    func bytesArePinned(_ pin: PinCase) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 16, mipmapped: false)
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let geometry = pin.size == nil && pin.origin == .zero
            ? WPERenderLayerGeometry.identity
            : WPERenderLayerGeometry(origin: pin.origin, scale: pin.scale, angles: pin.angles, alignment: .center,
                                     size: pin.size, alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        let layer = WPERenderLayer(objectID: "pin", objectName: "pin", imagePath: "image", materialPath: nil, geometry: geometry,
                                   compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
        let uniforms = executor.objectQuadUniforms(for: layer, sceneSize: Self.sceneSize, sourceTexture: texture)
        let hex = withUnsafeBytes(of: uniforms) { $0.map { String(format: "%02x", $0) }.joined() }
        #expect(hex == pin.hex + Self.identityCameraTail)
    }

    @Test("Object-quad uniform layout matches the Metal struct")
    func layoutIsPinned() {
        #expect(MemoryLayout<WPEObjectQuadUniforms>.stride == 128)
        #expect(MemoryLayout<WPEObjectQuadUniforms>.offset(of: \.sceneSizeAndRotation) == 16)
        #expect(MemoryLayout<WPEObjectQuadUniforms>.offset(of: \.uvSignAndPadding) == 32)
        #expect(MemoryLayout<WPEObjectQuadUniforms>.offset(of: \.cameraOrientation) == 48)
        #expect(MemoryLayout<WPEObjectQuadUniforms>.offset(of: \.cameraWorldDepth) == 112)
    }
}
#endif
