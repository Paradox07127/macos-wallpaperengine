@testable import LiveWallpaperProWPE
import XCTest

final class ParityBindingPackingTests: XCTestCase {
    typealias Variable = WPEStageReflection.CBuffer.Variable

    func variable(_ name: String = "v", offset: Int = 0, size: Int = 4,
                  type: Variable.BaseType = .float, kind: Variable.VariableClass = .scalar,
                  rows: Int = 1, columns: Int = 1, elements: Int = 0) -> Variable {
        Variable(name: name, offset: offset, size: size, baseType: type, class: kind,
                 rows: rows, columns: columns, elements: elements, used: false)
    }

    func layout(_ variables: [Variable], size: Int = 64) throws -> WPECBufferLayout {
        try WPECBufferLayout(.init(name: "g_bufDynamic", register: 1, space: 0,
                                   size: size, variables: variables))
    }

    func word(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    /// `float g_AudioSpectrum64Left[64]` packs as float4[16], which a helper before main indexes up to 63.
    func testBoundLengthCoversElementIndexedFloat4Arrays() throws {
        let layout = try layout([
            variable("g_Texture0Resolution", size: 16, kind: .vector, columns: 4),
            variable("g_AudioSpectrum64Left", offset: 16, size: 256, kind: .vector, columns: 4, elements: 16),
            variable("g_AudioSpectrum64Right", offset: 272, size: 256, kind: .vector, columns: 4, elements: 16),
        ], size: 528)
        XCTAssertEqual(layout.size, 528)
        XCTAssertEqual(layout.boundLength, 272 + 64 * 16)
        let plain = try self.layout([variable("v", size: 16, kind: .vector, columns: 4)], size: 16)
        XCTAssertEqual(plain.boundLength, 16)
    }

    func testScalarsAreFourBytesAndPreserveBits() throws {
        let layout = try layout([
            variable("f", size: 4), variable("i", offset: 4, type: .int),
            variable("u", offset: 8, type: .uint), variable("b", offset: 12, type: .bool),
        ], size: 16)
        var packer = WPECBufferPacker(layout: layout)
        try packer.write(.float(-2.5), to: "f")
        try packer.write(.int(.min), to: "i")
        try packer.write(.uint(.max), to: "u")
        try packer.write(.bool(true), to: "b")
        XCTAssertEqual(word(packer.bytes, 0), Float(-2.5).bitPattern)
        XCTAssertEqual(word(packer.bytes, 4), 0x8000_0000)
        XCTAssertEqual(word(packer.bytes, 8), 0xFFFF_FFFF)
        XCTAssertEqual(Array(packer.bytes[12 ..< 16]), [1, 0, 0, 0])
        try packer.write(.bool(false), to: "b")
        XCTAssertEqual(word(packer.bytes, 12), 0)
        let before = packer.bytes
        XCTAssertThrowsError(try packer.write(.float(1), to: "b"))
        XCTAssertThrowsError(try packer.write(.uint(1), to: "i"))
        XCTAssertThrowsError(try packer.write(.vector([1, 2]), to: "f"))
        XCTAssertThrowsError(try packer.write(.array([.float(1)]), to: "f"))
        XCTAssertThrowsError(try packer.write(.float(1), to: "missing"))
        XCTAssertEqual(packer.bytes, before)
        XCTAssertEqual(layout["i"]?.offset, 4)
        XCTAssertNil(layout["missing"])
    }

    func testIntegerVectorsAndArraysPreserveBits() throws {
        let layout = try layout([
            variable("i4", size: 16, type: .int, kind: .vector, columns: 4),
            variable("u2", offset: 16, size: 8, type: .uint, kind: .vector, columns: 2),
            variable("packed", offset: 32, size: 32, type: .int, kind: .vector, columns: 4, elements: 2),
        ], size: 64)
        var packer = WPECBufferPacker(layout: layout)
        try packer.write(.intVector([-1, 2, .min, 4]), to: "i4")
        try packer.write(.uintVector([.max, 7]), to: "u2")
        try packer.write(.array([.intVector([1, 2, 3, 4]), .intVector([5, 6, 7, 8])]), to: "packed")
        XCTAssertEqual((0 ..< 4).map { word(packer.bytes, $0 * 4) }, [0xFFFF_FFFF, 2, 0x8000_0000, 4])
        XCTAssertEqual([word(packer.bytes, 16), word(packer.bytes, 20)], [0xFFFF_FFFF, 7])
        XCTAssertEqual((0 ..< 8).map { word(packer.bytes, 32 + $0 * 4) }, [1, 2, 3, 4, 5, 6, 7, 8])
        let before = packer.bytes
        XCTAssertThrowsError(try packer.write(.vector([1, 2, 3, 4]), to: "i4"))
        XCTAssertThrowsError(try packer.write(.uintVector([1, 2, 3, 4]), to: "i4"))
        XCTAssertThrowsError(try packer.write(.intVector([1, 2, 3, 4]), to: "u2"))
        XCTAssertEqual(packer.bytes, before)
    }

    func testVectorsStayWithinRegisters() throws {
        var packer = try WPECBufferPacker(layout: layout([
            variable("two", offset: 8, size: 8, kind: .vector, columns: 2),
            variable("three", offset: 16, size: 12, kind: .vector, columns: 3),
            variable("tail", offset: 28),
            variable("four", offset: 32, size: 16, kind: .vector, columns: 4),
        ]))
        try packer.write(.vector([1, 2]), to: "two")
        try packer.write(.vector([3, 4, 5]), to: "three")
        try packer.write(.float(6), to: "tail")
        try packer.write(.vector([7, 8, 9, 10]), to: "four")
        for (offset, value) in zip(stride(from: 8, to: 48, by: 4), 1 ... 10) {
            XCTAssertEqual(word(packer.bytes, offset), Float(value).bitPattern)
        }
        XCTAssertThrowsError(try packer.write(.vector([1, 2, 3, 4]), to: "three"))
        XCTAssertThrowsError(try packer.write(.vector([1, 2]), to: "three"))
        XCTAssertThrowsError(try layout([variable(offset: 12, size: 8, kind: .vector, columns: 2)]))
        XCTAssertThrowsError(try layout([variable(offset: 8, size: 12, kind: .vector, columns: 3)]))
    }

    func testArraysStartEachElementAtANewRegister() throws {
        for columns in 1 ... 4 {
            let kind: Variable.VariableClass = columns == 1 ? .scalar : .vector
            var packer = try WPECBufferPacker(layout: layout([
                variable(size: 32 + columns * 4, kind: kind, columns: columns, elements: 3),
            ]))
            let elements: [WPECBufferValue] = (1 ... 3).map { element in
                columns == 1 ? .float(Float(element))
                    : .vector((0 ..< columns).map { Float(element * 10 + $0) })
            }
            try packer.write(.array(elements), to: "v")
            for element in 0 ..< 3 {
                for component in 0 ..< columns {
                    let value = columns == 1 ? Float(element + 1) : Float((element + 1) * 10 + component)
                    XCTAssertEqual(word(packer.bytes, element * 16 + component * 4), value.bitPattern)
                }
                for byte in (element * 16 + columns * 4) ..< ((element + 1) * 16) {
                    XCTAssertEqual(packer.bytes[byte], 0)
                }
            }
            let before = packer.bytes
            XCTAssertThrowsError(try packer.write(.array(elements + [elements[0]]), to: "v"))
            XCTAssertThrowsError(try packer.write(elements[0], to: "v"))
            XCTAssertThrowsError(try packer.write(.array([elements[0], .vector([1, 2, 3, 4, 5])]), to: "v"))
            XCTAssertEqual(packer.bytes, before)
            XCTAssertThrowsError(try layout([
                variable(offset: 4, size: 32 + columns * 4, kind: kind, columns: columns, elements: 3),
            ]))
        }
    }

    func testTypedArrayInputsAndPartialUpdates() throws {
        var packer = try WPECBufferPacker(layout: layout([
            variable("i", size: 20, type: .int, elements: 2),
            variable("u", offset: 32, size: 20, type: .uint, elements: 2),
            variable("b", offset: 64, size: 20, type: .bool, elements: 2),
            variable("f", offset: 96, size: 20, elements: 2),
            variable("v2", offset: 128, size: 24, kind: .vector, columns: 2, elements: 2),
            variable("v3", offset: 160, size: 28, kind: .vector, columns: 3, elements: 2),
            variable("v4", offset: 192, size: 32, kind: .vector, columns: 4, elements: 2),
        ], size: 224))
        try packer.write(.array([.int(-1), .int(-2)]), to: "i")
        try packer.write(.array([.uint(1), .uint(.max)]), to: "u")
        try packer.write(.array([.bool(true), .bool(false)]), to: "b")
        try packer.write(.array([.float(3), .float(4)]), to: "f")
        try packer.write(.array([.vector([1, 2]), .vector([3, 4])]), to: "v2")
        try packer.write(.array([.vector([1, 2, 3]), .vector([4, 5, 6])]), to: "v3")
        try packer.write(.array([.vector([1, 2, 3, 4]), .vector([5, 6, 7, 8])]), to: "v4")
        XCTAssertEqual(word(packer.bytes, 16), UInt32(bitPattern: -2))
        XCTAssertEqual(word(packer.bytes, 48), .max)
        XCTAssertEqual(word(packer.bytes, 64), 1)
        XCTAssertEqual(word(packer.bytes, 80), 0)
        XCTAssertEqual(word(packer.bytes, 148), Float(4).bitPattern)
        XCTAssertEqual(word(packer.bytes, 184), Float(6).bitPattern)
        XCTAssertEqual(word(packer.bytes, 220), Float(8).bitPattern)
        try packer.write(.array([.float(9)]), to: "f")
        XCTAssertEqual(word(packer.bytes, 96), Float(9).bitPattern)
        XCTAssertEqual(word(packer.bytes, 112), Float(4).bitPattern)
        XCTAssertThrowsError(try packer.write(.array([.float(1)]), to: "i"))
        XCTAssertThrowsError(try packer.write(.array([.bool(true), .bool(false), .bool(true)]), to: "b"))
    }

    func testColumnMajorMatrixUsesOneRegisterPerColumn() throws {
        var packer = try WPECBufferPacker(layout: layout([
            variable(size: 40, kind: .matrix_columns, rows: 2, columns: 3),
        ]))
        try packer.write(.matrix(WPEFloatMatrix(columns: [[1, 2], [3, 4], [5, 6]])), to: "v")
        for (offset, value) in [(0, 1), (4, 2), (16, 3), (20, 4), (32, 5), (36, 6)] {
            XCTAssertEqual(word(packer.bytes, offset), Float(value).bitPattern)
        }
        XCTAssertEqual(Array(packer.bytes[8 ..< 16]), Array(repeating: 0, count: 8))
        XCTAssertThrowsError(try packer.write(.matrix(WPEFloatMatrix(columns: [[1, 2], [3, 4]])), to: "v"))
        XCTAssertThrowsError(try layout([variable(size: 24, kind: .matrix_columns, rows: 2, columns: 3)]))
    }

    func testRowMajorMatrixTransposesColumnInput() throws {
        var packer = try WPECBufferPacker(layout: layout([
            variable(size: 28, kind: .matrix_rows, rows: 2, columns: 3),
        ]))
        try packer.write(.matrix(WPEFloatMatrix(columns: [[1, 2], [3, 4], [5, 6]])), to: "v")
        for (offset, value) in [(0, 1), (4, 3), (8, 5), (16, 2), (20, 4), (24, 6)] {
            XCTAssertEqual(word(packer.bytes, offset), Float(value).bitPattern)
        }
        XCTAssertEqual(word(packer.bytes, 12), 0)
        XCTAssertThrowsError(try packer.write(.matrix(WPEFloatMatrix(columns: [[1], [2], [3]])), to: "v"))
        XCTAssertThrowsError(try packer.write(.matrix(WPEFloatMatrix(columns: [[1, 2], [3], [4, 5]])), to: "v"))
        XCTAssertThrowsError(try layout([variable(offset: 4, size: 28, kind: .matrix_rows, rows: 2, columns: 3)]))
    }

    func testMatrixArraysUsePaddedMatrixStride() throws {
        for kind: Variable.VariableClass in [.matrix_columns, .matrix_rows] {
            var packer = try WPECBufferPacker(layout: layout([
                variable(size: 92, kind: kind, rows: 3, columns: 3, elements: 2),
            ], size: 96))
            let first = WPECBufferValue.matrix(WPEFloatMatrix(columns: [
                SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6), SIMD3<Float>(7, 8, 9),
            ]))
            let second = WPECBufferValue.matrix(WPEFloatMatrix(columns: [[11, 12, 13], [14, 15, 16], [17, 18, 19]]))
            try packer.write(.array([first, second]), to: "v")
            XCTAssertEqual(word(packer.bytes, 48), Float(11).bitPattern)
            XCTAssertEqual(word(packer.bytes, 88), Float(19).bitPattern)
            XCTAssertEqual(word(packer.bytes, 44), 0)
            let before = packer.bytes
            XCTAssertThrowsError(try packer.write(.array([first, second, first]), to: "v"))
            XCTAssertThrowsError(try packer.write(.array([first, .matrix(WPEFloatMatrix(columns: [[1]]))]), to: "v"))
            XCTAssertEqual(packer.bytes, before)
        }
        var four = try WPECBufferPacker(layout: layout([
            variable(size: 64, kind: .matrix_columns, rows: 4, columns: 4),
        ]))
        let matrix = WPEFloatMatrix(columns: [SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8),
                                              SIMD4<Float>(9, 10, 11, 12), SIMD4<Float>(13, 14, 15, 16)])
        try four.write(.matrix(matrix), to: "v")
        XCTAssertEqual(word(four.bytes, 60), Float(16).bitPattern)
        XCTAssertThrowsError(try four.write(.vector([1, 2, 3, 4]), to: "v"))
    }

    func testDirectWriterMatchesThePackerBytesAndErrors() throws {
        let variables = [
            variable("f"), variable("i", offset: 4, type: .int), variable("u", offset: 8, type: .uint),
            variable("b", offset: 12, type: .bool),
            variable("v3", offset: 16, size: 12, kind: .vector, columns: 3),
            variable("i2", offset: 32, size: 8, type: .int, kind: .vector, columns: 2),
            variable("u4", offset: 48, size: 16, type: .uint, kind: .vector, columns: 4),
            variable("columns", offset: 64, size: 40, kind: .matrix_columns, rows: 2, columns: 3),
            variable("rows", offset: 112, size: 28, kind: .matrix_rows, rows: 2, columns: 3),
            variable("array", offset: 144, size: 28, kind: .vector, columns: 3, elements: 2),
            variable("matrices", offset: 176, size: 92, kind: .matrix_rows, rows: 3, columns: 3, elements: 2),
        ]
        let layout = try layout(variables, size: 272)
        let matrix23 = WPECBufferValue.matrix(WPEFloatMatrix(columns: [[1, 2], [3, 4], [5, 6]]))
        let matrix33 = WPECBufferValue.matrix(WPEFloatMatrix(columns: [SIMD3<Float>(1, 2, 3), SIMD3(4, 5, 6),
                                                                       SIMD3(7, 8, 9)]))
        let values: [WPECBufferValue] = [
            .float(-2.5), .int(.min), .uint(.max), .bool(true), .vector([1, 2, 3]), .vector([1, 2]),
            .intVector([-1, 7]), .uintVector([.max, 1, 2, 3]), matrix23, matrix33,
            .matrix(WPEFloatMatrix(columns: [[1, 2], [3], [4, 5]])),
            .array([.vector([1, 2, 3]), .vector([4, 5, 6])]), .array([.vector([1, 2, 3])]),
            .array([.vector([1, 2, 3]), .vector([4, 5, 6]), .vector([7, 8, 9])]), .array([.vector([1, 2, 3]), .float(1)]),
            .array([matrix33, matrix33]), .array([.array([.float(1)])]),
        ]
        func outcome(_ body: () throws -> Void) -> WPEParityBindingError? {
            do {
                try body()
                return nil
            } catch {
                return error as? WPEParityBindingError
            }
        }
        var matched = 0
        for variable in variables {
            for value in values {
                var packer = WPECBufferPacker(layout: layout)
                var direct = [UInt8](repeating: 0, count: layout.size)
                let packed = outcome { try packer.write(value, to: variable.name) }
                let written = outcome {
                    try direct.withUnsafeMutableBytes { try WPECBufferWriter.write(value, to: variable, at: $0.baseAddress!) }
                }
                XCTAssertEqual(written, packed, "\(variable.name) \(value)")
                if packed == nil {
                    XCTAssertEqual(direct, packer.bytes, "\(variable.name) \(value)")
                    matched += 1
                }
            }
        }
        XCTAssertEqual(matched, variables.count + 1)
    }

    func testInvalidReflectedLayoutsAreRejected() throws {
        XCTAssertThrowsError(try layout([variable(offset: 2)]))
        XCTAssertThrowsError(try layout([variable()], size: 15))
        XCTAssertThrowsError(try layout([variable(offset: 64)]))
        XCTAssertThrowsError(try layout([variable(), variable("overlap")]))
        XCTAssertThrowsError(try layout([variable(), variable(offset: 16)]))
        XCTAssertThrowsError(try layout([variable(kind: .struct)]))
        XCTAssertThrowsError(try layout([variable(kind: .vector, columns: 5)]))
        XCTAssertThrowsError(try layout([variable(elements: Int.max)]))
        XCTAssertThrowsError(try layout([variable(size: 16, type: .int, kind: .matrix_columns)]))
    }
}
