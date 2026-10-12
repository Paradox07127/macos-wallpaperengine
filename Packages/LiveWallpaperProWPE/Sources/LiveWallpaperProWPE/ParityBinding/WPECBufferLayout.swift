public struct WPECBufferLayout: Sendable {
    public let reflection: WPEStageReflection.CBuffer
    public var size: Int {
        reflection.size
    }

    private let variablesByName: [String: WPEStageReflection.CBuffer.Variable]

    public init(_ reflection: WPEStageReflection.CBuffer) throws {
        guard reflection.size >= 0, reflection.size % 16 == 0,
              reflection.register >= 0, reflection.space >= 0 else {
            throw WPEParityBindingError.invalidLayout(reflection.name)
        }
        var variables: [String: WPEStageReflection.CBuffer.Variable] = [:]
        var ranges: [Range<Int>] = []
        for variable in reflection.variables {
            guard variables[variable.name] == nil, variable.offset >= 0,
                  variable.offset % 4 == 0, variable.size > 0,
                  variable.offset <= reflection.size,
                  variable.size <= reflection.size - variable.offset,
                  variable.elements >= 0,
                  (1 ... 4).contains(variable.rows), (1 ... 4).contains(variable.columns) else {
                throw WPEParityBindingError.invalidLayout(variable.name)
            }
            let registers: Int
            let components: Int
            switch variable.class {
            case .scalar:
                guard variable.rows == 1, variable.columns == 1 else {
                    throw WPEParityBindingError.invalidLayout(variable.name)
                }
                registers = 1
                components = 1
            case .vector:
                guard variable.rows == 1 else {
                    throw WPEParityBindingError.invalidLayout(variable.name)
                }
                registers = 1
                components = variable.columns
            case .matrix_columns, .matrix_rows:
                guard variable.baseType == .float else {
                    throw WPEParityBindingError.unsupportedVariable(variable.name)
                }
                registers = variable.class == .matrix_columns ? variable.columns : variable.rows
                components = variable.class == .matrix_columns ? variable.rows : variable.columns
            case .struct:
                throw WPEParityBindingError.unsupportedVariable(variable.name)
            }
            let matrix = variable.class == .matrix_columns || variable.class == .matrix_rows
            if matrix || variable.elements > 0 {
                guard variable.offset % 16 == 0 else {
                    throw WPEParityBindingError.invalidLayout(variable.name)
                }
            } else {
                guard variable.offset % 16 + components * 4 <= 16 else {
                    throw WPEParityBindingError.invalidLayout(variable.name)
                }
            }
            let elementExtent = (registers - 1) * 16 + components * 4
            let stride = registers * 16
            let count = max(1, variable.elements)
            guard elementExtent <= variable.size,
                  count - 1 <= (variable.size - elementExtent) / stride else {
                throw WPEParityBindingError.invalidLayout(variable.name)
            }
            let range = variable.offset ..< (variable.offset + variable.size)
            guard !ranges.contains(where: { $0.overlaps(range) }) else {
                throw WPEParityBindingError.invalidLayout(variable.name)
            }
            variables[variable.name] = variable
            ranges.append(range)
        }
        self.reflection = reflection
        variablesByName = variables
    }

    public subscript(name: String) -> WPEStageReflection.CBuffer.Variable? {
        variablesByName[name]
    }
}
