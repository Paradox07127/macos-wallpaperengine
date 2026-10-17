import Foundation

/// The masked SSE Double-to-signed-int conversion used by native JSON readers.
enum WPEParityNumericConversion {
    static func cvttsd2si(_ value: Double) -> Int32 {
        Int32(exactly: value.rounded(.towardZero)) ?? Int32.min
    }

    /// Existing Mac parser for the native 198e20/1a4230 string family; UCRT grammar/locale equivalence stays open.
    static func asciiSpaceVector3(_ text: String) -> SIMD3<Float> {
        var result = SIMD3<Float>.zero
        text.withCString { start in
            var cursor = start
            for component in 0 ..< 3 {
                result[component] = Float(strtod(cursor, nil))
                while cursor.pointee != 0, cursor.pointee != 0x20 {
                    cursor += 1
                }
                while cursor.pointee == 0x20 {
                    cursor += 1
                }
            }
        }
        return result
    }

    /// The vec2 fromJSON (1401a3fc0.c:18-48): a number broadcasts; a string reads x, then y after the first space run
    /// or 0; nil = other shapes, which leave the field alone.
    static func nativeVector2(_ value: WPESceneJSONValue?) -> SIMD2<Double>? {
        switch value {
        case let .number(number)?:
            SIMD2(repeating: number)
        case let .string(text)?:
            text.withCString { start in
                guard start.pointee != 0 else { return .zero }
                var cursor = start
                let x = strtod(cursor, nil)
                while cursor.pointee != 0, cursor.pointee != 0x20 {
                    cursor += 1
                }
                guard cursor.pointee == 0x20 else { return SIMD2(x, 0) }
                while cursor.pointee == 0x20 {
                    cursor += 1
                }
                return SIMD2(x, strtod(cursor, nil))
            }
        default:
            nil
        }
    }
}
