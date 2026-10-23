#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal
import simd

/// Everything one draw needs except the per-frame engine constants.
struct WPEParityFrameDrawPlan {
    enum TextureSource {
        /// A graph resource, looked up in the frame's texture table.
        case resource(WPEResourceID)
        case image(MTLTexture)
    }

    /// One TEXS frame: its sampling transform, the sheet image it samples and how long it shows.
    struct SpriteStep {
        let frame: WPEParityUniformSpriteFrame
        let texture: MTLTexture
        let duration: Double
    }

    enum Geometry {
        case mesh(vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int, indexType: MTLIndexType = .uint16)
        case modelData(WPEParityModelDataMetalShape)
        /// Point lists the particle systems write each frame, one draw per batch.
        case particles(Particles)
    }

    struct Particles {
        let key: WPEParityParticleDrawKey
        let layers: WPEParityLayerTransformSet
        let perspective: Bool
        let compositeOwnerID: String?
        let renderer: WPEParityParticleRenderer
        /// Set for SPRITESHEET draws with TEXS frames.
        let renderVar1: SIMD4<Float>?
        /// Arena bytes of the largest batch one system, or one instance of an event group, can write.
        let maxBytes: Int
        /// Arena bytes each of this draw's batches takes for cbuffers and argument tables.
        let argumentBytes: Int
    }

    let pipeline: WPEParityPipeline
    let depthStencil: WPEParityDepthStencilState
    let rasterizer: WPEParityRasterizerState
    var geometry: Geometry
    /// The skinned puppet layer whose animator supplies the vertex stage's `g_Bones`.
    let puppetID: String?
    /// One table per frame variant: on odd frames each FBO swap pair binds its other side.
    var textures: [[String: TextureSource]]
    /// System declarations eligible to replace an authored image, never a graph-owned RT or glyph atlas.
    /// `aspect` is the slot width / height the image is centre-cropped to; nil binds it whole (keepaspect).
    var mediaSlots: [Int: (kind: WPEMediaSystemTexture, aspect: Float?)] = [:]
    /// Usershortcut and scene-texture slots, resolved by the product icon store.
    var userImageSlots: [Int: WPEUserImageSlot] = [:]
    /// Full-image UVs for a media replacement of a padded authored albedo; built once, not on artwork changes.
    var mediaGeometry: Geometry?
    /// A compiled authored-format conversion that cannot consume an RGBA8 media image unchanged.
    var mediaFormatFailures: [Int: String] = [:]
    let samplers: [String: WPEParitySamplerState]
    let uniforms: WPEParityUniformDraw
    /// Where a scene layer draw sits; nil for post-process and particle draws.
    let placement: Placement?
    /// Camera parallax or camerashake moves the view, so the layer matrices are recomputed every frame.
    var cameraMoves = false
    /// The state object whose live g_Color4/g_Color/g_Alpha the draw takes. `loaded` is the colour `constants`
    /// holds; nil for a script-created layer, whose constants hold its template's colour.
    var layerColor: (object: Int, loaded: SIMD4<Float>?)?
    /// The state material pass whose constants `materialConstants` re-pack into `constants`.
    var materialPass: Int?
    var materialConstants: [WPEHLSLStage: [WPEParityProgramBinding.MaterialConstant]] = [:]
    /// TEXS frames of each sprite-sheet slot, shown in turn for their durations.
    let sprites: [Int: [SpriteStep]]
    /// The binding description's constants per stage; the engine uniform set does not carry them.
    let constants: [WPEHLSLStage: [String: WPECBufferValue]]
    /// The binding's g_RenderVar0/1, which also land in the scene-wide store particle draws read.
    let renderVarWrites: (rv0: SIMD4<Float>?, rv1: SIMD4<Float>?)
    var textRenderVars: WPEParityTextDrawParameters?
    /// Native clip masks replace only RV0.x; the other lanes stay in the scene-wide store.
    var clipMaskInverted: Bool?
    /// Declared textures the frame does not have, bound to a transparent texel.
    let fallbackTextures: [String]

    struct Placement {
        let layers: WPEParityLayerTransformSet
        let objectID: String
        let kind: WPEParityLayerDrawKind
        let compositeOwnerID: String?
        var text: TextPlacement?

