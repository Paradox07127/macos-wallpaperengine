/// The masked SSE Double-to-signed-int conversion used by native JSON readers.
enum WPEParityNumericConversion {
    static func cvttsd2si(_ value: Double) -> Int32 {
        Int32(exactly: value.rounded(.towardZero)) ?? Int32.min
    }
}
