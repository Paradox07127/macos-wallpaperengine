#if !LITE_BUILD
/// Detached input published to a render actor; an inactive pointer stays at the neutral scene centre.
struct WPEMetalPointerSample: Equatable, Sendable {
    let position: SIMD2<Double>
    let isInsideView: Bool

    static let inactive = WPEMetalPointerSample(position: SIMD2(0.5, 0.5), isInsideView: false)

    static func inside(_ position: SIMD2<Double>) -> WPEMetalPointerSample {
        WPEMetalPointerSample(position: SIMD2(min(max(position.x, 0), 1), min(max(position.y, 0), 1)),
                              isInsideView: true)
    }
}
#endif
