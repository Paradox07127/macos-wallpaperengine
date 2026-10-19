import Foundation

/// Authored camera selection and seeds, separate from the lossless camera-object mirror. Parsed after
/// user bindings resolve, so the selected camera and its seeds share one source.
public struct WPESceneCameraMotion: Equatable, Sendable {
    public let objectID: String
    public let origin: SIMD3<Double>
    public let zoom: Double
    public let angles: SIMD3<Double>
    public let originAnimation: WPESceneAnimatedValue?
    public let zoomAnimation: WPESceneAnimatedValue?
    public let anglesAnimation: WPESceneAnimatedValue?
    public let zoomScript: WPESceneTransformScript?
    public let originIsRelative: Bool
    public let originFollowsZoom: Bool

    public init(objectID: String, origin: SIMD3<Double>, zoom: Double,
                originAnimation: WPESceneAnimatedValue? = nil, zoomAnimation: WPESceneAnimatedValue? = nil,
                originIsRelative: Bool = false, originFollowsZoom: Bool = false,
                angles: SIMD3<Double> = .zero, anglesAnimation: WPESceneAnimatedValue? = nil,
                zoomScript: WPESceneTransformScript? = nil) {
        self.objectID = objectID
        self.origin = origin
        self.zoom = zoom
        self.angles = angles
        self.anglesAnimation = anglesAnimation
        self.zoomScript = zoomScript
        self.originAnimation = originAnimation
        self.zoomAnimation = zoomAnimation
        self.originIsRelative = originIsRelative
        self.originFollowsZoom = originFollowsZoom
    }
}
