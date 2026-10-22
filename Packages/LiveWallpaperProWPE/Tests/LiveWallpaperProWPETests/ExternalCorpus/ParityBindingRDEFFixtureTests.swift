import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityBindingRDEFFixtureTests: XCTestCase {
    private struct Capture: Decodable {
        let name: String
        let rdef: [Stage]

        struct Stage: Decodable {
            let rdef: RDEF
        }

        struct RDEF: Decodable {
            let program: Int
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

    func testCapturedRDEFLayouts() throws {
        guard let directory = ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"],
              !directory.isEmpty else {
            throw CorpusFixtures.MissingInput("Set WPE_HLSL_CAPTURE_DIR to the HLSL capture directory containing dxs-pairs.json.")
        }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("dxs-pairs.json")
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
        XCTAssertFalse(captures.isEmpty)
        var layouts = 0
        var variables = 0
        var failures = 0
        var sentinel = 0
        defer { print("rdef layouts checked \(layouts), variables \(variables), failures \(failures)") }

        for capture in captures {
            for stage in capture.rdef {
                for cbuffer in stage.rdef.cbuffers {
                    layouts += 1
                    variables += cbuffer.vars.count
                    do {
                        let binding = try XCTUnwrap(stage.rdef.resources.first {
                            $0.type == "cbuffer" && $0.name == cbuffer.name
                        })
                        let reflected = WPEStageReflection.CBuffer(
                            name: cbuffer.name, register: binding.bind, space: 0, size: cbuffer.size,
                            variables: cbuffer.vars.map {
                                .init(name: $0.name, offset: $0.offset, size: $0.size, baseType: $0.type,
                                      class: $0.class, rows: $0.rows, columns: $0.cols,
                                      elements: $0.elements, used: $0.used)
                            }
                        )
                        let layout = try WPECBufferLayout(reflected)
                        var packer = WPECBufferPacker(layout: layout)
                        var occupied = Set<Int>()
                        var expected: [Int: UInt32] = [:]
                        for variable in cbuffer.vars {
                            for byte in variable.offset ..< (variable.offset + variable.size) {
                                guard occupied.insert(byte).inserted else {
                                    throw WPEParityBindingError.invalidLayout("overlap: \(variable.name)")
                                }
                            }
                            var values: [WPECBufferValue] = []
                            let matrix = variable.class == .matrix_columns || variable.class == .matrix_rows
                            let rowMajor = variable.class == .matrix_rows
                            let stride = matrix ? (rowMajor ? variable.rows : variable.cols) * 16 : 16
                            for element in 0 ..< max(1, variable.elements) {
                                var columns: [[Float]] = []
                                for column in 0 ..< variable.cols {
                                    var rows: [Float] = []
                                    for row in 0 ..< variable.rows {
                                        sentinel += 1
                                        let value = Float(sentinel)
                                        rows.append(value)
                                        let component = matrix ? (rowMajor ? row * 16 + column * 4 : column * 16 + row * 4)
                                            : column * 4
                                        expected[variable.offset + element * stride + component] = value.bitPattern
                                    }
                                    columns.append(rows)
                                }
                                if matrix {
                                    values.append(.matrix(WPEFloatMatrix(columns: columns)))
                                } else if variable.class == .scalar {
                                    values.append(.float(columns[0][0]))
                                } else {
                                    values.append(.vector(columns.map { $0[0] }))
                                }
                            }
                            try packer.write(variable.elements > 0 ? .array(values) : values[0], to: variable.name)
                        }
                        guard packer.bytes.count == cbuffer.size else {
                            throw WPEParityBindingError.invalidLayout("buffer size")
                        }
                        for offset in stride(from: 0, to: cbuffer.size, by: 4) {
                            let actual = (0 ..< 4).reduce(UInt32(0)) {
                                $0 | UInt32(packer.bytes[offset + $1]) << ($1 * 8)
                            }
                            guard actual == expected[offset, default: 0] else {
                                throw WPEParityBindingError.invalidLayout("sentinel at \(offset): \(actual)")
                            }
                        }
                    } catch {
                        failures += 1
                        XCTFail("\(capture.name), stage \(stage.rdef.program), \(cbuffer.name): \(error)")
                    }
                }
            }
        }
        XCTAssertGreaterThan(layouts, 0)
        XCTAssertGreaterThan(variables, 0)
        XCTAssertEqual(failures, 0)
    }
}
