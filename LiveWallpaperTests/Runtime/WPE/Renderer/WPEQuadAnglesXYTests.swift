import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

/// Probes for folding `angles.x`/`angles.y` into the 2D quad draw paths
/// (`objectQuadUniforms`, `shapeQuadUniforms`, direct text placement). The flat
/// quad can't express true 3D, but cos(angles.y)·X / cos(angles.x)·Y scale is
/// exact for the ±π flips wallpaper 3292361861's button group is authored with.
@Suite("WPE quad X/Y angle fold")
struct WPEQuadAnglesXYTests {
    // MARK: - objectQuadUniforms

    @Test("angles.x = π mirrors vertically through the UV-sign field")
    func xFlipMirrorsUVSignY() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try makeTexture(device: device)

        let baseline = executor.objectQuadUniforms(
            for: quadLayer(angles: .zero), sceneSize: sceneSize, sourceTexture: source
        )
        let flipped = executor.objectQuadUniforms(
            for: quadLayer(angles: SIMD3<Double>(.pi, 0, 0)), sceneSize: sceneSize, sourceTexture: source
        )

        #expect(baseline.uvSignAndPadding.x == 1)
        #expect(baseline.uvSignAndPadding.y == 1)
        #expect(flipped.uvSignAndPadding.x == 1)
        #expect(flipped.uvSignAndPadding.y == -1)
        // A ±π flip changes orientation only — placement and extent are unchanged.
        #expect(flipped.centerAndSize == baseline.centerAndSize)
        #expect(flipped.sceneSizeAndRotation == baseline.sceneSizeAndRotation)
    }

    @Test("angles.y = π mirrors horizontally through the UV-sign field")
    func yFlipMirrorsUVSignX() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try makeTexture(device: device)

        let flipped = executor.objectQuadUniforms(
            for: quadLayer(angles: SIMD3<Double>(0, .pi, 0)), sceneSize: sceneSize, sourceTexture: source
        )

        #expect(flipped.uvSignAndPadding.x == -1)
        #expect(flipped.uvSignAndPadding.y == 1)
    }

    @Test("Single-axis tilt foreshortens the matching quad extent")
    func tiltForeshortensWidth() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try makeTexture(device: device)

        let baseline = executor.objectQuadUniforms(
            for: quadLayer(angles: .zero), sceneSize: sceneSize, sourceTexture: source
        )
        let tilted = executor.objectQuadUniforms(
            for: quadLayer(angles: SIMD3<Double>(0, .pi / 3, 0)), sceneSize: sceneSize, sourceTexture: source
        )

        #expect(abs(tilted.centerAndSize.z - baseline.centerAndSize.z * 0.5) < 0.01)
        #expect(abs(tilted.centerAndSize.w - baseline.centerAndSize.w) < 0.01)
    }

    @Test("Negative authored scale and an X/Y flip compose in the UV-sign field")
    func negativeScaleComposesWithFlip() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let source = try makeTexture(device: device)

        let uniforms = executor.objectQuadUniforms(
            for: quadLayer(angles: SIMD3<Double>(0, .pi, 0), scale: SIMD3<Double>(-1, 1, 1)),
            sceneSize: sceneSize,
            sourceTexture: source
        )

        // scale.x < 0 and cos(angles.y) < 0 cancel back to unmirrored UVs.
        #expect(uniforms.uvSignAndPadding.x == 1)
        #expect(uniforms.uvSignAndPadding.y == 1)
    }

    // MARK: - shapeQuadUniforms

    @Test("shapeQuadUniforms mirrors corners vertically under angles.x = π")
    func shapeQuadXFlipMirrorsCorners() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let baseline = executor.shapeQuadUniforms(
            for: shapeQuadLayer(angles: .zero), sceneSize: sceneSize
        )
        let flipped = executor.shapeQuadUniforms(
            for: shapeQuadLayer(angles: SIMD3<Double>(.pi, 0, 0)), sceneSize: sceneSize
        )

        for (base, mirror) in [
            (baseline.corner0, flipped.corner0),
            (baseline.corner1, flipped.corner1),
            (baseline.corner2, flipped.corner2),
            (baseline.corner3, flipped.corner3),
        ] {
            #expect(abs(mirror.x - base.x) < 0.01)
            #expect(abs(mirror.y + base.y) < 0.01)
            // Each corner keeps its authored point UV; only placement mirrors.
            #expect(mirror.z == base.z)
            #expect(mirror.w == base.w)
        }
    }

    @Test("shapeQuadUniforms mirrors corners horizontally under angles.y = π")
    func shapeQuadYFlipMirrorsCorners() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)

        let baseline = executor.shapeQuadUniforms(
            for: shapeQuadLayer(angles: .zero), sceneSize: sceneSize
        )
        let flipped = executor.shapeQuadUniforms(
            for: shapeQuadLayer(angles: SIMD3<Double>(0, .pi, 0)), sceneSize: sceneSize
        )

        for (base, mirror) in [
            (baseline.corner0, flipped.corner0),
            (baseline.corner1, flipped.corner1),
            (baseline.corner2, flipped.corner2),
            (baseline.corner3, flipped.corner3),
        ] {
            #expect(abs(mirror.x + base.x) < 0.01)
            #expect(abs(mirror.y - base.y) < 0.01)
        }
    }

    // MARK: - text placement

    @Test("transformedTextOffset mirrors the anchor offset under an X flip")
    func textOffsetMirrorsUnderXFlip() {
        let offset = WPEMetalSceneRenderer.transformedTextOffset(
            SIMD2<Double>(4, 2),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(.pi, 0, 0)
        )
        #expect(abs(offset.x - 4) < 0.0001)
        #expect(abs(offset.y + 2) < 0.0001)
    }

    // MARK: - end-to-end render probe

    @Test("Rendered quad with angles.x = π is the baseline flipped vertically")
    func renderedXFlipIsVerticalMirror() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let baseline = try renderQuadPixels(device: device, angles: .zero)
        let flipped = try renderQuadPixels(device: device, angles: SIMD3<Double>(.pi, 0, 0))

        #expect(flipped != baseline)
        for x in 0 ..< 2 {
            for y in 0 ..< 2 {
                #expect(flipped[y][x] == baseline[1 - y][x])
            }
        }
    }

    @Test("Rendered quad with angles.y = π is the baseline flipped horizontally")
    func renderedYFlipIsHorizontalMirror() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let baseline = try renderQuadPixels(device: device, angles: .zero)
        let flipped = try renderQuadPixels(device: device, angles: SIMD3<Double>(0, .pi, 0))

        #expect(flipped != baseline)
        for x in 0 ..< 2 {
            for y in 0 ..< 2 {
                #expect(flipped[y][x] == baseline[y][1 - x])
            }
        }
    }

    // MARK: - fixtures

    private let sceneSize = CGSize(width: 4, height: 4)

    /// 2×2 texture: TL red, TR green, BL blue, BR white.
    private var quadBytes: Data {
        Data([
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255,
        ])
    }

    private func quadLayer(
        angles: SIMD3<Double>,
        scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        passes: [WPERenderPass] = []
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "layer",
            objectName: "Layer",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                // Scene-centre origin: the 2×2 quad covers the central 2×2 pixels.
                origin: SIMD3<Double>(2, 2, 0),
                scale: scale,
                angles: angles,
                alignment: .center,
                size: CGSize(width: 2, height: 2),
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1
            ),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: passes
        )
    }

    private func shapeQuadLayer(angles: SIMD3<Double>) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "shape",
            objectName: "Shape",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(2, 2, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: angles,
                alignment: .center,
                size: nil,
                alpha: 1,
                color: SIMD3<Double>(1, 1, 1),
                brightness: 1,
                shapePoints: [
                    SIMD2<Double>(0, 0), SIMD2<Double>(1, 0),
                    SIMD2<Double>(1, 1), SIMD2<Double>(0, 1),
                ]
            ),
            compositeA: "a",
            compositeB: "b",
            localFBOs: [],
            passes: []
        )
    }

    /// Renders the quad layer through the real genericimage2 object-quad path and
    /// returns the central 2×2 pixels of the 4×4 target as [row][column].
    private func renderQuadPixels(
        device: MTLDevice,
        angles: SIMD3<Double>
    ) throws -> [[QuadPixel]] {
        let executor = try WPEMetalRenderExecutor(device: device)
        let texture = try makeTexture(device: device)
        let pass = WPERenderPass(
            id: "quad.0",
            phase: .material,
            shader: "genericimage2",
            source: .image("materials/base.png"),
            target: .scene,
            textures: [0: .image("materials/base.png")],
            binds: [:],
            constants: [:],
            combos: [:],
            blending: "normal",
            cullMode: "nocull",
            depthTest: "disabled",
            depthWrite: "disabled"
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [
            WPEPreparedRenderLayer(
                graphLayer: quadLayer(angles: angles, passes: [pass]),
                passes: [WPEPreparedRenderPass(
                    pass: pass,
                    shader: WPEShaderProgram(name: "genericimage2", vertexSource: "", fragmentSource: "", isBuiltin: true),
                    textureBindings: [0: .image("materials/base.png")],
                    comboValues: [:],
                    uniformValues: [:]
                )]
            ),
        ])

        let output = try executor.render(
            pipeline: pipeline,
            size: sceneSize,
            textures: ["materials/base.png": texture]
        )
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var bytes = [UInt8](repeating: 0, count: staged.width * staged.height * 4)
        staged.getBytes(
            &bytes,
            bytesPerRow: staged.width * 4,
            from: MTLRegionMake2D(0, 0, staged.width, staged.height),
            mipmapLevel: 0
        )
        return (0 ..< 2).map { row in
            (0 ..< 2).map { column in
                let index = ((row + 1) * staged.width + (column + 1)) * 4
                return QuadPixel(
                    r: bytes[index], g: bytes[index + 1],
                    b: bytes[index + 2], a: bytes[index + 3]
                )
            }
        }
    }

    private func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2,
            height: 2,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        try quadBytes.withUnsafeBytes { raw in
            let baseAddress = try #require(raw.baseAddress)
            texture.replace(
                region: MTLRegionMake2D(0, 0, 2, 2),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: 8
            )
        }
        return texture
    }
}

private struct QuadPixel: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
    var a: UInt8
}
