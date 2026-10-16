import simd

public enum WPEParityLayerDrawKind: Sendable, Equatable {
    /// Layer albedo, or the last effect pass drawn onto the layer-size mesh.
    case layer
    /// Slot28 overwrites M with W' and inherits V/P before the text FBO/perspective pushes (140257c30.c).
    case textClearAlpha
    /// The albedo filling the layer's first composite of `size`.
    case compositeFill(size: SIMD2<Float>)
    /// An intermediate effect pass on the 2×2 quad.
    case effectPass
    /// Ancestor clip-mask multiplication uses a 2×2 quad with identity M/V/P (14020d6a0.c:80-165).
    case clipMaskMerge
    /// A pass of the last effect after its last flip: the 2×2 quad with the layer's matrices (1401e8aa0.c:951-1075).
    case lastEffectPass
}

/// The camera and every layer's world matrix, answering per draw with the matrices `WPEParityUniformSet` packs.
public struct WPEParityLayerTransformSet: Sendable {
    /// Replaced per frame by the shaken camera; layer worlds do not depend on it.
    public var camera: WPEParityCamera
    public private(set) var layers: [String: WPEParityLayerTransform]
    private var worlds: [String: simd_float4x4]
    /// Parents before children, each with the parent its world composes with; `refreshWorlds` walks it.
    private let order: [(id: String, parentID: String?)]
    /// A child's attachment point on its puppet parent (obj+0x190 ≥ 0): the MDAT bone and bind matrix.
    private let attachments: [String: (bone: Int, matrix: simd_float4x4)]
    /// Each attachment parent's rest-pose bone worlds, used until an animator supplies the frame's.
    private let restBones: [String: [simd_float4x4]]

    /// `puppetModels` (`WPEParityProgramScene.puppetModels`) resolves attachments: the parent's first MDAT entry with
    /// the name (1401fd510.c); a parent without a puppet resolves none (slot 14 returns −1).
    public init(camera: WPEParityCamera, layers: [WPEParityLayerTransform],
                puppetModels: [String: WPEPuppetModel] = [:]) {
        self.camera = camera
        let byID = Dictionary(layers.map { ($0.id, $0) }) { first, _ in first }
        self.layers = byID
        var attachments: [String: (bone: Int, matrix: simd_float4x4)] = [:]
        var restBones: [String: [simd_float4x4]] = [:]
        for layer in layers {
            guard let name = layer.attachment, let parentID = layer.parentID, let model = puppetModels[parentID],
                  let point = model.attachments.first(where: { $0.name == name }) else { continue }
            attachments[layer.id] = (point.boneIndex, point.matrix)
            if restBones[parentID] == nil {
                restBones[parentID] = WPEParityPuppetAnimator(model: model, layers: []).boneWorld
            }
        }
        self.attachments = attachments
        self.restBones = restBones
        var worlds: [String: simd_float4x4] = [:]
        var order: [(id: String, parentID: String?)] = []
        func world(_ id: String, _ visiting: Set<String>) -> simd_float4x4 {
            if let known = worlds[id] {
                return known
            }
            guard let layer = byID[id] else { return matrix_identity_float4x4 }
            var parent = matrix_identity_float4x4
            var parentID: String?
            if let candidate = layer.parentID, byID[candidate] != nil, !visiting.contains(candidate) {
                parent = world(candidate, visiting.union([id]))
                parentID = candidate
            }
            let result = parent * Self.attachmentMatrix(attachments[id], bones: parentID.flatMap { restBones[$0] })
                * layer.local
            worlds[id] = result
            order.append((id, parentID))
            return result
        }
        for id in byID.keys {
            _ = world(id, [])
        }
        self.worlds = worlds
        self.order = order
    }

    /// Children pinned to puppet attachment points; their worlds follow the parent's bones every frame.
    public var hasAttachments: Bool {
        !attachments.isEmpty
    }

    /// BoneWorld[bone] · AttachM, left of the child's local (1401fd5c0.c:14-35); nothing without bone worlds or with
    /// the bone out of range.
    private static func attachmentMatrix(_ attachment: (bone: Int, matrix: simd_float4x4)?,
                                         bones: [simd_float4x4]?) -> simd_float4x4 {
        guard let attachment, let bones, bones.indices.contains(attachment.bone) else {
            return matrix_identity_float4x4
        }
        return bones[attachment.bone] * attachment.matrix
    }

    /// A re-laid text layer's FBO extent also sizes its final composite and cursor quad.
    public mutating func setSize(_ id: String, size: SIMD2<Float>) {
        layers[id]?.size = size
    }

    /// Replaces a layer's own transform; the worlds follow on `refreshWorlds`.
    public mutating func setTransform(_ id: String, origin: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>) {
        layers[id]?.origin = origin
        layers[id]?.angles = angles
        layers[id]?.scale = scale
    }

    /// Descriptor fields with no native transform-dirty hook still affect the draw's V/P. The frame owner calls
    /// this when scriptFieldsGeneration changes; unchanged values leave the placement alone.
    @discardableResult
    public mutating func applyFields(state: WPEParitySceneState) -> Bool {
        var changed = false
        for id in layers.keys {
            if case let .vector(value)? = state.scriptField("parallaxDepth", of: id) {
                let depth = SIMD2(value.x, value.y)
                if layers[id]?.parallaxDepth != depth {
                    layers[id]?.parallaxDepth = depth
                    changed = true
                }
            }
            if case let .vector(value)? = state.scriptField("perspective", of: id) {
                let perspective = value.x != 0
                if layers[id]?.perspective != perspective {
                    layers[id]?.perspective = perspective
                    changed = true
                }
            }
        }
        return changed
    }

