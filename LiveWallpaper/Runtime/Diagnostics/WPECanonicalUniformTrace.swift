#if !LITE_BUILD && DEBUG
import Foundation

enum WPECanonicalUniformTrace {
    static func floatValue(_ value: Float) -> Any {
        if value.isNaN {
            return "NaN"
        }
        if value == .infinity {
            return "+Infinity"
        }
        if value == -.infinity {
            return "-Infinity"
        }
        return Double(value)
    }

    static func floatSlots(_ slots: [SIMD4<Float>]) -> [[Any]] {
        slots.map { slot in (0 ..< 4).map { floatValue(slot[$0]) } }
    }

    /// UInt32 values preserve NaN payloads and integer bits without JSON float conversion.
    static func bitSlots(_ slots: [SIMD4<Float>]) -> [[UInt32]] {
        slots.map { slot in (0 ..< 4).map { slot[$0].bitPattern } }
    }

    static func variables(layout: [WPEUniformSlot], slots: [SIMD4<Float>]) -> [[String: Any]] {
        layout.map { uniform in
            var record: [String: Any] = [
                "name": uniform.name, "type": uniform.glslType,
                "slot": uniform.slot, "slotCount": uniform.slotCount,
                "arrayLength": uniform.arrayLength.map { $0 as Any } ?? NSNull(),
                "materialName": uniform.materialName.map { $0 as Any } ?? NSNull(),
            ]
            guard let type = uniform.typeLayout, uniform.slot >= 0,
                  uniform.slot <= slots.count, uniform.slotCount > 0,
                  uniform.slotCount <= slots.count - uniform.slot,
                  uniform.slotCount % type.columns == 0,
                  (uniform.arrayLength ?? 1) == uniform.slotCount / type.columns else {
                record["value"] = NSNull()
                record["diagnostic"] = "Invalid uniform slot span"
                return record
            }
            let raw = Array(slots[uniform.slot ..< (uniform.slot + uniform.slotCount)])
            record["rawSlotFloats"] = floatSlots(raw).flatMap(\.self)
            record["rawSlotBits"] = bitSlots(raw).flatMap(\.self)
            let elements: [Any] = (0 ..< (uniform.arrayLength ?? 1)).map { element in
                let values: [Any] = (0 ..< type.columns).flatMap { column in
                    (0 ..< type.rows).map { row -> Any in
                        let value = raw[element * type.columns + column][row]
                        switch type.scalar {
                        case .float: return floatValue(value)
                        case .int: return Int32(bitPattern: value.bitPattern)
                        case .uint: return value.bitPattern
                        case .bool: return value != 0
                        }
                    }
                }
                return type.componentCount == 1 ? values[0] : values
            }
            record["value"] = uniform.arrayLength == nil ? elements[0] : elements
            if type.columns > 1 {
                record["matrixMajor"] = "column"
                record["matrixRows"] = type.rows
                record["matrixColumns"] = type.columns
                if type.rows == 4, uniform.arrayLength == nil {
                    record["matrix4x4"] = elements[0]
                }
            }
            return record
        }
    }
}
#endif
