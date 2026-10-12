import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityUniformCaptureTests: XCTestCase {
    private struct Capture: Decodable {
        let name: String
        let rdef: [Stage]

        struct Stage: Decodable {
            let rdef: RDEF
        }

        struct RDEF: Decodable {
            let resources: [Resource]
            let cbuffers: [CBuffer]
        }

        struct Resource: Decodable {
            let name: String
            let type: String
            let bind: Int
        }

        struct CBuffer: Decodable {
            let name: String
            let size: Int
            let vars: [Variable]
        }

        struct Variable: Decodable {
            let name: String
            let offset: Int
            let size: Int
            let used: Bool
            let `class`: WPEStageReflection.CBuffer.Variable.VariableClass
            let type: WPEStageReflection.CBuffer.Variable.BaseType
            let rows: Int
            let cols: Int
            let elements: Int
        }
    }

    private func layout(_ stage: Capture.Stage, _ cbuffer: Capture.CBuffer) throws -> WPECBufferLayout {
        let binding = try XCTUnwrap(stage.rdef.resources.first { $0.type == "cbuffer" && $0.name == cbuffer.name })
        return try WPECBufferLayout(WPEStageReflection.CBuffer(
            name: cbuffer.name, register: binding.bind, space: 0, size: cbuffer.size,
            variables: cbuffer.vars.map {
                .init(name: $0.name, offset: $0.offset, size: $0.size, baseType: $0.type, class: $0.class,
                      rows: $0.rows, columns: $0.cols, elements: $0.elements, used: $0.used)
            }
        ))
    }

    private func float(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) })
    }

    private func sampleValues() -> (values: [String: WPECBufferValue], mvp: simd_float4x4) {
        var clock = WPEParityClock()
        clock.advance(elapsed: 1.0 / 60, ratePercent: 100, paused: false)
        let screen = WPEParityUniformScreen(clientWidth: 1920, clientHeight: 1080)
        var pointer = WPEParityUniformPointer()
        pointer.advance(cursor: SIMD2(480, 270), screen: screen, buttonDown: false)
        var parallax = WPEParityUniformParallax()
        parallax.advance(pointer: pointer.position, mouseInfluence: 1, delay: 0, eye: .zero,
                         ortho: SIMD2(1920, 1080), frametime: clock.frametime)
        let frame = WPEParityUniformFrame(
            clock: clock, daytime: 0.5, screen: screen, pointer: pointer, parallax: parallax,
            eyePosition: WPEParityUniformParallax.eyePosition2D(eye: .zero, ortho: SIMD2(1920, 1080)),
            view: matrix_identity_float4x4
        )
        let model = simd_float4x4(rows: [
            SIMD4(2, 0, 0, 100), SIMD4(0, 3, 0, 50), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1),
        ])
        let matrices = WPEParityUniformMatrices(model: model, view: matrix_identity_float4x4,
                                                projection: WPEParityUniformMatrices.ortho(
                                                    halfWidth: 960, halfHeight: 540, depth: 1000
                                                ))
        let sprite = WPEParityUniformSpriteFrame(x: 64, y: 32, widthX: 100, widthY: 20, heightX: -10, heightY: 50,
                                                 imageWidth: 400, imageHeight: 200)
        let texture = WPEParityUniformTexture(textureWidth: 512, textureHeight: 256, imageWidth: 400,
                                              imageHeight: 200, mipMapInfo: 3, spriteFrame: sprite)
        let draw = WPEParityUniformDraw(matrices: matrices, textures: [texture])
        return (WPEParityUniformSet.values(frame: frame, draw: draw), matrices.modelViewProjection)
    }

    func testPackIntoCapturedLayouts() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the HLSL capture directory containing dxs-pairs.json.")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("dxs-pairs.json")
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
        let (values, mvp) = sampleValues()

        let capture = try XCTUnwrap(captures.first { $0.name == "shaders/genericimage4.vert" })
        let stage = try XCTUnwrap(capture.rdef.first { $0.rdef.cbuffers.contains { $0.name == "g_bufDynamic" } })
        let cbuffer = try XCTUnwrap(stage.rdef.cbuffers.first { $0.name == "g_bufDynamic" })
        let dynamic = try layout(stage, cbuffer)
        var packer = WPECBufferPacker(layout: dynamic)
        for variable in cbuffer.vars {
            try packer.write(XCTUnwrap(values[variable.name], variable.name), to: variable.name)
        }
        let mvpOffset = try XCTUnwrap(dynamic["g_ModelViewProjectionMatrix"]).offset
        let rows = mvp.transpose
        for register in 0 ..< 4 {
            for component in 0 ..< 4 {
                XCTAssertEqual(float(packer.bytes, at: mvpOffset + register * 16 + component * 4),
                               rows[register][component])
            }
        }
        let rotationOffset = try XCTUnwrap(dynamic["g_Texture0Rotation"]).offset
        XCTAssertEqual((0 ..< 4).map { float(packer.bytes, at: rotationOffset + $0 * 4) }, [0.25, 0.1, -0.025, 0.25])
        let eyeOffset = try XCTUnwrap(dynamic["g_EyePosition"]).offset
        XCTAssertEqual((0 ..< 3).map { float(packer.bytes, at: eyeOffset + $0 * 4) }, [960, 540, 2000])

        var written = 0
        for capture in captures {
            for stage in capture.rdef {
                for cbuffer in stage.rdef.cbuffers {
                    var packer = try WPECBufferPacker(layout: layout(stage, cbuffer))
                    for variable in cbuffer.vars {
                        guard let value = values[variable.name] else {
                            continue
                        }
                        try packer.write(value, to: variable.name)
                        written += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(written, 0)
    }
}
