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

    func testScalarsAreFourBytesAndPreserveBits() throws {
        let layout = try layout([
            variable("f", size: 4), variable("i", offset: 4, type: .int),
            variable("u", offset: 8, type: .uint), variable("b", offset: 12, type: .bool),
        ], size: 16)
        var packer = WPECBufferPacker(layout: layout)
        try packer.write(Float(-2.5), to: "f")
        try packer.write(Int32.min, to: "i")
        try packer.write(UInt32.max, to: "u")
        try packer.write(true, to: "b")
        XCTAssertEqual(word(packer.bytes, 0), Float(-2.5).bitPattern)
        XCTAssertEqual(word(packer.bytes, 4), 0x8000_0000)
        XCTAssertEqual(word(packer.bytes, 8), 0xFFFF_FFFF)
        XCTAssertEqual(Array(packer.bytes[12 ..< 16]), [1, 0, 0, 0])
        try packer.write(false, to: "b")
        XCTAssertEqual(word(packer.bytes, 12), 0)
        let before = packer.bytes
        XCTAssertThrowsError(try packer.write(Float(1), to: "b"))
        XCTAssertThrowsError(try packer.write(UInt32(1), to: "i"))
        XCTAssertThrowsError(try packer.write(SIMD2<Float>(1, 2), to: "f"))
        XCTAssertThrowsError(try packer.write([Float(1)], to: "f"))
        XCTAssertThrowsError(try packer.write(Float(1), to: "missing"))
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
        try packer.write(SIMD4<Int32>(-1, 2, Int32.min, 4), to: "i4")
        try packer.write(SIMD2<UInt32>(UInt32.max, 7), to: "u2")
        try packer.write([SIMD4<Int32>(1, 2, 3, 4), SIMD4<Int32>(5, 6, 7, 8)], to: "packed")
        XCTAssertEqual((0 ..< 4).map { word(packer.bytes, $0 * 4) }, [0xFFFF_FFFF, 2, 0x8000_0000, 4])
        XCTAssertEqual([word(packer.bytes, 16), word(packer.bytes, 20)], [0xFFFF_FFFF, 7])
        XCTAssertEqual((0 ..< 8).map { word(packer.bytes, 32 + $0 * 4) }, [1, 2, 3, 4, 5, 6, 7, 8])
        let before = packer.bytes
        XCTAssertThrowsError(try packer.write(SIMD4<Float>(1, 2, 3, 4), to: "i4"))
        XCTAssertThrowsError(try packer.write(SIMD4<UInt32>(1, 2, 3, 4), to: "i4"))
        XCTAssertThrowsError(try packer.write(SIMD4<Int32>(1, 2, 3, 4), to: "u2"))
        XCTAssertEqual(packer.bytes, before)
    }

    func testVectorsStayWithinRegisters() throws {
        var packer = try WPECBufferPacker(layout: layout([
            variable("two", offset: 8, size: 8, kind: .vector, columns: 2),
            variable("three", offset: 16, size: 12, kind: .vector, columns: 3),
            variable("tail", offset: 28),
            variable("four", offset: 32, size: 16, kind: .vector, columns: 4),
        ]))
        try packer.write(SIMD2<Float>(1, 2), to: "two")
        try packer.write(SIMD3<Float>(3, 4, 5), to: "three")
        try packer.write(Float(6), to: "tail")
        try packer.write(SIMD4<Float>(7, 8, 9, 10), to: "four")
        for (offset, value) in zip(stride(from: 8, to: 48, by: 4), 1 ... 10) {
            XCTAssertEqual(word(packer.bytes, offset), Float(value).bitPattern)
        }
        XCTAssertThrowsError(try packer.write(SIMD4<Float>(1, 2, 3, 4), to: "three"))
        XCTAssertThrowsError(try packer.write(SIMD2<Float>(1, 2), to: "three"))
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
        try packer.write([Int32(-1), -2], to: "i")
        try packer.write([UInt32(1), .max], to: "u")
        try packer.write([true, false], to: "b")
        try packer.write([Float(3), 4], to: "f")
        try packer.write([SIMD2<Float>(1, 2), SIMD2<Float>(3, 4)], to: "v2")
        try packer.write([SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6)], to: "v3")
        try packer.write([SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8)], to: "v4")
        XCTAssertEqual(word(packer.bytes, 16), UInt32(bitPattern: -2))
        XCTAssertEqual(word(packer.bytes, 48), .max)
        XCTAssertEqual(word(packer.bytes, 64), 1)
        XCTAssertEqual(word(packer.bytes, 80), 0)
        XCTAssertEqual(word(packer.bytes, 148), Float(4).bitPattern)
        XCTAssertEqual(word(packer.bytes, 184), Float(6).bitPattern)
        XCTAssertEqual(word(packer.bytes, 220), Float(8).bitPattern)
        try packer.write([Float(9)], to: "f")
        XCTAssertEqual(word(packer.bytes, 96), Float(9).bitPattern)
        XCTAssertEqual(word(packer.bytes, 112), Float(4).bitPattern)
        XCTAssertThrowsError(try packer.write([Float(1)], to: "i"))
        XCTAssertThrowsError(try packer.write([true, false, true], to: "b"))
    }

    func testColumnMajorMatrixUsesOneRegisterPerColumn() throws {
        var packer = try WPECBufferPacker(layout: layout([
            variable(size: 40, kind: .matrix_columns, rows: 2, columns: 3),
        ]))
        try packer.write(WPEFloatMatrix(columns: [SIMD2<Float>(1, 2), SIMD2<Float>(3, 4), SIMD2<Float>(5, 6)]), to: "v")
        for (offset, value) in [(0, 1), (4, 2), (16, 3), (20, 4), (32, 5), (36, 6)] {
            XCTAssertEqual(word(packer.bytes, offset), Float(value).bitPattern)
        }
        XCTAssertEqual(Array(packer.bytes[8 ..< 16]), Array(repeating: 0, count: 8))
        XCTAssertThrowsError(try packer.write(WPEFloatMatrix(columns: [[1, 2], [3, 4]]), to: "v"))
        XCTAssertThrowsError(try layout([variable(size: 24, kind: .matrix_columns, rows: 2, columns: 3)]))
    }

    func testRowMajorMatrixTransposesColumnInput() throws {
        var packer = try WPECBufferPacker(layout: layout([
            variable(size: 28, kind: .matrix_rows, rows: 2, columns: 3),
        ]))
        try packer.write(WPEFloatMatrix(columns: [[1, 2], [3, 4], [5, 6]]), to: "v")
        for (offset, value) in [(0, 1), (4, 3), (8, 5), (16, 2), (20, 4), (24, 6)] {
            XCTAssertEqual(word(packer.bytes, offset), Float(value).bitPattern)
        }
        XCTAssertEqual(word(packer.bytes, 12), 0)
        XCTAssertThrowsError(try packer.write(WPEFloatMatrix(columns: [[1], [2], [3]]), to: "v"))
        XCTAssertThrowsError(try packer.write(WPEFloatMatrix(columns: [[1, 2], [3], [4, 5]]), to: "v"))
        XCTAssertThrowsError(try layout([variable(offset: 4, size: 28, kind: .matrix_rows, rows: 2, columns: 3)]))
    }

    func testMatrixArraysUsePaddedMatrixStride() throws {
        for kind: Variable.VariableClass in [.matrix_columns, .matrix_rows] {
            var packer = try WPECBufferPacker(layout: layout([
                variable(size: 92, kind: kind, rows: 3, columns: 3, elements: 2),
            ], size: 96))
            let first = WPEFloatMatrix(columns: [SIMD3<Float>(1, 2, 3), SIMD3<Float>(4, 5, 6), SIMD3<Float>(7, 8, 9)])
            let second = WPEFloatMatrix(columns: [[11, 12, 13], [14, 15, 16], [17, 18, 19]])
            try packer.write([first, second], to: "v")
            XCTAssertEqual(word(packer.bytes, 48), Float(11).bitPattern)
            XCTAssertEqual(word(packer.bytes, 88), Float(19).bitPattern)
            XCTAssertEqual(word(packer.bytes, 44), 0)
            let before = packer.bytes
            XCTAssertThrowsError(try packer.write([first, second, first], to: "v"))
            XCTAssertThrowsError(try packer.write([first, WPEFloatMatrix(columns: [[1]])], to: "v"))
            XCTAssertEqual(packer.bytes, before)
        }
        var four = try WPECBufferPacker(layout: layout([
            variable(size: 64, kind: .matrix_columns, rows: 4, columns: 4),
        ]))
        try four.write(WPEFloatMatrix(columns: [SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8),
                                                SIMD4<Float>(9, 10, 11, 12), SIMD4<Float>(13, 14, 15, 16)]), to: "v")
        XCTAssertEqual(word(four.bytes, 60), Float(16).bitPattern)
        XCTAssertThrowsError(try four.write(SIMD4<Float>(1, 2, 3, 4), to: "v"))
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
