/// g_Screen / g_TexelSize / g_TexelSizeHalf (14017f1b0.c:73-86, 1400d8300.c cases 6-8).
public struct WPEParityUniformScreen: Sendable {
    public let size: SIMD2<Float>

    public init(clientWidth: Int, clientHeight: Int) {
        size = SIMD2(Float(max(2, clientWidth)), Float(max(2, clientHeight)))
    }

    public var screen: SIMD3<Float> {
        SIMD3(size.x, size.y, size.x / size.y)
    }

    public var texelSize: SIMD2<Float> {
        1 / size
    }

    public var texelSizeHalf: SIMD2<Float> {
        0.5 / size
    }
}
