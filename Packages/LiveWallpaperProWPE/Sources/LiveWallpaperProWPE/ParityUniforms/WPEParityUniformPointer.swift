/// g_PointerPosition / g_PointerPositionLast / g_PointerState (140110630.c:731-763, 14017fa70.c:1126-1135).
public struct WPEParityUniformPointer: Sendable {
    public private(set) var position: SIMD2<Float> = .zero
    public private(set) var lastPosition: SIMD2<Float> = .zero
    public private(set) var isDown = false
    public private(set) var wasDown = false

    public init() {}

    /// Call once per frame; the previous frame's values become the "last" values.
    public mutating func advance(cursor: SIMD2<Float>, screen: WPEParityUniformScreen, buttonDown: Bool) {
        lastPosition = position
        wasDown = isDown
        position = cursor / screen.size
        isDown = buttonDown
    }

    public var state: SIMD4<Float> {
        let down: Float = isDown ? 1 : 0
        return SIMD4(down, down, isDown && !wasDown ? 1 : 0, 0)
    }
}