    /// Recomputes every world matrix from the current local transforms, parents on the left. `boneWorlds` gives a
    /// puppet parent's bone worlds for this frame (`WPEParityPuppetAnimator.boneWorld`); attachments to a parent it
    /// has none for use the rest pose. WPE recomputes attached worlds every frame.
    public mutating func refreshWorlds(boneWorlds: (String) -> [simd_float4x4]? = { _ in nil }) {
        for (id, parentID) in order {
            guard let local = layers[id]?.local else { continue }
            let parent = parentID.flatMap { worlds[$0] } ?? matrix_identity_float4x4
            guard let attachment = attachments[id], let parentID else {
                worlds[id] = parent * local
                continue
            }
            let bones = boneWorlds(parentID) ?? restBones[parentID]
            worlds[id] = parent * Self.attachmentMatrix(attachment, bones: bones) * local
        }
    }

    /// `textSizes` sizes the text layers (`WPEParityProgramScene.textSizes`); `puppetModels` resolves attachments.
    public init(document: WPESceneDocument, renderTargetSize: SIMD2<Float>,
                alignment: WPEParityCameraAlignment = .noCrop, cameraZoom: Float = 1,
                textSizes: [String: SIMD2<Float>] = [:], puppetModels: [String: WPEPuppetModel] = [:]) {
        self.init(camera: WPEParityCamera(document: document, renderTargetSize: renderTargetSize,
                                          alignment: alignment, cameraZoom: cameraZoom),
                  layers: WPEParityLayerTransform.layers(document: document)
                      + WPEParityLayerTransform.textLayers(document: document, sizes: textSizes),
                  puppetModels: puppetModels)
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
    public func view(_ id: String, parallax: SIMD2<Float>) throws -> simd_float4x4 {
        let view = sceneView(id, parallax: parallax)
        return layers[id]?.perspective == true
            ? try camera.pushPerspective(view: view, projection: camera.projection).view : view
    }

    /// The scene V with the object's parallax push (14018aac0.c:87-165), before any perspective replacement.
    private func sceneView(_ id: String, parallax: SIMD2<Float>) -> simd_float4x4 {
        guard let layer = layers[id] else { return camera.view }
        var root = layer
        var seen: Set<String> = [id]
        while let parentID = root.parentID, let parent = layers[parentID], seen.insert(parentID).inserted {
            root = parent
        }
        return camera.view(parallaxRoot: SIMD2(root.origin.x, root.origin.y), depth: root.parallaxDepth,
                           smoothed: parallax)
    }

    public func projection(_ id: String) throws -> simd_float4x4 {
        layers[id]?.perspective == true ? try camera.perspectiveProjection : camera.projection
    }

    /// Matrices and effect-pass values for one draw of `id`; `compositeOwnerID` places it in that layer's
    /// composite instead of the scene, also when the owner is a grandparent (140207b50.c:386-458).
    public func draw(_ id: String, kind: WPEParityLayerDrawKind, compositeOwnerID: String? = nil,
                     parallax: SIMD2<Float>) throws -> WPEParityUniformDraw {
        var matrices = WPEParityUniformMatrices(model: model(id),
                                                view: kind == .textClearAlpha ? camera.view : sceneView(id, parallax: parallax),
                                                projection: camera.projection)
        if let ownerID = compositeOwnerID, let owner = layers[ownerID] {
            if kind == .textClearAlpha {
                // The parent supplies only the inherited camera; slot28 replaces its inverse model entirely.
                matrices.view = matrix_identity_float4x4
                matrices.projection = WPEParityUniformMatrices.ortho(halfWidth: owner.size.x / 2,
                                                                     halfHeight: owner.size.y / 2, depth: 1000)
            } else {
                matrices = WPEParityLayerTransform.compositeMatrices(parentModel: model(ownerID), parentSize: owner.size,
                                                                     childModel: matrices.model)
            }
        }
        // 1401e8aa0.c:998-1001: the perspective replaces whichever V and P are pushed, composite ones included.
        if kind != .textClearAlpha, layers[id]?.perspective == true {
            (matrices.view, matrices.projection) = try camera.pushPerspective(view: matrices.view,
                                                                              projection: matrices.projection)
        }
        // 1401ebf60.c:201-333 branches on param_5, which every pass after the break carries.
        let effectPass = WPEParityUniformEffectPass(layerModel: matrices.model,
                                                    layerModelViewProjection: matrices.modelViewProjection,
                                                    size: layers[id]?.size ?? .zero,
                                                    isLastPass: kind == .layer || kind == .textClearAlpha || kind == .lastEffectPass)
        let drawn = switch kind {
        case .layer, .textClearAlpha, .lastEffectPass: matrices
        case let .compositeFill(size): WPEParityLayerTransform.compositeFillMatrices(size: size)
        case .effectPass: WPEParityUniformMatrices.effectPass
        case .clipMaskMerge: WPEParityUniformMatrices(model: matrix_identity_float4x4,
                                                      view: matrix_identity_float4x4,
                                                      projection: matrix_identity_float4x4)
        }
        return WPEParityUniformDraw(matrices: drawn, effectPass: effectPass)
    }

    public func quad(_ id: String, kind: WPEParityLayerDrawKind, uvMax: SIMD2<Float> = .one) -> WPEParityLayerQuad {
        switch kind {
        case .layer, .textClearAlpha: .layer(size: layers[id]?.size ?? .zero, uvMax: uvMax)
        case let .compositeFill(size): .composite(size: size, uvMax: uvMax)
        case .effectPass, .clipMaskMerge, .lastEffectPass: .effectPass
        }
    }
}
