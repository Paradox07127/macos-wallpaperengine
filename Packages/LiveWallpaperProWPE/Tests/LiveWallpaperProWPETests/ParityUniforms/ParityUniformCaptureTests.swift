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
        let (frame, draw) = sampleInputs()
        return (WPEParityUniformSet.values(frame: frame, draw: draw), draw.matrices.modelViewProjection)
    }

    private func sampleInputs() -> (frame: WPEParityUniformFrame, draw: WPEParityUniformDraw) {
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

    private func outcome(_ body: () throws -> Void) -> WPEParityBindingError? {
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

    /// Every captured WPE cbuffer, filled name by name from the engine inputs, holds the bytes packing the whole set gives.
    func testDirectEngineWritesMatchPackingTheWholeSet() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"],
              !directory.isEmpty else {
            throw XCTSkip("Set WPE_HLSL_CAPTURE_DIR to the HLSL capture directory containing dxs-pairs.json.")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("dxs-pairs.json")
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
        var (frame, layer) = sampleInputs()
        frame.lights = WPEParityUniformLights(ambient: SIMD3(0.1, 0.2, 0.3), skylight: SIMD3(0.4, 0.5, 0.6))
        frame.audio.advance(left: (0 ..< 64).map { Float($0 % 5) }, right: (0 ..< 64).map { Float($0 % 3) },
                            dt: 1.0 / 30, silence: false)
        var effect = layer
        effect.matrices = .effectPass
        effect.effectPass = WPEParityUniformEffectPass(layerModel: layer.matrices.model,
                                                       layerModelViewProjection: layer.matrices.modelViewProjection,
                                                       size: SIMD2(400, 200), isLastPass: false)
        let plain = WPEParityUniformTexture(textureWidth: 64, textureHeight: 32, imageWidth: 60, imageHeight: 30,
                                            mipMapInfo: -1)
        effect.textures = [nil, plain, layer.textures[0]]
        var compared = 0, engineWrites = 0
        for draw in [layer, effect] {
            let values = WPEParityUniformSet.values(frame: frame, draw: draw)
            for capture in captures {
                for stage in capture.rdef {
                    for cbuffer in stage.rdef.cbuffers where cbuffer.size > 0 {
                        let layout = try layout(stage, cbuffer)
                        var packer = WPECBufferPacker(layout: layout)
                        var direct = [UInt8](repeating: 0, count: layout.size)
                        for variable in layout.reflection.variables {
                            let packed = outcome {
                                if let value = values[variable.name] {
                                    try packer.write(value, to: variable.name)
                                }
                            }
                            let written = outcome {
                                try direct.withUnsafeMutableBytes {
                                    try WPEParityUniformSet.write(WPEParityEngineUniform(name: variable.name),
                                                                  to: variable, frame: frame, draw: draw,
                                                                  at: XCTUnwrap($0.baseAddress))
                                }
                            }
                            XCTAssertEqual(written, packed, "\(capture.name) \(variable.name)")
                            engineWrites += values[variable.name] == nil ? 0 : 1
                        }
                        XCTAssertEqual(direct, packer.bytes, "\(capture.name) \(cbuffer.name)")
                        compared += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 0)
        XCTAssertGreaterThan(engineWrites, 0)
    }
}
