#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Signed object-quad alignment regression", .serialized)
struct WPESignedAlignmentGeometryTests {
    struct AlignmentCase: Sendable {
        let alignment: WPESceneAlignment
        let offset: SIMD2<Float>
    }

    static let alignments: [AlignmentCase] = [
        .init(alignment: .center, offset: .zero),
        .init(alignment: .topLeft, offset: SIMD2(0.5, -0.5)),
        .init(alignment: .topRight, offset: SIMD2(-0.5, -0.5)),
        .init(alignment: .bottomLeft, offset: SIMD2(0.5, 0.5)),
        .init(alignment: .bottomRight, offset: SIMD2(-0.5, 0.5)),
        .init(alignment: .top, offset: SIMD2(0, -0.5)),
        .init(alignment: .bottom, offset: SIMD2(0, 0.5)),
        .init(alignment: .left, offset: SIMD2(0.5, 0)),
        .init(alignment: .right, offset: SIMD2(-0.5, 0)),
    ]

    @Test("Captured native negative-X right-anchor matrix centre")
    func capturedRightAnchor() throws {
        let fixture = try Fixture()
        // WPE 2.8.0.42 API matrix, stable at init/frame1/frame30. No pixel parity claim.
        let origin = SIMD3<Double>(2986.8720703125 - 304.376708984375, 547.18603515625 - 351.1973876953125, 0)
        let layer = Self.layer(origin: origin, scale: SIMD2(-0.6682500243186951, 0.20187999308109283),
                               alignment: .right, size: CGSize(width: 512, height: 512))
        let quad = fixture.executor.objectQuadUniforms(for: layer, sceneSize: CGSize(width: 3840, height: 2160), sourceTexture: fixture.texture)
        #expect(abs(quad.centerAndSize.x - Float(2853.5673828125 - 1920)) < 0.001)
        #expect(abs(quad.centerAndSize.y - Float(195.9886474609375 - 1080)) < 0.001)
        #expect(abs(quad.centerAndSize.z - 342.1440124511719) < 0.001)
        #expect(quad.uvSignAndPadding.x == -1)
    }

    @Test("Alignment offsets follow each scale sign while extents and UV signs stay separate", arguments: WPESignedAlignmentGeometryTests.alignments)
    func allAlignmentSigns(_ value: AlignmentCase) throws {
        let fixture = try Fixture()
        for scale in [SIMD2<Double>(2, 3), SIMD2(-2, 3), SIMD2(2, -3), SIMD2(-2, -3)] {
            let layer = Self.layer(scale: scale, alignment: value.alignment)
            let quad = fixture.executor.objectQuadUniforms(for: layer, sceneSize: Self.sceneSize, sourceTexture: fixture.texture)
            let expected = SIMD2<Float>(-100, -100) + value.offset * SIMD2(Float(80 * scale.x), Float(40 * scale.y))
            Self.expectCenter(quad, expected)
            #expect(quad.centerAndSize.z == 160 && quad.centerAndSize.w == 120)
            #expect(quad.uvSignAndPadding.x == (scale.x < 0 ? -1 : 1))
            #expect(quad.uvSignAndPadding.y == (scale.y < 0 ? -1 : 1))
        }
    }

    @Test("Drawing and hover use the same signed anchor under projection and camera zoom", arguments: WPESignedAlignmentGeometryTests.alignments)
    func drawAndHoverShareSignedAlignment(_ value: AlignmentCase) throws {
        let fixture = try Fixture()
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 800, height: 600, auto: false), sceneCamera: .defaultCamera)
        let perspective = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 800, height: 600, auto: false),
                                                 sceneCamera: .init(center: .zero, eye: SIMD3(0, 0, 100), up: SIMD3(0, 1, 0),
                                                                    nearZ: 0.01, farZ: 1000, fov: 90), usesPerspectiveProjection: true)
        for camera in [camera, camera.applyingSceneMotion(.init(origin: SIMD3(37, -23, 0), zoom: 1.75)), perspective] {
            for scale in [SIMD2<Double>(2, 3), SIMD2(-2, 3), SIMD2(2, -3), SIMD2(-2, -3)] {
                let layer = Self.layer(scale: scale, alignment: value.alignment)
                let projection = camera.usesPerspectiveProjection
                    ? camera.projectedCenterInScenePixels(worldPoint: layer.geometry.origin, sceneSize: Self.sceneSize) : nil
                let projected = projection.map { (center: SIMD2<Double>(Double($0.center.x), Double($0.center.y)), depthScale: Double($0.depthScale)) }
                let hit = try #require(WPEMetalSceneRenderer.hoverHitRect(geometry: layer.geometry, sceneSize: Self.sceneSize,
                                                                          projection: projected, camera: camera))
                let signedOffset = value.offset * SIMD2(Float(80 * scale.x), Float(40 * scale.y))
                let expected = projection.map { $0.center + signedOffset * $0.depthScale }
                    ?? camera.transformScenePoint(SIMD2(-100, -100) + signedOffset)
                #expect(abs(hit.center.x - Double(400 + expected.x)) < 0.001)
                #expect(abs(hit.center.y - Double(300 - expected.y)) < 0.001)
                let quad = fixture.executor.objectQuadUniforms(for: layer, sceneSize: Self.sceneSize,
                                                               sourceTexture: fixture.texture, cameraUniforms: camera)
                #expect(abs(hit.center.x - Double(400 + quad.centerAndSize.x)) < 0.001)
                #expect(abs(hit.center.y - Double(300 - quad.centerAndSize.y)) < 0.001)
                #expect(abs(hit.half.x - Double(quad.centerAndSize.z / 2)) < 0.001)
                #expect(abs(hit.half.y - Double(quad.centerAndSize.w / 2)) < 0.001)
            }
        }
    }

    private static let sceneSize = CGSize(width: 800, height: 600)

    private static func expectCenter(_ quad: WPEObjectQuadUniforms, _ expected: SIMD2<Float>) {
        #expect(abs(quad.centerAndSize.x - expected.x) < 0.001)
        #expect(abs(quad.centerAndSize.y - expected.y) < 0.001)
    }

    private static func layer(
        origin: SIMD3<Double> = SIMD3(300, 200, 0), scale: SIMD2<Double>, alignment: WPESceneAlignment,
        size: CGSize = CGSize(width: 80, height: 40)
    ) -> WPERenderLayer {
        let geometry = WPERenderLayerGeometry(origin: origin, scale: SIMD3(scale.x, scale.y, 1), angles: .zero,
                                              alignment: alignment, size: size, alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
        return .init(objectID: "layer", objectName: "layer", imagePath: "image", materialPath: nil, geometry: geometry,
                     compositeA: "a", compositeB: "b", localFBOs: [], passes: [])
    }

    private struct Fixture {
        let executor: WPEMetalRenderExecutor
        let texture: MTLTexture

        init() throws {
            let device = try #require(MTLCreateSystemDefaultDevice())
            executor = try WPEMetalRenderExecutor(device: device)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 16, mipmapped: false)
            texture = try #require(device.makeTexture(descriptor: descriptor))
        }
    }
}
#endif
