import Foundation

/// Execution IR, separate from the lossless camera-object mirror. Parsed after
/// user bindings resolve, so the selected camera and its seeds share one source.
public struct WPESceneCameraMotion: Equatable, Sendable {
    public let objectID: String
    public let origin: SIMD3<Double>
    public let zoom: Double
    public let originAnimation: WPESceneAnimatedValue?
    public let zoomAnimation: WPESceneAnimatedValue?
    public let originIsRelative: Bool
    public let originFollowsZoom: Bool

    public init(objectID: String, origin: SIMD3<Double>, zoom: Double,
                originAnimation: WPESceneAnimatedValue? = nil, zoomAnimation: WPESceneAnimatedValue? = nil,
                originIsRelative: Bool = false, originFollowsZoom: Bool = false) {
        self.objectID = objectID
        self.origin = origin
        self.zoom = zoom
        self.originAnimation = originAnimation
        self.zoomAnimation = zoomAnimation
        self.originIsRelative = originIsRelative
        self.originFollowsZoom = originFollowsZoom
    }

    public var seed: WPESceneCameraMotionSample {
        .init(origin: origin, zoom: zoom)
    }

    public func sample(at time: Double) -> WPESceneCameraMotionSample {
        let clock = originFollowsZoom ? zoomAnimation?.animation : nil
        var position = origin
        if let animated = originAnimation, !Self.isPaused(clock ?? animated.animation) {
            let values = animated.animation.values(atFrame: (clock ?? animated.animation).frame(at: time),
                                                   fallbacks: originIsRelative ? [0, 0, 0] : [origin.x, origin.y, origin.z])
            if !values.isEmpty {
                position = originIsRelative ? .zero : origin
                for index in 0 ..< min(values.count, 3) {
                    position[index] = values[index]
                }
                if originIsRelative {
                    position += origin
                }
            }
        }
        let sampledZoom = zoomAnimation.flatMap { Self.isPaused($0.animation) ? nil : $0.scalar(at: time) } ?? zoom
        return .init(origin: position, zoom: sampledZoom)
    }

    public func needsFrames(at time: Double) -> Bool {
        let animations = [zoomAnimation?.animation, originFollowsZoom ? (zoomAnimation?.animation ?? originAnimation?.animation) : originAnimation?.animation].compactMap(\.self)
        return animations.contains { animation in
            guard !Self.isPaused(animation), animation.tracks.contains(where: { $0.count > 1 }) else { return false }
            if animation.mode == "loop" || animation.mode == "mirror" || animation.wrapLoop {
                return true
            }
            let end = animation.length > 0 ? animation.length : (animation.tracks.compactMap(\.last?.frame).max() ?? 0)
            return time * animation.fps < end
        }
    }

    private static func isPaused(_ animation: WPESceneNumericAnimation) -> Bool {
        animation.startPaused == .value(true)
    }
}

public struct WPESceneCameraMotionSample: Equatable, Sendable {
    public let origin: SIMD3<Double>
    public let zoom: Double
    public static let identity = Self(origin: .zero, zoom: 1)

    public init(origin: SIMD3<Double>, zoom: Double) {
        self.origin = origin.x.isFinite && origin.y.isFinite && origin.z.isFinite ? origin : .zero
        self.zoom = zoom.isFinite && zoom > 0 ? zoom : 1
    }
}
