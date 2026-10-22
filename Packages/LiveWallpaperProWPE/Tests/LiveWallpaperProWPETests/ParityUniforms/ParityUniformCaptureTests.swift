import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityUniformCaptureTests: XCTestCase {
    struct Capture: Decodable {
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

    func layout(_ stage: Capture.Stage, _ cbuffer: Capture.CBuffer) throws -> WPECBufferLayout {
        let binding = try XCTUnwrap(stage.rdef.resources.first { $0.type == "cbuffer" && $0.name == cbuffer.name })
        return try WPECBufferLayout(WPEStageReflection.CBuffer(
            name: cbuffer.name, register: binding.bind, space: 0, size: cbuffer.size,
            variables: cbuffer.vars.map {
                .init(name: $0.name, offset: $0.offset, size: $0.size, baseType: $0.type, class: $0.class,
                      rows: $0.rows, columns: $0.cols, elements: $0.elements, used: $0.used)
            }
        ))
    }

    func float(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) })
    }

    func sampleValues() -> (values: [String: WPECBufferValue], mvp: simd_float4x4) {
        let (frame, draw) = sampleInputs()
        return (WPEParityUniformSet.values(frame: frame, draw: draw), draw.matrices.modelViewProjection)
    }

    func sampleInputs() -> (frame: WPEParityUniformFrame, draw: WPEParityUniformDraw) {
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
        return (frame, WPEParityUniformDraw(matrices: matrices, textures: [texture]))
    }

    func outcome(_ body: () throws -> Void) -> WPEParityBindingError? {
        do {
            try body()
            return nil
        } catch {
            return error as? WPEParityBindingError ?? .invalidBinding("\(error)")
        }
    }

    func testFrameMutationsAfterInitReachDrawValues() throws {
        func time(_ values: [String: WPECBufferValue]) -> Float? {
            guard case let .float(value) = values["g_Time"] else { return nil }
            return value
        }
        func spectrum16Left(_ values: [String: WPECBufferValue]) -> [Float]? {
            guard case let .array(rows) = values["g_AudioSpectrum16Left"] else { return nil }
            return rows.flatMap { row -> [Float] in
                guard case let .vector(components) = row else { return [] }
                return components
            }
        }
        let screen = WPEParityUniformScreen(clientWidth: 1920, clientHeight: 1080)
        var frame = WPEParityUniformFrame(
            clock: WPEParityClock(), daytime: 0.5, screen: screen, pointer: WPEParityUniformPointer(),
            parallax: WPEParityUniformParallax(), eyePosition: .zero, view: matrix_identity_float4x4
        )
        let draw = WPEParityUniformDraw(matrices: .effectPass)
        XCTAssertEqual(spectrum16Left(WPEParityUniformSet.values(frame: frame, draw: draw)),
                       [Float](repeating: 0, count: 16))

        let bins = (0 ..< 64).map { Float($0 % 8 + 1) }
        // Audio last: any later didSet would recompute every shared value and hide a missing audio refresh.
        frame.clock.advance(elapsed: 0.5, ratePercent: 100, paused: false)
        frame.audio.advance(left: bins, right: bins, dt: 1.0 / 30, silence: false)
        let values = WPEParityUniformSet.values(frame: frame, draw: draw)

        let expected = try XCTUnwrap(spectrum16Left(frame.audio.uniforms()))
        XCTAssertTrue(expected.contains { $0 > 0 })
        XCTAssertEqual(spectrum16Left(values), expected)
        XCTAssertGreaterThan(frame.clock.timeUniform, 0)
        XCTAssertEqual(time(values), frame.clock.timeUniform)
    }

    /// Every captured WPE cbuffer, filled name by name from the engine inputs, holds the bytes packing the whole set gives.
}
