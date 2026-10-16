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
