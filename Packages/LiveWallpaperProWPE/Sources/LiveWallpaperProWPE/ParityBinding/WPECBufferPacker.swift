public struct WPEFloatMatrix: Sendable {
    public let columns: [[Float]]

    public init(columns: [[Float]]) {
        self.columns = columns
    }

    public init(columns: [SIMD3<Float>]) {
        self.columns = columns.map { [$0.x, $0.y, $0.z] }
    }

    public init(columns: [SIMD4<Float>]) {
        self.columns = columns.map { [$0.x, $0.y, $0.z, $0.w] }
    }
}

public indirect enum WPECBufferValue: Sendable {
    case float(Float), int(Int32), uint(UInt32), bool(Bool)
    case vector([Float]), intVector([Int32]), uintVector([UInt32]), matrix(WPEFloatMatrix), array([Self])
}

public struct WPECBufferPacker: Sendable {
    public let layout: WPECBufferLayout
    public private(set) var bytes: [UInt8]

    public init(layout: WPECBufferLayout) {
        self.layout = layout
        bytes = [UInt8](repeating: 0, count: layout.size)
    }

    public mutating func write(_ value: WPECBufferValue, to name: String) throws {
        guard let variable = layout[name] else {
            throw WPEParityBindingError.unknownVariable(name)
        }
        let values: [WPECBufferValue]
        if variable.elements > 0 {
            guard case let .array(array) = value, array.count <= variable.elements else {
                throw WPEParityBindingError.shapeMismatch(name)
            }
            values = array
        } else {
            if case .array = value {
                throw WPEParityBindingError.shapeMismatch(name)
            }
            values = [value]
        }
        let registers = variable.class == .matrix_columns ? variable.columns
            : variable.class == .matrix_rows ? variable.rows : 1
        let stride = registers * 16
        var writes: [(Int, UInt32)] = []
        for (index, element) in values.enumerated() {
            let offset = variable.offset + index * stride
            switch element {
            case let .matrix(matrix):
                guard variable.class == .matrix_columns || variable.class == .matrix_rows,
                      matrix.columns.count == variable.columns,
                      matrix.columns.allSatisfy({ $0.count == variable.rows }) else {
                    throw WPEParityBindingError.shapeMismatch(name)
                }
                guard variable.baseType == .float else {
                    throw WPEParityBindingError.typeMismatch(name)
                }
                for column in 0 ..< variable.columns {
                    for row in 0 ..< variable.rows {
                        let componentOffset = variable.class == .matrix_columns
                            ? column * 16 + row * 4 : row * 16 + column * 4
                        writes.append((offset + componentOffset, matrix.columns[column][row].bitPattern))
                    }
                }
            default:
                let words: [UInt32]
                let type: WPEStageReflection.CBuffer.Variable.BaseType
                let expectedClass: WPEStageReflection.CBuffer.Variable.VariableClass
                switch element {
                case let .float(value):
                    words = [value.bitPattern]
                    type = .float
                    expectedClass = .scalar
                case let .int(value):
                    words = [UInt32(bitPattern: value)]
                    type = .int
                    expectedClass = .scalar
                case let .uint(value):
                    words = [value]
                    type = .uint
                    expectedClass = .scalar
                case let .bool(value):
                    words = [value ? 1 : 0]
                    type = .bool
                    expectedClass = .scalar
                case let .vector(value):
                    words = value.map(\.bitPattern)
                    type = .float
                    expectedClass = .vector
                case let .intVector(value):
                    words = value.map { UInt32(bitPattern: $0) }
                    type = .int
                    expectedClass = .vector
                case let .uintVector(value):
                    words = value
                    type = .uint
                    expectedClass = .vector
                case .matrix, .array: throw WPEParityBindingError.shapeMismatch(name)
                }
                guard variable.class == expectedClass, words.count == variable.columns else {
                    throw WPEParityBindingError.shapeMismatch(name)
                }
                guard variable.baseType == type else {
                    throw WPEParityBindingError.typeMismatch(name)
                }
                writes.append(contentsOf: words.enumerated().map { (offset + $0.offset * 4, $0.element) })
            }
        }
        // Validate all elements before changing the buffer.
        for (offset, word) in writes {
            for byte in 0 ..< 4 {
                bytes[offset + byte] = UInt8(truncatingIfNeeded: word >> (byte * 8))
            }
        }
    }
}

/// Writes one variable straight into a zeroed cbuffer at `base`: the bytes and errors `WPECBufferPacker.write` gives,
/// without staging copies.
public enum WPECBufferWriter {
    public typealias Variable = WPEStageReflection.CBuffer.Variable

