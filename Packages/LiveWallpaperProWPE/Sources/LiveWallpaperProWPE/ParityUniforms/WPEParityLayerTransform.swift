import simd

/// Image-layer alignment as WPE numbers it (140211070.c:809-880).
public enum WPEParityLayerAlignment: Int, Sendable, CaseIterable {
    case center, top, topRight, right, bottomRight, bottom, bottomLeft, left, topLeft

    public init(_ alignment: WPESceneAlignment) {
        self = switch alignment {
        case .center: .center
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        case .topLeft: .topLeft
        }
    }

    /// Local-space offset applied before scale and rotation (1402066a0.c:89-117).
    public func offset(size: SIMD2<Float>) -> SIMD2<Float> {
        let half = size / 2
        return switch self {
        case .center: .zero
        case .top: SIMD2(0, -half.y)
        case .topRight: SIMD2(-half.x, -half.y)
        case .right: SIMD2(-half.x, 0)
        case .bottomRight: SIMD2(-half.x, half.y)
        case .bottom: SIMD2(0, half.y)
        case .bottomLeft: SIMD2(half.x, half.y)
        case .left: SIMD2(half.x, 0)
        case .topLeft: SIMD2(half.x, -half.y)
        }
    }
}

/// One scene node's own transform; the world matrix is the parent's world times `local` (1401850a0.c:34-55).
public struct WPEParityLayerTransform: Sendable, Equatable {
    public var id: String
    public var parentID: String?
    public var origin: SIMD3<Float>
    /// Radians, as authored.
    public var angles: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var size: SIMD2<Float>
    public var alignment: WPEParityLayerAlignment
    public var parallaxDepth: SIMD2<Float>
    /// obj+0x120 bit 0x80: drawn with the camera's perspective P and V.
    public var perspective: Bool

    public init(id: String, parentID: String? = nil, origin: SIMD3<Float>, angles: SIMD3<Float> = .zero,
                scale: SIMD3<Float> = .one, size: SIMD2<Float> = .zero, alignment: WPEParityLayerAlignment = .center,
                parallaxDepth: SIMD2<Float> = .zero, perspective: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.origin = origin
        self.angles = angles
        self.scale = scale
        self.size = size
        self.alignment = alignment
        self.parallaxDepth = parallaxDepth
        self.perspective = perspective
    }

    /// Image layers, groups and particle systems of a document with their local (not parent-baked) transforms.
    public static func layers(document: WPESceneDocument) -> [Self] {
        let ortho = document.general.orthogonalProjection
        let canvas = SIMD2(Float(ortho.width), Float(ortho.height))
        let autoID = WPEParityCamera.autoLayer(document)?.id
        var layers = document.imageObjects.map { image in
            let size = image.size.map { SIMD2(Float($0.width), Float($0.height)) } ?? canvas
            var origin = SIMD3<Float>(image.localOrigin)
            if image.id == autoID {
                origin = SIMD3(size / 2, origin.z)
            }
            return Self(id: image.id, parentID: image.parentObjectID, origin: origin,
                        angles: SIMD3(image.localAngles), scale: SIMD3(image.localScale), size: size,
                        alignment: WPEParityLayerAlignment(image.alignment),
                        parallaxDepth: SIMD2(image.parallaxDepth), perspective: image.usesPerspectiveProjection)
        }
        layers += document.transformHostObjects.map { group in
            Self(id: group.id, parentID: group.parentObjectID, origin: SIMD3(group.localOrigin),
                 angles: SIMD3(group.localAngles), scale: SIMD3(group.localScale),
                 parallaxDepth: SIMD2(group.parallaxDepth))
        }
        layers += document.particleObjects.map { particle in
            Self(id: particle.id, parentID: particle.parentObjectID, origin: SIMD3(particle.localOrigin),
                 angles: SIMD3(particle.localAngles), scale: SIMD3(particle.localScale),
                 parallaxDepth: SIMD2(particle.parallaxDepth))
        }
        return layers
    }

    /// Text layers of a document with their local transforms; `sizes` (`WPEParityProgramScene.textSizes`) gives each
    /// its FBO size, which WPE writes into the layer size (140258900.c:12-38).
    public static func textLayers(document: WPESceneDocument, sizes: [String: SIMD2<Float>] = [:]) -> [Self] {
        document.textObjects.map { text in
            Self(id: text.id, parentID: text.parentObjectID, origin: SIMD3(text.localOrigin ?? text.origin),
                 angles: SIMD3(text.localAngles ?? text.angles), scale: SIMD3(text.localScale ?? text.scale),
                 size: sizes[text.id] ?? .zero, parallaxDepth: SIMD2(text.parallaxDepth))
        }
    }

    /// T(origin)·Rz·Ry·Rx·S(scale) (1401dd630.c:16-36).
    public var local: simd_float4x4 {
        func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
            simd_float4x4(simd_quatf(angle: angle, axis: axis))
        }
        return WPEParityCamera.translation(origin) * rotation(angles.z, SIMD3(0, 0, 1))
            * rotation(angles.y, SIMD3(0, 1, 0)) * rotation(angles.x, SIMD3(1, 0, 0))
            * simd_float4x4(diagonal: SIMD4(scale, 1))
    }

    /// W' = W·T(alignment offset), used for this layer's own draws only (FUN_1401fd3f0).
    public func aligned(_ world: simd_float4x4) -> simd_float4x4 {
        world * WPEParityCamera.translation(SIMD3(alignment.offset(size: size), 0))
    }

    /// A child drawn into its parent's composite: M_top = inverse(W'_parent), V = I,
    /// P = ortho(±w/2, ±h/2, ±1000) (140207b50.c:357-417).
    public static func compositeMatrices(parentModel: simd_float4x4, parentSize: SIMD2<Float>,
                                         childModel: simd_float4x4) -> WPEParityUniformMatrices {
        WPEParityUniformMatrices(model: parentModel.inverse * childModel, view: matrix_identity_float4x4,
                                 projection: WPEParityUniformMatrices.ortho(halfWidth: parentSize.x / 2,
                                                                            halfHeight: parentSize.y / 2,
                                                                            depth: 1000))
    }

    /// The albedo filling a layer composite of `size`: M = V = I, P = ortho(0, w, 0, h, ±1000) (1401e8aa0.c:569-611).
    public static func compositeFillMatrices(size: SIMD2<Float>) -> WPEParityUniformMatrices {
        WPEParityUniformMatrices(model: matrix_identity_float4x4, view: matrix_identity_float4x4,
                                 projection: WPEParityCamera.ortho(left: 0, right: size.x, bottom: 0, top: size.y,
                                                                   near: -1000, far: 1000))
    }
}
