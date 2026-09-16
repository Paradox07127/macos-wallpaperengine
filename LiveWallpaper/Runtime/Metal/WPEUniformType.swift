#if !LITE_BUILD
import Foundation

/// Shared host/MSL ABI. Every scalar/vector column occupies a 16-byte slot;
/// matrices are column-major and arrays retain the complete element stride.
struct WPEUniformType: Equatable, Sendable {
    enum Scalar: Equatable, Sendable { case float, int, uint, bool }
    let scalar: Scalar
    let rows: Int
    let columns: Int

    init?(glslType: String) {
        switch glslType {
        case "float": self.init(scalar: .float, rows: 1)
        case "int": self.init(scalar: .int, rows: 1)
        case "uint": self.init(scalar: .uint, rows: 1)
        case "bool": self.init(scalar: .bool, rows: 1)
        case "vec2": self.init(scalar: .float, rows: 2)
        case "vec3": self.init(scalar: .float, rows: 3)
        case "vec4": self.init(scalar: .float, rows: 4)
        case "ivec2": self.init(scalar: .int, rows: 2)
        case "ivec3": self.init(scalar: .int, rows: 3)
        case "ivec4": self.init(scalar: .int, rows: 4)
        case "uvec2": self.init(scalar: .uint, rows: 2)
        case "uvec3": self.init(scalar: .uint, rows: 3)
        case "uvec4": self.init(scalar: .uint, rows: 4)
        case "bvec2": self.init(scalar: .bool, rows: 2)
        case "bvec3": self.init(scalar: .bool, rows: 3)
        case "bvec4": self.init(scalar: .bool, rows: 4)
        case "mat2": self.init(scalar: .float, rows: 2, columns: 2)
        case "mat3": self.init(scalar: .float, rows: 3, columns: 3)
        case "mat4": self.init(scalar: .float, rows: 4, columns: 4)
        default: return nil
        }
    }

    private init(scalar: Scalar, rows: Int, columns: Int = 1) {
        self.scalar = scalar
        self.rows = rows
        self.columns = columns
    }

    var columnStride: Int { 16 }
    var elementSlotCount: Int { columns }
    var elementStride: Int { columnStride * columns }
    var componentCount: Int { rows * columns }
    var metalType: String {
        let base: String
        switch scalar {
        case .float: base = "float"
        case .int: base = "int"
        case .uint: base = "uint"
        case .bool: base = "bool"
        }
        if columns > 1 { return "\(base)\(columns)x\(rows)" }
        return rows == 1 ? base : "\(base)\(rows)"
    }

    func metalRead(firstSlot: Int) -> String {
        let swizzle = ["", ".x", ".xy", ".xyz", ""][rows]
        if columns > 1 {
            let values = (0..<columns).map { "u.vals[\(firstSlot + $0)]\(swizzle)" }
            return "\(metalType)(\(values.joined(separator: ", ")))"
        }
        let value = "u.vals[\(firstSlot)]\(swizzle)"
        switch scalar {
        case .float: return value
        case .int, .uint: return "as_type<\(metalType)>(\(value))"
        case .bool:
            let zero = rows == 1 ? "0.0" : "float\(rows)(0.0)"
            return "\(value) != \(zero)"
        }
    }
}
#endif