        func draw(parallax: SIMD2<Float>, camera: WPEParityCamera? = nil,
                  layers live: WPEParityLayerTransformSet? = nil) throws -> WPEParityUniformDraw {
            var layers = live ?? layers
            if let camera {
                layers.camera = camera
            }
            var placed = try layers.draw(objectID, kind: kind, compositeOwnerID: compositeOwnerID, parallax: parallax)
            guard let text else { return placed }
            if case let .compositeFill(size) = kind {
                placed.matrices = WPEParityTextMatrices.fbo(size: SIMD2(Int(size.x), Int(size.y)),
                                                            translation: text.translation ?? .zero)
                return placed
            }
            let layerModel = WPEParityTextMatrices.layerModel(layers.model(objectID), anchorOffset: text.anchorOffset,
                                                              blockOffset: text.blockOffset)
            let model = text.translation.map { WPEParityTextMatrices.direct(layerModel: layerModel, translation: $0) }
                ?? layerModel
            // Keep the common draw's V/P: it selects the scene or composite camera before applying the layer's
            // perspective push (1401e8aa0.c:314-342, 998-1001). Rebuilding the composite here lost that push.
            let layerMatrices = kind == .layer || kind == .lastEffectPass
            var matrices = if layerMatrices {
                placed.matrices
            } else {
                try layers.draw(objectID, kind: .layer, compositeOwnerID: compositeOwnerID, parallax: parallax).matrices
            }
            matrices.model = model
            if let ownerID = compositeOwnerID, let owner = layers.layers[ownerID] {
                matrices.model = layers.model(owner.id).inverse * model
            }
            placed.effectPass = WPEParityUniformEffectPass(
                layerModel: matrices.model, layerModelViewProjection: matrices.modelViewProjection,
                size: layers.layers[objectID]?.size ?? .zero, isLastPass: layerMatrices
            )
            if layerMatrices {
                placed.matrices = matrices
            }
            return placed
        }
    }

    /// Slot16 model terms for glyph/background and final text draws.
    /// Slot28 clearalpha bypasses this placement and uses W' with the inherited camera.
    struct TextPlacement {
        let anchorOffset: SIMD2<Float>
        let blockOffset: SIMD2<Float>
        /// The glyph or background translation; nil for effect passes and the final composite.
        let translation: SIMD2<Float>?
    }

    /// `parallax` is `WPEParityUniformParallax.smoothed` for the frame; `camera` is the frame's shaken camera.
    /// `layers` holds the live layer transforms once any moved; nil keeps the planned matrices.
    func frameUniforms(parallax: SIMD2<Float>, camera: WPEParityCamera? = nil,
                       layers: WPEParityLayerTransformSet? = nil) throws -> WPEParityUniformDraw {
        guard let placement else { return uniforms }
        let cameraChanged = camera.map { $0 != placement.layers.camera } ?? false
        guard cameraMoves || layers != nil || cameraChanged else { return uniforms }
        let placed = try placement.draw(parallax: parallax, camera: camera, layers: layers)
        var uniforms = uniforms
        (uniforms.matrices, uniforms.effectPass) = (placed.matrices, placed.effectPass)
        return uniforms
    }