    public static func write(_ value: WPECBufferValue, to variable: Variable, at base: UnsafeMutableRawPointer) throws {
        guard variable.elements > 0 else {
            if case .array = value {
                throw WPEParityBindingError.shapeMismatch(variable.name)
            }
            try check(value, variable)
            store(value, variable, at: base + variable.offset)
            return
        }
        guard case let .array(array) = value, array.count <= variable.elements else {
            throw WPEParityBindingError.shapeMismatch(variable.name)
        }
        for element in array {
            try check(element, variable)
        }
        let registers = variable.class == .matrix_columns ? variable.columns
            : variable.class == .matrix_rows ? variable.rows : 1
        for (index, element) in array.enumerated() {
            store(element, variable, at: base + variable.offset + index * registers * 16)
        }
    }

    /// A float scalar (`count` 1 with `vector` false) or vector of the first `count` lanes.
    static func write(_ lanes: SIMD4<Float>, count: Int, vector: Bool, to variable: Variable,
                      at base: UnsafeMutableRawPointer) throws {
        guard variable.elements == 0, variable.class == (vector ? .vector : .scalar), count == variable.columns else {
            throw WPEParityBindingError.shapeMismatch(variable.name)
        }
        guard variable.baseType == .float else {
            throw WPEParityBindingError.typeMismatch(variable.name)
        }
        for lane in 0 ..< count {
            base.storeBytes(of: lanes[lane].bitPattern.littleEndian, toByteOffset: variable.offset + lane * 4,
                            as: UInt32.self)
        }
    }

    /// `.wpeTransposed(matrix)` for a `size` x `size` matrix, read through `element(column, row)` of the transpose.
    static func writeTransposed(size: Int, to variable: Variable, at base: UnsafeMutableRawPointer,
                                _ element: (Int, Int) -> Float) throws {
        guard variable.elements == 0, variable.class == .matrix_columns || variable.class == .matrix_rows,
              variable.columns == size, variable.rows == size else {
            throw WPEParityBindingError.shapeMismatch(variable.name)
        }
        guard variable.baseType == .float else {
            throw WPEParityBindingError.typeMismatch(variable.name)
        }
        for column in 0 ..< size {
            for row in 0 ..< size {
                let offset = variable.class == .matrix_columns ? column * 16 + row * 4 : row * 16 + column * 4
                base.storeBytes(of: element(column, row).bitPattern.littleEndian,
                                toByteOffset: variable.offset + offset, as: UInt32.self)
            }
        }
    }

    private static func check(_ element: WPECBufferValue, _ variable: Variable) throws {
        let type: Variable.BaseType
        let expectedClass: Variable.VariableClass
        let count: Int
        switch element {
        case let .matrix(matrix):
            guard variable.class == .matrix_columns || variable.class == .matrix_rows,
                  matrix.columns.count == variable.columns,
                  matrix.columns.allSatisfy({ $0.count == variable.rows }) else {
                throw WPEParityBindingError.shapeMismatch(variable.name)
            }
            guard variable.baseType == .float else {
                throw WPEParityBindingError.typeMismatch(variable.name)
            }
            return
        case .float: (type, expectedClass, count) = (.float, .scalar, 1)
        case .int: (type, expectedClass, count) = (.int, .scalar, 1)
        case .uint: (type, expectedClass, count) = (.uint, .scalar, 1)
        case .bool: (type, expectedClass, count) = (.bool, .scalar, 1)
        case let .vector(value): (type, expectedClass, count) = (.float, .vector, value.count)
        case let .intVector(value): (type, expectedClass, count) = (.int, .vector, value.count)
        case let .uintVector(value): (type, expectedClass, count) = (.uint, .vector, value.count)
        case .array: throw WPEParityBindingError.shapeMismatch(variable.name)
        }
        guard variable.class == expectedClass, count == variable.columns else {
            throw WPEParityBindingError.shapeMismatch(variable.name)
        }
        guard variable.baseType == type else {
            throw WPEParityBindingError.typeMismatch(variable.name)
        }
    }

    private static func store(_ element: WPECBufferValue, _ variable: Variable, at base: UnsafeMutableRawPointer) {
        func put(_ word: UInt32, _ offset: Int) {
            base.storeBytes(of: word.littleEndian, toByteOffset: offset, as: UInt32.self)
        }
        switch element {
        case let .matrix(matrix):
            for column in 0 ..< variable.columns {
                for row in 0 ..< variable.rows {
                    let offset = variable.class == .matrix_columns ? column * 16 + row * 4 : row * 16 + column * 4
                    put(matrix.columns[column][row].bitPattern, offset)
                }
            }
        case let .float(value): put(value.bitPattern, 0)
        case let .int(value): put(UInt32(bitPattern: value), 0)
        case let .uint(value): put(value, 0)
        case let .bool(value): put(value ? 1 : 0, 0)
        case let .vector(value):
            for (lane, component) in value.enumerated() {
                put(component.bitPattern, lane * 4)
            }
        case let .intVector(value):
            for (lane, component) in value.enumerated() {
                put(UInt32(bitPattern: component), lane * 4)
            }
        case let .uintVector(value):
            for (lane, component) in value.enumerated() {
                put(component, lane * 4)
            }
        case .array: break
        }
    }
}
