import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

extension ParityUniformCaptureTests {
    func testPackIntoCapturedLayouts() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"],
              !directory.isEmpty else {
            throw CorpusFixtures.MissingInput("Set WPE_HLSL_CAPTURE_DIR to the HLSL capture directory containing dxs-pairs.json.")
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

    func testDirectEngineWritesMatchPackingTheWholeSet() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"],
              !directory.isEmpty else {
            throw CorpusFixtures.MissingInput("Set WPE_HLSL_CAPTURE_DIR to the HLSL capture directory containing dxs-pairs.json.")
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
