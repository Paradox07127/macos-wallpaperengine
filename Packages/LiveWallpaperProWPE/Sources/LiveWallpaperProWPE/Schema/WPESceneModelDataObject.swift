/// A numeric model reference uses the native ModelData registry, never the file-model/image resource path.
/// The canonical source JSON retains other class fields until their consumers are admitted.
public struct WPESceneModelDataObject: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let modelDataToken: UInt32
    public let parentObjectID: String?
    public let origin: SIMD3<Double>
    public let scale: SIMD3<Double>
    public let angles: SIMD3<Double>
    public let localOrigin: SIMD3<Double>
    public let localScale: SIMD3<Double>
    public let localAngles: SIMD3<Double>
    public let visible: Bool
    public let parallaxDepth: SIMD2<Double>
    public let usesPerspectiveProjection: Bool
    public let attachment: String?

    public init(id: String, name: String, modelDataToken: UInt32, parentObjectID: String?,
                origin: SIMD3<Double>, scale: SIMD3<Double>, angles: SIMD3<Double>,
                localOrigin: SIMD3<Double>, localScale: SIMD3<Double>, localAngles: SIMD3<Double>,
                visible: Bool, parallaxDepth: SIMD2<Double>, usesPerspectiveProjection: Bool,
                attachment: String?) {
        self.id = id
        self.name = name
        self.modelDataToken = modelDataToken
        self.parentObjectID = parentObjectID
        self.origin = origin
        self.scale = scale
        self.angles = angles
        self.localOrigin = localOrigin
        self.localScale = localScale
        self.localAngles = localAngles
        self.visible = visible
        self.parallaxDepth = parallaxDepth
        self.usesPerspectiveProjection = usesPerspectiveProjection
        self.attachment = attachment
    }
}
