/// Scene- and script-supplied numbers as integers without trapping. nil = not finite, not representable as
/// `Integer`, outside `range`, or (`exact` only) fractional; callers fail the load or ignore the call.
public enum WPEAuthoredInteger {
    /// Scene projection and layer extents in pixels; the TEX decoder caps every texture at 16384 (WPETexErrors).
    public static let pixelExtent = 0 ... 16384
    /// Native readers keep counts and flag words in 32 bits; a literal of either signedness is accepted.
    public static let native32 = Int(Int32.min) ... Int(UInt32.max)

    /// Truncates toward zero, as `Int(_:)` does.
    public static func truncated<Integer: FixedWidthInteger>(_ value: Double, as _: Integer.Type,
                                                             in range: ClosedRange<Integer>? = nil) -> Integer? {
        convert(value.rounded(.towardZero), in: range)
    }

    /// Rounds half away from zero, as `Double.rounded()` does.
    public static func rounded<Integer: FixedWidthInteger>(_ value: Double, as _: Integer.Type,
                                                           in range: ClosedRange<Integer>? = nil) -> Integer? {
        convert(value.rounded(), in: range)
    }

    /// For ids: truncating a fractional id would alias it onto another object's id.
    public static func exact<Integer: FixedWidthInteger>(_ value: Double, as _: Integer.Type,
                                                         in range: ClosedRange<Integer>? = nil) -> Integer? {
        convert(value, in: range)
    }

    private static func convert<Integer: FixedWidthInteger>(_ value: Double, in range: ClosedRange<Integer>?)
        -> Integer? {
        guard let integer = Integer(exactly: value), range?.contains(integer) ?? true else { return nil }
        return integer
    }
}
