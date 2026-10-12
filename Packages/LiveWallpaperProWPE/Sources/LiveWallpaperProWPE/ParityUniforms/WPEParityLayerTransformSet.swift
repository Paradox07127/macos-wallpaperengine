import simd

public enum WPEParityLayerDrawKind: Sendable, Equatable {
    /// Layer albedo, or the last effect pass drawn onto the layer-size mesh.
    case layer
    /// The albedo filling the layer's first composite of `size` (R10 step 1).
    case compositeFill(size: SIMD2<Float>)
    /// An intermediate effect pass on the 2×2 quad.
    case effectPass
}

/// The camera and every layer's world matrix, answering per draw with the matrices `WPEParityUniformSet` packs.
public struct WPEParityLayerTransformSet: Sendable {
    public let camera: WPEParityCamera
    public let layers: [String: WPEParityLayerTransform]
    private let worlds: [String: simd_float4x4]

    public init(camera: WPEParityCamera, layers: [WPEParityLayerTransform]) {
        self.camera = camera
        let byID = Dictionary(layers.map { ($0.id, $0) }) { first, _ in first }
        self.layers = byID
        var worlds: [String: simd_float4x4] = [:]
        func world(_ id: String, _ visiting: Set<String>) -> simd_float4x4 {
            if let known = worlds[id] {
                return known
            }
            guard let layer = byID[id] else { return matrix_identity_float4x4 }
            var parent = matrix_identity_float4x4
            if let parentID = layer.parentID, byID[parentID] != nil, !visiting.contains(parentID) {
                parent = world(parentID, visiting.union([id]))
            }
            let result = parent * layer.local
            worlds[id] = result
            return result
        }
        for id in byID.keys {
            _ = world(id, [])
        }
        self.worlds = worlds
    }

    public init(document: WPESceneDocument, renderTargetSize: SIMD2<Float>,
                alignment: WPEParityCameraAlignment = .noCrop, cameraZoom: Float = 1) {
        self.init(camera: WPEParityCamera(document: document, renderTargetSize: renderTargetSize,
                                          alignment: alignment, cameraZoom: cameraZoom),
                  layers: WPEParityLayerTransform.layers(document: document))
    }

    /// W: what children compose with.
    public func world(_ id: String) -> simd_float4x4 {
        worlds[id] ?? matrix_identity_float4x4
    }

    /// W' = g_ModelMatrix of the layer's own draws.
    public func model(_ id: String) -> simd_float4x4 {
        layers[id].map { $0.aligned(world(id)) } ?? matrix_identity_float4x4
    }

    /// `parallax` is `WPEParityUniformParallax.smoothed` for the frame.
    public func view(_ id: String, parallax: SIMD2<Float>) -> simd_float4x4 {
        guard let layer = layers[id] else { return camera.view }
        if layer.perspective {
            return camera.perspectiveView
        }
        var root = layer
        var seen: Set<String> = [id]
        while let parentID = root.parentID, let parent = layers[parentID], seen.insert(parentID).inserted {
            root = parent
        }
        return camera.view(parallaxRoot: SIMD2(root.origin.x, root.origin.y), depth: root.parallaxDepth,
                           smoothed: parallax)
    }

    public func projection(_ id: String) -> simd_float4x4 {
        layers[id]?.perspective == true ? camera.perspectiveProjection : camera.projection
    }

    /// Matrices and effect-pass values for one draw of `id`; `compositeOwnerID` places it in that layer's
    /// composite instead of the scene, also when the owner is a grandparent (140207b50.c:386-458).
    public func draw(_ id: String, kind: WPEParityLayerDrawKind, compositeOwnerID: String? = nil,
                     parallax: SIMD2<Float>) -> WPEParityUniformDraw {
        var matrices = WPEParityUniformMatrices(model: model(id), view: view(id, parallax: parallax),
                                                projection: projection(id))
        if let ownerID = compositeOwnerID, let owner = layers[ownerID] {
            matrices = WPEParityLayerTransform.compositeMatrices(parentModel: model(ownerID), parentSize: owner.size,
                                                                 childModel: matrices.model)
        }
        let effectPass = WPEParityUniformEffectPass(layerModel: matrices.model,
                                                    layerModelViewProjection: matrices.modelViewProjection,
                                                    size: layers[id]?.size ?? .zero, isLastPass: kind == .layer)
        let drawn = switch kind {
        case .layer: matrices
        case let .compositeFill(size): WPEParityLayerTransform.compositeFillMatrices(size: size)
        case .effectPass: WPEParityUniformMatrices.effectPass
        }
        return WPEParityUniformDraw(matrices: drawn, effectPass: effectPass)
    }

    public func quad(_ id: String, kind: WPEParityLayerDrawKind, uvMax: SIMD2<Float> = .one) -> WPEParityLayerQuad {
        switch kind {
        case .layer: .layer(size: layers[id]?.size ?? .zero, uvMax: uvMax)
        case let .compositeFill(size): .composite(size: size, uvMax: uvMax)
        case .effectPass: .effectPass
        }
    }
}
