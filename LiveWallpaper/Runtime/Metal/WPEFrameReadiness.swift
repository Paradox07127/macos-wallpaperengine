#if !LITE_BUILD
import Foundation

struct WPEFrameReadinessResult: Equatable, Sendable {
    let generation: Int
    let renderCompleted: Bool
    let presentCompleted: Bool
}

#endif