    /// `textureSlots` holds the last TEXS rotation and translation written to each slot, across draws and frames.
    /// `puppets` holds this frame's bone animator of each skinned puppet layer, `textureAnimations` each image
    /// layer's script sprite state. `constants` replaces the planned ones; a `layerColor` overrides g_Color4,
    /// g_Color and g_Alpha. Mesh draws only.
    func makeDraw(frame: WPEParityUniformFrame, camera: WPEParityCamera? = nil, variant: Int,
                  textures table: [WPEResourceID: MTLTexture], textureSlots: inout [String: WPECBufferValue],
                  puppets: [String: WPEParityPuppetAnimator],
                  textureAnimations: [String: WPEParityTextureAnimation] = [:],
                  layers: WPEParityLayerTransformSet? = nil,
                  constants: [WPEHLSLStage: [String: WPECBufferValue]]? = nil,
                  layerColor: SIMD4<Float>? = nil, renderVar0: SIMD4<Float>? = nil,
                  textRenderVarState: WPEParityRenderVarState? = nil,
                  mediaTexture: (WPEMediaSystemTexture, Float?) -> MTLTexture? = { _, _ in nil },
                  userShortcutTexture: (WPEUserImageSlot) -> MTLTexture? = { _ in nil }) throws -> WPEParityDraw {
        let replacements = replacementTextures(mediaTexture: mediaTexture, userShortcutTexture: userShortcutTexture)
        let selectedGeometry = replacements[0] == nil ? geometry : mediaGeometry ?? geometry
        let vertices: MTLBuffer
        let indices: MTLBuffer?
        let indexCount: Int
        let indexType: MTLIndexType
        let vertexCount: Int
        switch selectedGeometry {
        case let .mesh(buffer, indexBuffer, count, type):
            (vertices, indices, indexCount, indexType, vertexCount) = (buffer, indexBuffer, count, type, 4)
        case let .modelData(shape):
            (vertices, indices, indexCount, indexType, vertexCount) = (
                shape.vertexBuffer, shape.indexBuffer, shape.indexCount, shape.indexType, shape.vertexCount
            )
        case .particles:
            throw WPEParityExecutionError.geometryDrawUnsupported
        }
        var state = try drawState(frame: frame,
                                  uniforms: frameUniforms(parallax: frame.parallax.smoothed, camera: camera,
                                                          layers: layers),
                                  variant: variant, table: table, textureSlots: &textureSlots, puppets: puppets,
                                  textureAnimations: textureAnimations, constants: constants ?? self.constants,
                                  replacementTextures: replacements)
        if let textRenderVarState, textRenderVars != nil {
            for (index, value) in [textRenderVarState.rv0, textRenderVarState.rv1,
                                   textRenderVarState.rv2, textRenderVarState.rv3].enumerated() {
                for stage in state.constants.keys {
                    state.constants[stage]?["g_RenderVar\(index)"] = .vector([value.x, value.y, value.z, value.w])
                }
            }
        }
        if let renderVar0 {
            let value = WPECBufferValue.vector([renderVar0.x, renderVar0.y, renderVar0.z, renderVar0.w])
            for stage in state.constants.keys {
                state.constants[stage]?["g_RenderVar0"] = value
            }
        }
        if let color = layerColor {
            for stage in state.constants.keys {
                state.constants[stage]?["g_Color4"] = .vector([color.x, color.y, color.z, color.w])
                state.constants[stage]?["g_Color"] = .vector([color.x, color.y, color.z])
                state.constants[stage]?["g_Alpha"] = .float(color.w)
            }
        }
        return WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                             constants: state.constants, uniforms: state.uniforms, textures: state.textures,
                             samplers: samplers, vertexBuffer: vertices, primitiveType: .triangle,
                             vertexCount: vertexCount, indexBuffer: indices, indexCount: indexCount,
                             indexType: indexType)
    }

    func applyRenderVarWrites(to state: inout WPEParityRenderVarState) {
        state.rv0 = renderVarWrites.rv0 ?? state.rv0
        state.rv1 = renderVarWrites.rv1 ?? state.rv1
        if let textRenderVars {
            state.apply(textRenderVars)
        }
        if let clipMaskInverted {
            state.rv0.x = clipMaskInverted ? 1 : 0
        }
    }

    /// One point-list draw per batch of live particles, its vertices copied into `arena`; none without live particles,
    /// which also leaves `renderVars`, the scene-wide g_RenderVar store, untouched. `layers` holds the live
    /// layer transforms once any moved.
    func makeParticleDraw(_ batch: WPEParityParticleDrawBatch,
                          frame: WPEParityUniformFrame, camera: WPEParityCamera, variant: Int,
                          textures table: [WPEResourceID: MTLTexture], arena: WPEParityFrameArena.Frame,
                          textureSlots: inout [String: WPECBufferValue], renderVars: inout WPEParityRenderVarState,
                          particles: inout WPEParityParticleFrame,
                          layers live: WPEParityLayerTransformSet? = nil,
                          mediaTexture: (WPEMediaSystemTexture, Float?) -> MTLTexture? = { _, _ in nil },
                          userShortcutTexture: (WPEUserImageSlot) -> MTLTexture? = { _ in nil }) throws -> WPEParityDraw? {
        guard case let .particles(particle) = geometry else { throw WPEParityExecutionError.geometryDrawUnsupported }
        let replacements = replacementTextures(mediaTexture: mediaTexture, userShortcutTexture: userShortcutTexture)
        if particle.renderVar1 != nil, replacements[0] != nil {
            // The GS consumes RV1 rather than image Rotation/Translation. Do not reuse authored TEXS metadata.
            throw WPEParityFrameSkip.program("particle media SPRITESHEET RV1 requires native evidence")
        }
        var layers = live ?? particle.layers
        layers.camera = camera
        var uniforms = uniforms
        uniforms.matrices = try WPEParityParticleMatrices.draw(
            layers, objectID: particle.key.objectID,
            modelMatrix: batch.modelMatrix, perspective: particle.perspective,
            compositeOwnerID: particle.compositeOwnerID, parallax: frame.parallax.smoothed
        )
        let model = uniforms.matrices.model
        func xyz(_ column: SIMD4<Float>) -> SIMD3<Float> {
            SIMD3(column.x, column.y, column.z)
        }
        // The frame's scene camera V, never the perspective or composite push.
        let vectors = WPEParityParticleOrientation.vectors(
            renderer: particle.renderer,
            modelRotation: simd_float3x3(xyz(model.columns.0), xyz(model.columns.1), xyz(model.columns.2)),
            sceneView: camera.view
        )
        func vector(_ value: SIMD3<Float>) -> WPECBufferValue {
            .vector([value.x, value.y, value.z])
        }
        let orientation: [String: WPECBufferValue] = [
            "g_OrientationForward": vector(vectors.forward), "g_OrientationRight": vector(vectors.right),
            "g_OrientationUp": vector(vectors.up),
        ]
        let vertices = batch.vertices
        guard let allocation = particles.upload(vertices, argumentBytes: particle.argumentBytes, to: arena) else {
            return nil
        }
        let state = try drawState(frame: frame, uniforms: uniforms, variant: variant, table: table,
                                  textureSlots: &textureSlots, puppets: [:], textureAnimations: [:], constants: constants,
                                  engineExtras: orientation, replacementTextures: replacements)
        // RV1 (SPRITESHEET only), then the entry's partial RV0.
        if let renderVar1 = particle.renderVar1 {
            renderVars.rv1 = renderVar1
        }
        renderVars.apply(vertices.renderVar0)
        let (rv0, rv1) = (renderVars.rv0, renderVars.rv1)
        let values: [String: WPECBufferValue] = [
            "g_RenderVar0": .vector([rv0.x, rv0.y, rv0.z, rv0.w]),
            "g_RenderVar1": .vector([rv1.x, rv1.y, rv1.z, rv1.w]),
        ]
        return WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                             constants: state.constants.mapValues { $0.merging(values) { $1 } },
                             uniforms: state.uniforms, textures: state.textures, samplers: samplers,
                             vertexBuffer: allocation.buffer, vertexBufferOffset: allocation.offset,
                             primitiveType: .point, vertexCount: vertices.count, dropsWhenArenaIsFull: true)
    }

    private func replacementTextures(mediaTexture: (WPEMediaSystemTexture, Float?) -> MTLTexture?,
                                     userShortcutTexture: (WPEUserImageSlot) -> MTLTexture?) -> [Int: MTLTexture] {
        var textures = mediaSlots.compactMapValues { mediaTexture($0.kind, $0.aspect) }
        for (slot, image) in userImageSlots {
            if let texture = userShortcutTexture(image) {
                textures[slot] = texture
            }
        }
        return textures
    }

    /// Per-stage constants (the binding's `constants`, then the puppet's bones), the engine inputs they override
    /// (engine set, then `engineExtras`) and the textures of `variant`.
    private func drawState(frame: WPEParityUniformFrame, uniforms: WPEParityUniformDraw, variant: Int,
                           table: [WPEResourceID: MTLTexture], textureSlots: inout [String: WPECBufferValue],
                           puppets: [String: WPEParityPuppetAnimator],
                           textureAnimations: [String: WPEParityTextureAnimation],
                           constants: [WPEHLSLStage: [String: WPECBufferValue]],
                           engineExtras: [String: WPECBufferValue] = [:],
                           replacementTextures: [Int: MTLTexture])
        throws -> (constants: [WPEHLSLStage: [String: WPECBufferValue]], uniforms: WPEParityDrawUniforms,
                   textures: [String: MTLTexture]) {
        for (slot, failure) in mediaFormatFailures where replacementTextures[slot] != nil {
            throw WPEParityFrameSkip.program(failure)
        }
        var uniforms = uniforms
        var spriteTextures: [String: MTLTexture] = [:]
        var systemTextures: [String: MTLTexture] = [:]
        for (slot, texture) in replacementTextures {
            if uniforms.textures.indices.contains(slot) {
                let width = Float(texture.width), height = Float(texture.height)
                uniforms.textures[slot] = WPEParityUniformTexture(
                    textureWidth: UInt32(texture.width), textureHeight: UInt32(texture.height),
                    imageWidth: UInt32(texture.width), imageHeight: UInt32(texture.height), mipMapInfo: 1,
                    spriteFrame: .init(x: 0, y: 0, widthX: width, widthY: 0, heightX: 0, heightY: height,
                                       imageWidth: width, imageHeight: height)
                )
            }
            systemTextures["g_Texture\(slot)"] = texture
        }
        // An individual texture animation picks the frame of the slots the layer's own image feeds; like 14015fdd0,
        // a frame outside the sheet reads frame 0.
        let own = placement.flatMap { placed in
            textureAnimations[placed.objectID].flatMap {
                $0.individual ? (image: WPEParitySceneResource.layerImage(placed.objectID), frame: $0.frame) : nil
            }
        }
        for (slot, steps) in sprites where slot < uniforms.textures.count && systemTextures["g_Texture\(slot)"] == nil {
            let step = if let own, case let .resource(id)? = textures[variant]["g_Texture\(slot)"], id == own.image {
                steps.indices.contains(own.frame) ? steps[own.frame] : steps.first
            } else {
                Self.sprite(steps, at: frame.clock.time)
            }
            uniforms.textures[slot]?.spriteFrame = step?.frame
            spriteTextures["g_Texture\(slot)"] = step?.texture
        }
        // The shadow atlas grows at frame time, and receivers read its live size from SHADOW_ATLAS_TEXEL (common_pbr_2.h:59-61).
        for slot in uniforms.textures.indices {
            guard case let .resource(id)? = textures[variant]["g_Texture\(slot)"], let texture = table[id],
                  texture.pixelFormat == .depth32Float else { continue }
            uniforms.textures[slot] = WPEParityUniformTexture(
                textureWidth: UInt32(texture.width), textureHeight: UInt32(texture.height),
                imageWidth: UInt32(texture.width), imageHeight: UInt32(texture.height), mipMapInfo: 1
            )
        }
        func spriteFrame(_ slot: Int) -> WPEParityUniformSpriteFrame? {
            uniforms.textures.indices.contains(slot) ? uniforms.textures[slot]?.spriteFrame : nil
        }
        // Only a bound sprite frame writes these; any other draw uploads what the slot last held.
        for slot in 0 ..< min(uniforms.textures.count, WPEParityUniformTextures.slotCount) {
            guard let sprite = spriteFrame(slot) else { continue }
            let (rotation, translation) = (sprite.rotation, sprite.translation)
            textureSlots[WPEParityUniformTextures.rotationNames[slot]] =
                .vector([rotation.x, rotation.y, rotation.z, rotation.w])
            textureSlots[WPEParityUniformTextures.translationNames[slot]] = .vector([translation.x, translation.y])
        }
        var extras = engineExtras
        for (name, slot) in pipeline.textureTransforms where spriteFrame(slot) == nil && extras[name] == nil {
            extras[name] = textureSlots[name]
        }
        let stages = pipeline.geometry == nil ? Self.meshStages : Self.geometryStages
        var stageConstants: [WPEHLSLStage: [String: WPECBufferValue]] = [:]
        stageConstants.reserveCapacity(stages.count)
        for stage in stages {
            stageConstants[stage] = constants[stage] ?? [:]
        }
        if let animator = puppetID.flatMap({ puppets[$0] }) {
            stageConstants[.vertex, default: [:]].merge(animator.values) { $1 }
        }
        var boundTextures: [String: MTLTexture] = try textures[variant].mapValues { source in
            switch source {
            case let .resource(id):
                guard let texture = table[id] else { throw WPEParityGraphExecutionError.missingTexture(id) }
                return texture
            case let .image(texture):
                return texture
            }
        }
        boundTextures.merge(spriteTextures) { $1 }
        boundTextures.merge(systemTextures) { $1 }
        return (stageConstants, WPEParityDrawUniforms(frame: frame, draw: uniforms, extras: extras), boundTextures)
    }

    private static let meshStages: [WPEHLSLStage] = [.vertex, .fragment]
    private static let geometryStages: [WPEHLSLStage] = [.vertex, .geometry, .fragment]

    private static func sprite(_ steps: [SpriteStep], at time: Double) -> SpriteStep? {
        steps.isEmpty ? nil : steps[sharedSprite(steps, at: time).frame]
    }

    /// The frame showing at `time`, looping over the whole sequence, and the seconds into it.
    static func sharedSprite(_ steps: [SpriteStep], at time: Double) -> (frame: Int, time: Float) {
        let total = steps.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return (0, 0) }
        var remaining = time.truncatingRemainder(dividingBy: total)
        for (index, step) in steps.enumerated() {
            if remaining < step.duration || index == steps.count - 1 {
                return (index, Float(remaining))
            }
            remaining -= step.duration
        }
        return (0, 0)
    }
}
#endif
