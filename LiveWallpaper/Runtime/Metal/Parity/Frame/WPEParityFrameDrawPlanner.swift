#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
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
        case mesh(vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)
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
        /// Set for SPRITESHEET draws with TEXS frames (R22 Q4).
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
    var mediaSlots: [Int: WPEMediaSystemTexture] = [:]
    /// Native usershortcut provider keys, resolved by the existing product icon store.
    var userShortcutSlots: [Int: String] = [:]
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
    /// The state object whose live g_Color4/g_Color/g_Alpha the draw takes, and the value `constants` holds.
    var layerColor: (object: Int, loaded: SIMD4<Float>)?
    /// The state material pass whose constants `materialConstants` re-pack into `constants`.
    var materialPass: Int?
    var materialConstants: [WPEHLSLStage: [WPEParityProgramBinding.MaterialConstant]] = [:]
    /// TEXS frames of each sprite-sheet slot, shown in turn for their durations.
    let sprites: [Int: [SpriteStep]]
    /// The binding description's constants per stage; the engine uniform set does not carry them.
    let constants: [WPEHLSLStage: [String: WPECBufferValue]]
    /// The binding's g_RenderVar0/1, which also land in the scene-wide store particle draws read (R22 Q3).
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

    /// Slot16 model terms for glyph/background and final text draws (R23 Q6).
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
    /// `puppets` holds this frame's bone animator of each skinned puppet layer. `constants` replaces the planned
    /// ones; a `layerColor` overrides g_Color4, g_Color and g_Alpha. Mesh draws only.
    func makeDraw(frame: WPEParityUniformFrame, camera: WPEParityCamera? = nil, variant: Int,
                  textures table: [WPEResourceID: MTLTexture], textureSlots: inout [String: WPECBufferValue],
                  puppets: [String: WPEParityPuppetAnimator], layers: WPEParityLayerTransformSet? = nil,
                  constants: [WPEHLSLStage: [String: WPECBufferValue]]? = nil,
                  layerColor: SIMD4<Float>? = nil, renderVar0: SIMD4<Float>? = nil,
                  textRenderVarState: WPEParityRenderVarState? = nil,
                  mediaTexture: (WPEMediaSystemTexture) -> MTLTexture? = { _ in nil },
                  userShortcutTexture: (String) -> MTLTexture? = { _ in nil }) throws -> WPEParityDraw {
        let replacements = replacementTextures(mediaTexture: mediaTexture, userShortcutTexture: userShortcutTexture)
        let selectedGeometry = replacements[0] == nil ? geometry : mediaGeometry ?? geometry
        let vertices: MTLBuffer
        let indices: MTLBuffer?
        let indexCount: Int
        let indexType: MTLIndexType
        let vertexCount: Int
        switch selectedGeometry {
        case let .mesh(buffer, indexBuffer, count):
            (vertices, indices, indexCount, indexType, vertexCount) = (buffer, indexBuffer, count, .uint16, 4)
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
                                  constants: constants ?? self.constants, replacementTextures: replacements)
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
        var draw = WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                                 constants: state.constants, textures: state.textures, samplers: samplers,
                                 vertexBuffer: vertices, primitiveType: .triangle, vertexCount: vertexCount)
        draw.indexBuffer = indices
        draw.indexCount = indexCount
        draw.indexType = indexType
        return draw
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
    /// which also leaves `renderVars`, the scene-wide g_RenderVar store, untouched (R22 Q3). `layers` holds the live
    /// layer transforms once any moved.
    func makeParticleDraw(_ batch: WPEParityParticleDrawBatch,
                          frame: WPEParityUniformFrame, camera: WPEParityCamera, variant: Int,
                          textures table: [WPEResourceID: MTLTexture], arena: WPEParityFrameArena.Frame,
                          textureSlots: inout [String: WPECBufferValue], renderVars: inout WPEParityRenderVarState,
                          particles: inout WPEParityParticleFrame,
                          layers live: WPEParityLayerTransformSet? = nil,
                          mediaTexture: (WPEMediaSystemTexture) -> MTLTexture? = { _ in nil },
                          userShortcutTexture: (String) -> MTLTexture? = { _ in nil }) throws -> WPEParityDraw? {
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
        // R22 Q2: the frame's scene camera V, never the perspective or composite push.
        let vectors = WPEParityParticleOrientation.vectors(
            renderer: particle.renderer,
            modelRotation: simd_float3x3(xyz(model.columns.0), xyz(model.columns.1), xyz(model.columns.2)),
            sceneView: camera.view
        )
        var orientation: [String: WPECBufferValue] = [:]
        for (name, vector) in [("Forward", vectors.forward), ("Right", vectors.right), ("Up", vectors.up)] {
            orientation["g_Orientation" + name] = .vector([vector.x, vector.y, vector.z])
        }
        let vertices = batch.vertices
        guard let allocation = particles.upload(vertices, argumentBytes: particle.argumentBytes, to: arena) else {
            return nil
        }
        let state = try drawState(frame: frame, uniforms: uniforms, variant: variant, table: table,
                                  textureSlots: &textureSlots, puppets: [:], constants: constants,
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
        var draw = WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                                 constants: state.constants.mapValues { $0.merging(values) { $1 } },
                                 textures: state.textures, samplers: samplers, vertexBuffer: allocation.buffer,
                                 primitiveType: .point, vertexCount: vertices.count)
        draw.vertexBufferOffset = allocation.offset
        draw.dropsWhenArenaIsFull = true
        return draw
    }

    private func replacementTextures(mediaTexture: (WPEMediaSystemTexture) -> MTLTexture?,
                                     userShortcutTexture: (String) -> MTLTexture?) -> [Int: MTLTexture] {
        var textures = mediaSlots.compactMapValues(mediaTexture)
        for (slot, key) in userShortcutSlots {
            if let texture = userShortcutTexture(key) {
                textures[slot] = texture
            }
        }
        return textures
    }

    /// Per-stage constants (engine set, `engineExtras`, then the binding's `constants`) and the textures of `variant`.
    private func drawState(frame: WPEParityUniformFrame, uniforms: WPEParityUniformDraw, variant: Int,
                           table: [WPEResourceID: MTLTexture], textureSlots: inout [String: WPECBufferValue],
                           puppets: [String: WPEParityPuppetAnimator],
                           constants: [WPEHLSLStage: [String: WPECBufferValue]],
                           engineExtras: [String: WPECBufferValue] = [:],
                           replacementTextures: [Int: MTLTexture])
        throws -> (constants: [WPEHLSLStage: [String: WPECBufferValue]], textures: [String: MTLTexture]) {
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
        for (slot, steps) in sprites where slot < uniforms.textures.count && systemTextures["g_Texture\(slot)"] == nil {
            let step = Self.sprite(steps, at: frame.clock.time)
            uniforms.textures[slot]?.spriteFrame = step?.frame
            spriteTextures["g_Texture\(slot)"] = step?.texture
        }
        var engine = WPEParityUniformSet.values(frame: frame, draw: uniforms)
        // R6: only a bound sprite frame writes these; any other draw uploads what the slot last held.
        for slot in 0 ..< WPEParityUniformTextures.slotCount {
            for name in ["g_Texture\(slot)Rotation", "g_Texture\(slot)Translation"] {
                if let value = engine[name] {
                    textureSlots[name] = value
                } else {
                    engine[name] = textureSlots[name]
                }
            }
        }
        engine.merge(engineExtras) { $1 }
        var stageConstants: [WPEHLSLStage: [String: WPECBufferValue]] = [:]
        for stage in pipeline.geometry == nil ? [WPEHLSLStage.vertex, .fragment] : [.vertex, .geometry, .fragment] {
            stageConstants[stage] = engine.merging(constants[stage] ?? [:]) { $1 }
        }
        if let animator = puppetID.flatMap({ puppets[$0] }) {
            stageConstants[.vertex, default: [:]].merge(animator.values) { $1 }
        }
        var boundTextures: [String: MTLTexture] = [:]
        for (name, source) in textures[variant] {
            switch source {
            case let .resource(id):
                guard let texture = table[id] else { throw WPEParityGraphExecutionError.missingTexture(id) }
                boundTextures[name] = texture
            case let .image(texture):
                boundTextures[name] = texture
            }
        }
        boundTextures.merge(spriteTextures) { $1 }
        boundTextures.merge(systemTextures) { $1 }
        return (stageConstants, boundTextures)
    }

    /// The frame showing at `time`, looping over the whole sequence.
    private static func sprite(_ steps: [SpriteStep], at time: Double) -> SpriteStep? {
        let total = steps.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return steps.first }
        var remaining = time.truncatingRemainder(dividingBy: total)
        for step in steps {
            if remaining < step.duration {
                return step
            }
            remaining -= step.duration
        }
        return steps.last
    }
}

/// Resolves frame draws against their compiled programs and the package's binding descriptions: pipeline,
/// geometry, textures, samplers and matrices.
struct WPEParityFrameDrawPlanner {
    static let pixelFormats: [String: MTLPixelFormat] = [
        "rgba8unorm": .rgba8Unorm, "rgba16float": .rgba16Float, "r8unorm": .r8Unorm, "rg8unorm": .rg8Unorm,
        "r16float": .r16Float, "rg16float": .rg16Float, "depth32float": .depth32Float,
    ]

    struct Image {
        let texture: MTLTexture
        /// Authored TEXI fields, including source format and flags. The texture describes the actual upload format.
        let info: WPETexInfo
        var sprites: [WPEParityFrameDrawPlan.SpriteStep] = []
        /// Final observations only; the planner's asset cache handles property invalidation.
        var conditionalSelection: WPETexConditionalSelection?
    }

    /// TEXI flag 0x20: the first mip is a video stream (1400ec220.c:851).
    private static let videoFlag: UInt32 = 0x20

    private struct PipelineKey: Hashable {
        let program: WPEHLSLProgram
        let blend: WPEParityBlendState
        let color: MTLPixelFormat
        let depth: MTLPixelFormat
        let samples: Int
    }

    let device: MTLDevice
    let factory: WPEParityPipelineFactory
    let plan: WPEParityFramePlan
    /// The layout `makePlan` plans draws of.
    private(set) var layout: WPEParityFrameLayout
    private var frame: WPEParityFrame
    private var resources: [WPEResourceID: WPELogicalResource]
    /// Colour and depth target bound at each draw operation.
    private var targets: [Int: (color: WPEResourceID, depth: WPEResourceID?)]
    /// The scene camera and every layer's world matrix.
    private(set) var layers: WPEParityLayerTransformSet
    private var assetImages: [String: Image] = [:]
    /// The same committed typed snapshot the Driver supplies, also used for assets first loaded by a later layout.
    private var userProperties: WPESceneJSONValue
    /// Imported layer images, filled as draws are planned.
    private(set) var layerImages: [WPEResourceID: MTLTexture] = [:]
    private var layerImageAssets: [WPEResourceID: Image] = [:]
    private var transparent: MTLTexture?
    /// Video .tex files the planned draws sample, filled as draws are planned.
    private(set) var videos: [WPEParityVideoTextures.Stream] = []
    private var pipelines: [PipelineKey: WPEParityPipeline] = [:]
    /// Pipeline states built, over the planner's life; draws with the same program and state share one.
    private(set) var pipelineCreations = 0
    /// The text layers' atlas textures, uploaded at load and after each re-layout.
    private(set) var textAtlases: WPEParityTextAtlasTextures
    /// Scene light terms; WPE writes them for every draw that declares them.
    let lights: WPEParityUniformLights
    /// Each text layer as last laid out, which its draws are planned from.
    private(set) var texts: [String: WPEParitySceneText] = [:]

    init(device: MTLDevice, factory: WPEParityPipelineFactory, plan: WPEParityFramePlan,
         preservingVideoImages: [String: Image] = [:], userProperties: WPESceneJSONValue = .object([:])) {
        self.device = device
        self.factory = factory
        self.plan = plan
        assetImages = preservingVideoImages
        self.userProperties = userProperties
        layout = plan.layout
        frame = plan.frames[0]
        resources = Self.resources(frame)
        targets = Self.targets(frame)
        // No camera path or camera object zoom yet.
        layers = WPEParityLayerTransformSet(document: plan.document,
                                            renderTargetSize: SIMD2(Float(plan.width), Float(plan.height)),
                                            alignment: plan.alignment, cameraZoom: 1,
                                            textSizes: plan.scene.textSizes, puppetModels: plan.scene.puppetModels)
        lights = WPEParityUniformLights(document: plan.document, transforms: layers)
        textAtlases = WPEParityTextAtlasTextures(atlases: plan.scene.textAtlases)
        textAtlases.upload(device: device)
        for object in plan.scene.scene.objects {
            if case let .text(text) = object.kind {
                texts[object.id] = text
            }
        }
    }

    var videoImages: [String: Image] {
        assetImages.filter { $0.value.info.flags & Self.videoFlag != 0 }
    }

    /// Derived from final observations on the existing asset owners. This is a view, not another watch registry.
    var conditionalPropertyBindings: [String: [WPEScenePropertyBinding]] {
        var result: [String: [WPEScenePropertyBinding]] = [:]
        for asset in assetImages.keys.sorted() {
            guard let selection = assetImages[asset]?.conditionalSelection else { continue }
            for key in selection.observations.keys {
                if let name = String(data: key, encoding: .utf8) {
                    result[name, default: []].append(WPEScenePropertyBinding(
                        propertyKey: name, target: .conditionalTexture(asset: asset), kind: .texture, action: .incremental
                    ))
                }
            }
        }
        return result
    }

    /// Prepare immutable replacements against the new committed snapshot in a value copy. The renderer can
    /// rebuild affected draws and adopt this planner plus imported bindings together, or keep its old valid
    /// cohort on failure. That failure policy is a Mac boundary, not a claim about native late-load errors.
    func preparingConditionalProperties(changed: WPESceneJSONValue, merged: WPESceneJSONValue)
        throws(WPEParityFrameSkip) -> (planner: Self, affectedOperations: Set<Int>) {
        var candidate = self
        candidate.userProperties = merged
        let names = Set(assetImages.compactMap { name, image in
            image.conditionalSelection?.requiresReload(changedProperties: changed) == true ? name : nil
        })
        guard !names.isEmpty else { return (candidate, []) }
        var replacements: [ObjectIdentifier: Image] = [:]
        for name in names.sorted() {
            guard let previous = assetImages[name] else { continue }
            candidate.assetImages.removeValue(forKey: name)
            let replacement = try candidate.assetImage(name)
            replacements[ObjectIdentifier(previous.texture)] = replacement
        }
        var imported: Set<WPEResourceID> = []
        for (id, old) in layerImageAssets {
            if let replacement = replacements[ObjectIdentifier(old.texture)] {
                candidate.layerImageAssets[id] = replacement
                candidate.layerImages[id] = replacement.texture
                imported.insert(id)
            }
        }
        var affected: Set<Int> = []
        for bindings in layout.bindings {
            for (operation, binding) in bindings where binding.textures.values.contains(where: { source in
                switch source {
                case let .asset(name): names.contains(name)
                case let .imported(id, name): imported.contains(id) || name.map(names.contains) == true
                case let .resource(id): imported.contains(id)
                case .textAtlas: false
                }
            }) {
                affected.insert(operation)
            }
        }
        return (candidate, affected)
    }

    /// Takes re-laid text layers and their atlases, uploading the atlases that changed; later plans of their draws
    /// read the new layouts.
    mutating func updateTexts(_ changed: some Sequence<WPEParitySceneText>,
                              atlases: [String: WPEParityGlyphAtlasInstance]) -> Bool {
        guard textAtlases.replace(atlases, device: device) else { return false }
        for text in changed {
            texts[text.object.id] = text
            layers.setSize(text.object.id, size: SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y)))
        }
        return true
    }

    /// A parameter-only field update keeps the admitted mesh/PSO and supplies new actual glyph RV writes.
    func refreshTextParameters(_ draw: inout WPEParityFrameDrawPlan, operation: Int) {
        guard case let .scene(description)? = frame.draws[operation], case .textGlyphs = description.geometry else { return }
        draw.textRenderVars = texts[description.objectID]?.fieldParameters
    }

    /// Rebinds the current immutable atlas version without touching another layer's glyph mesh or UVs.
    func refreshAtlasBindings(_ draw: inout WPEParityFrameDrawPlan, operation: Int) throws(WPEParityFrameSkip) {
        for variant in draw.textures.indices {
            guard let binding = layout.bindings[variant][operation] else { continue }
            for (slot, source) in binding.textures {
                guard case let .textAtlas(key, atlas, scale, plane) = source else { continue }
                guard let texture = textAtlases.textures[.init(atlasKey: key, atlas: atlas, colorScale: scale, plane: plane)] else {
                    throw .texture("Text atlas \(key) \(atlas) scale\(scale) \(plane) has no prepared texture")
                }
                draw.textures[variant]["g_Texture\(slot)"] = .image(texture)
            }
        }
    }

    /// Plans later draws from `layout`; loaded images and built pipelines carry over.
    mutating func use(_ layout: WPEParityFrameLayout) {
        self.layout = layout
        frame = layout.frames[0]
        resources = Self.resources(frame)
        targets = Self.targets(frame)
    }

    mutating func adoptModelDataTransforms(_ layers: WPEParityLayerTransformSet) {
        self.layers = layers
    }

    /// Drops the layer images of `objectIDs` and the assets their draws in `previous` sampled that no draw of the
    /// current layout samples; returns the dropped textures, which in-flight frames may still read.
    mutating func releaseImages(of objectIDs: Set<String>, droppedFrom previous: WPEParityFrameLayout) -> [MTLTexture] {
        func assets(_ layout: WPEParityFrameLayout, owned: (String?) -> Bool) -> Set<String> {
            var names: Set<String> = []
            for (frame, bindings) in zip(layout.frames, layout.bindings) {
                for (operation, binding) in bindings where owned(frame.owners[operation]) {
                    for source in binding.textures.values {
                        if case let .asset(name) = source {
                            names.insert(name)
                        } else if case let .imported(_, name?) = source {
                            names.insert(name)
                        }
                    }
                }
            }
            return names
        }
        var released: [MTLTexture] = []
        let dropped = assets(previous) { $0.map(objectIDs.contains) == true }
        for name in dropped.subtracting(assets(layout) { _ in true }) {
            if let image = assetImages.removeValue(forKey: name) {
                released += [image.texture] + image.sprites.map(\.texture)
            }
        }
        for id in objectIDs.map(WPEParitySceneResource.layerImage) {
            layerImageAssets.removeValue(forKey: id)
            if let texture = layerImages.removeValue(forKey: id) {
                released.append(texture)
            }
        }
        return released
    }

    /// Builds the pipeline draw `index` of `frame` needs, so a later plan of the same draw finds it.
    mutating func prewarmPipeline(_ frame: WPEParityFrame, _ index: Int, program: WPEParityProgram,
                                  artifact: WPEParityShaderArtifact) throws(WPEParityFrameSkip) {
        guard let description = frame.draws[index], let target = Self.targets(frame)[index] else {
            throw .pipeline("Missing draw or target during pipeline preparation")
        }
        _ = try pipeline(description, target: target, resources: Self.resources(frame), program: program,
                         artifact: artifact)
    }

    private mutating func pipeline(_ description: WPEParityFrameDraw,
                                   target: (color: WPEResourceID, depth: WPEResourceID?),
                                   resources: [WPEResourceID: WPELogicalResource], program: WPEParityProgram?,
                                   artifact: WPEParityShaderArtifact) throws(WPEParityFrameSkip) -> WPEParityPipeline {
        let shader = program?.shader ?? "operation"
        guard let color = resources[target.color], let colorFormat = Self.pixelFormats[color.format] else {
            throw .pipeline("\(shader): unknown target format")
        }
        let depthFormat = target.depth.flatMap { resources[$0] }.flatMap { Self.pixelFormats[$0.format] } ?? .invalid
        let blend = Self.blend(description)
        let key = program.map {
            PipelineKey(program: $0.hlsl, blend: blend, color: colorFormat, depth: depthFormat,
                        samples: color.sampleCount)
        }
        if let key, let cached = pipelines[key] {
            return cached
        }
        do {
            let pipeline = try factory.makePipeline(artifact: artifact, blend: blend, colorPixelFormat: colorFormat,
                                                    depthStencilPixelFormat: depthFormat,
                                                    sampleCount: color.sampleCount)
            pipelineCreations += 1
            if let key {
                pipelines[key] = pipeline
            }
            return pipeline
        } catch {
            throw .pipeline("\(shader): \(error)")
        }
    }

    private static func resources(_ frame: WPEParityFrame) -> [WPEResourceID: WPELogicalResource] {
        Dictionary(uniqueKeysWithValues: frame.resources.map { ($0.id, $0) })
    }

    private static func targets(_ frame: WPEParityFrame) -> [Int: (color: WPEResourceID, depth: WPEResourceID?)] {
        var targets: [Int: (color: WPEResourceID, depth: WPEResourceID?)] = [:]
        var bound: (color: WPEResourceID, depth: WPEResourceID?)?
        for (index, operation) in frame.operations.enumerated() {
            switch operation.kind {
            case let .setTargets(color, depth):
                bound = color.first.map { (color: $0.resource, depth: depth?.resource) }
            case .draw:
                targets[index] = bound
            default:
                break
            }
        }
        return targets
    }

    mutating func makePlan(_ index: Int,
                           artifact: WPEParityShaderArtifact) throws(WPEParityFrameSkip) -> WPEParityFrameDrawPlan {
        let shader = layout.programs[index]?.shader ?? "operation \(index)"
        guard let description = frame.draws[index], let target = targets[index], let color = resources[target.color],
              Self.pixelFormats[color.format] != nil
        else { throw .pipeline("operation \(index) has no draw or known target format") }
        let bindings = layout.bindings.compactMap { $0[index] }
        guard let binding = bindings.first, bindings.count == layout.frames.count else { throw .noMaterial }
        let declarations = binding.userTextures.bindings
        let hasMedia = [declarations.material, declarations.pass, declarations.override].joined().contains {
            WPEMediaSystemTexture(bindingName: $0.name) != nil
        }
        let hasUserShortcut = [declarations.material, declarations.pass, declarations.override].joined().contains {
            $0.type == "usershortcut"
        }
        if hasMedia || hasUserShortcut, !binding.userTextures.diagnostics.isEmpty {
            throw .texture("\(shader): \(binding.userTextures.diagnostics.joined(separator: "; "))")
        }
        // Native usertextures retains the provider type. A matching media name does not turn an explicit
        // user-shortcut or unknown provider into a system texture. Keep the older untyped form compatible.
        if let declaration = binding.userTextureSlots.values.first(where: {
            WPEMediaSystemTexture(bindingName: $0.name) != nil && $0.type != nil && $0.type != "system"
        }) {
            throw .texture("\(shader): media usertexture provider '\(declaration.type ?? "")' is unsupported")
        }
        var mediaSlots = binding.userTextureSlots.reduce(into: [Int: WPEMediaSystemTexture]()) { slots, entry in
            if entry.key >= 0, let kind = WPEMediaSystemTexture(bindingName: entry.value.name) {
                slots[Int(entry.key)] = kind
            }
        }
        var userShortcutSlots = binding.userTextureSlots.reduce(into: [Int: String]()) { slots, entry in
            if entry.key >= 0, entry.value.type == "usershortcut" {
                slots[Int(entry.key)] = entry.value.name
            }
        }
        let pipeline = try pipeline(description, target: target, resources: resources, program: layout.programs[index],
                                    artifact: artifact)
        func combo(_ name: String) -> Int32? {
            layout.programs[index].flatMap {
                ($0.combos + $0.textureCombos).last { $0.name == name }.flatMap { Int32($0.value) }
            }
        }
        var mediaFormatFailures: [Int: String] = [:]
        if ["genericparticle", "genericropeparticle"].contains(shader),
           let format = combo("TEX0FORMAT"), (8 ... 11).contains(format) {
            mediaFormatFailures[0] = "\(shader) media TEX0FORMAT \(format) needs a prepared RGBA8 program variant"
        }
        if shader == "generic4", combo("SHADINGGRADIENT").map({ $0 != 0 }) == true,
           let format = combo("TEX4FORMAT"), [8, 9].contains(format) {
            mediaFormatFailures[4] = "generic4 media gradient TEX4FORMAT \(format) needs a prepared RGBA8 program variant"
        }

        let particleKey: WPEParityParticleDrawKey? = if case let .scene(draw) = description,
                                                        case let .particles(key) = draw.geometry {
            key
        } else {
            nil
        }
        let sceneObject: WPEParitySceneObject? = if case let .scene(draw) = description {
            plan.scene.scene.objects.first { $0.id == draw.objectID }
        } else {
            nil
        }
        // A shape never binds `previous` (1401ebf60.c:146), and D3D11 samples an unbound slot as zero.
        let unboundIsTransparent = if particleKey != nil {
            true
        } else if case .shape? = sceneObject?.kind {
            true
        } else {
            false
        }
        var textures = [[String: WPEParityFrameDrawPlan.TextureSource]](repeating: [:], count: bindings.count)
        var samplers: [String: WPEParitySamplerState] = [:]
        var uniformTextures = [WPEParityUniformTexture?](repeating: nil, count: WPEParityUniformTextures.slotCount)
        var sprites: [Int: [WPEParityFrameDrawPlan.SpriteStep]] = [:]
        var fallbackTextures: [String] = []
        let reflections = [(WPEHLSLStage.vertex, artifact.vertex), (.geometry, artifact.geometry),
                           (.fragment, artifact.fragment)].compactMap { stage, artifact in
            artifact.map { (stage, $0.reflection) }
        }
        let names = Set(reflections.flatMap(\.1.resources).filter { $0.kind == .texture }.map(\.name))
        mediaSlots = mediaSlots.filter { names.contains("g_Texture\($0.key)") }
        userShortcutSlots = userShortcutSlots.filter { names.contains("g_Texture\($0.key)") }
        let text: WPEParitySceneText? = if case let .scene(draw) = description {
            texts[draw.objectID]
        } else {
            nil
        }
        for name in names.sorted() {
            guard name.hasPrefix("g_Texture"), let slot = Int32(name.dropFirst("g_Texture".count)) else {
                throw .texture("\(shader) declares \(name)")
            }
            for (variant, binding) in bindings.enumerated() {
                guard case let .draw(operation) = layout.frames[variant].operations[index].kind else {
                    throw .pipeline("operation \(index) is not a draw in frame variant \(variant)")
                }
                // A re-laid layer's font or size may have moved it to another atlas.
                var source = binding.textures[slot]
                if case let .textAtlas(_, atlas, _, plane)? = source, let text {
                    let scale = atlas == .color ? text.layout.mesh?.colorAtlasScale ?? 1 : 1
                    source = .textAtlas(key: text.atlasKey, atlas: atlas, colorScale: scale, plane: plane)
                }
                if source == nil, unboundIsTransparent {
                    textures[variant][name] = try .image(transparentTexture())
                    if variant == 0 {
                        fallbackTextures.append(name)
                    }
                } else {
                    // D3D unbound slots read zero. A bound but corrupt or unsupported resource
                    // is a different readiness failure; never report its transparent replacement as success.
                    let particleSnapshots: [WPEResourceID] = particleKey == nil ? [] : [
                        WPEParitySceneResource.fullFrameBuffer, WPEResourceID("_rt_MipMappedFrameBuffer"),
                    ]
                    textures[variant][name] = try textureSource(source, slot: slot, shader: shader,
                                                                reads: operation.reads.map(\.resource) + particleSnapshots)
                }
            }
            guard let source = textures[0][name] else { continue }
            samplers[name + "SamplerState"] = try sampler(source)
            if slot < uniformTextures.count {
                uniformTextures[Int(slot)] = uniformTexture(source)
                sprites[Int(slot)] = self.sprites(source)
            }
        }

        for (_, reflection) in reflections {
            for resource in reflection.resources where resource.kind == .texture {
                for (variant, sources) in textures.enumerated() {
                    guard let source = sources[resource.name] else { continue }
                    let type: MTLTextureType
                    switch source {
                    case let .image(texture): type = texture.textureType
                    case let .resource(id):
                        guard let target = layout.frames[variant].resources.first(where: { $0.id == id }) else {
                            throw .texture("\(shader) samples undeclared \(id)")
                        }
                        if target.lifetime == .imported, let image = layerImages[id] {
                            type = image.textureType
                        } else {
                            type = target.sampleCount > 1 ? .type2DMultisample : .type2D
                        }
                    }
                    do {
                        try WPEParityDrawEncoder.validateDimension(resource, textureType: type)
                    } catch {
                        throw .pipeline("\(shader): \(error)")
                    }
                }
            }
        }

        // Post-process draws have no layer and keep the effect-pass matrices; particle draws place themselves per frame.
        let placement: WPEParityFrameDrawPlan.Placement? = switch description {
        case .scene where particleKey != nil: nil
        case let .scene(draw):
            WPEParityFrameDrawPlan.Placement(
                layers: layers, objectID: draw.objectID,
                kind: draw.source == .textClearAlpha ? .textClearAlpha
                    : draw.fillsComposite ? .compositeFill(size: draw.logicalCompositeSize.map {
                        SIMD2(Float($0.x), Float($0.y))
                    } ?? SIMD2(Float(color.width), Float(color.height)))
                    : draw.multipliesDestination && draw.source == .flatTexture && draw.geometry == .fullscreenQuad ? .clipMaskMerge
                    : draw.geometry != .fullscreenQuad ? .layer
                    : draw.layerMatrices ? .lastEffectPass : .effectPass,
                compositeOwnerID: draw.compositeOwnerID,
                text: draw.source == .textClearAlpha ? nil : text.map { textPlacement($0, draw) }
            )
        case .post: nil
        }
        // R10: the composite fill samples only the image part of a padded albedo texture.
        let uvMax = uniformTextures[0].map {
            SIMD2(Float($0.imageWidth) / Float($0.textureWidth), Float($0.imageHeight) / Float($0.textureHeight))
        } ?? .one
        let quad = placement.map { placed in
            if case .compositeFill = placed.kind {
                layers.quad(placed.objectID, kind: placed.kind, uvMax: uvMax)
            } else {
                layers.quad(placed.objectID, kind: placed.kind)
            }
        } ?? .effectPass
        let puppetSegment: Int? = if case let .scene(draw) = description, case let .puppetSegment(index) = draw.geometry {
            index
        } else {
            nil
        }
        let puppet: WPEParityScenePuppet? = if case let .scene(draw) = description,
                                               draw.geometry == .puppetMesh || puppetSegment != nil {
            plan.scene.scene.objects.first { $0.id == draw.objectID }?.puppet
        } else {
            nil
        }
        let puppetID = puppet?.skinned == true ? placement?.objectID : nil
        let modelMesh: WPEPuppetMesh? = if case let .scene(draw) = description, draw.geometry == .modelMesh,
                                           let mesh = WPEParitySceneModel.meshIndex(draw.pass, objectID: draw.objectID),
                                           let meshes = plan.scene.models[draw.objectID]?.meshes,
                                           meshes.indices.contains(mesh) {
            meshes[mesh]
        } else {
            nil
        }
        let geometry: WPEParityFrameDrawPlan.Geometry
        let placed: WPEParityUniformDraw
        do {
            placed = try placement?.draw(parallax: .zero) ?? WPEParityUniformDraw(matrices: .effectPass)
        } catch {
            throw .program("Perspective placement failed: \(error)")
        }
        if let shape = layout.modelDataShapes[index] {
            guard let prepared = shape.prepared as? WPEParityModelDataMetalShape,
                  prepared.program.hlsl == layout.programs[index]?.hlsl else {
                throw .pipeline("\(shader): canonical model shape has no admitted resource version")
            }
            geometry = .modelData(prepared)
        } else if let particleKey, case let .scene(draw) = description {
            let particles = try particleGeometry(particleKey, compositeOwnerID: draw.compositeOwnerID,
                                                 pipeline: pipeline, shader: shader, texture0: uniformTextures[0],
                                                 frameCount: sprites[0]?.count ?? 0)
            geometry = .particles(particles)
            // A live batch supplies its final native D and current V/P in makeParticleDraw.
        } else {
            let inputs = artifact.vertex.reflection.vertexInputs
            let buffers = if let modelMesh {
                try Self.modelGeometry(modelMesh, inputs: inputs, device: device)
            } else if case let .scene(draw) = description, draw.geometry == .modelMesh {
                throw .pipeline("\(shader): \(draw.pass) has no model mesh")
            } else if let puppet {
                // R12 B3: only the direct draw scales by uvMax; the bit4 draw samples a composite, whose uvMax is 1.
                try Self.puppetGeometry(puppet, segment: puppetSegment, uvMax: uvMax, inputs: inputs, device: device)
            } else if case let .scene(draw) = description, let text, let mesh = Self.textMesh(text, draw.geometry) {
                Self.geometry(mesh.vertices, indices: mesh.indices, inputs: inputs, device: device)
            } else if case let .scene(draw) = description, draw.geometry == .shapeQuad, let object = sceneObject,
                      case let .shape(shape) = object.kind {
                Self.geometry(shape.vertices(width: Float(object.width), height: Float(object.height)).map {
                    Vertex(position: $0.position, texcoord: $0.texcoord)
                }, indices: shape.indices, inputs: inputs, device: device)
            } else {
                Self.geometry(quad.vertices.map { Vertex(position: $0.position, texcoord: $0.texcoord) },
                              indices: WPEParityLayerQuad.indices, inputs: inputs, device: device)
            }
            guard let buffers else { throw .pipeline("vertex or index buffer allocation failed") }
            geometry = .mesh(vertices: buffers.vertices, indices: buffers.indices, indexCount: buffers.indexCount)
        }
        let clipMaskInverted: Bool? = if case let .scene(draw) = description,
                                         draw.colorRole == .mask, draw.shader == "clippingmaskimage4" {
            draw.clipMaskInverted
        } else {
            nil
        }
        var mediaGeometry: WPEParityFrameDrawPlan.Geometry?
        if mediaSlots[0] != nil || userShortcutSlots[0] != nil, uvMax != .one {
            let inputs = artifact.vertex.reflection.vertexInputs
            let paddedComposite = placement.map {
                if case .compositeFill = $0.kind {
                    true
                } else {
                    false
                }
            } ?? false
            let buffers: (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)?
            if let puppet {
                buffers = try Self.puppetGeometry(puppet, segment: puppetSegment, uvMax: .one,
                                                  inputs: inputs, device: device)
            } else if let placement, case .compositeFill = placement.kind {
                let full = layers.quad(placement.objectID, kind: placement.kind, uvMax: .one)
                buffers = Self.geometry(full.vertices.map { Vertex(position: $0.position, texcoord: $0.texcoord) },
                                        indices: WPEParityLayerQuad.indices, inputs: inputs, device: device)
            } else {
                buffers = nil
            }
            if let buffers {
                mediaGeometry = .mesh(vertices: buffers.vertices, indices: buffers.indices, indexCount: buffers.indexCount)
            } else if puppet != nil || paddedComposite {
                throw .pipeline("media vertex or index buffer allocation failed")
            }
        }
        let uniforms = WPEParityUniformDraw(matrices: placed.matrices, effectPass: placed.effectPass,
                                            textures: uniformTextures)
        func renderVar(_ name: String) -> SIMD4<Float>? {
            let value = WPEHLSLStage.allCases.lazy.compactMap { binding.constants[$0]?[name] }.first
            guard case let .vector(components)? = value else { return nil }
            return SIMD4((components + [0, 0, 0, 0]).prefix(4))
        }

        return WPEParityFrameDrawPlan(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: binding.depthTest, depthWrite: binding.depthWrite),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: !binding.cullsBackFaces, slopeDepthBias: false,
                             multisample: false),
            geometry: geometry,
            puppetID: puppetID,
            textures: textures,
            mediaSlots: mediaSlots,
            userShortcutSlots: userShortcutSlots,
            mediaGeometry: mediaGeometry,
            mediaFormatFailures: mediaFormatFailures,
            samplers: samplers,
            uniforms: uniforms,
            placement: placement,
            cameraMoves: layers.camera.parallaxAmount != nil || layers.camera.shake != nil,
            layerColor: binding.layerColorObjectID.flatMap(plan.state.index(of:)).map {
                (object: $0, loaded: plan.state.layerColor(at: $0))
            },
            materialPass: binding.materialPass.flatMap(plan.state.passIndex(of:)),
            materialConstants: binding.materialConstants,
            sprites: sprites.filter { !$0.value.isEmpty },
            constants: binding.constants,
            renderVarWrites: particleKey == nil ? (renderVar("g_RenderVar0"), renderVar("g_RenderVar1")) : (nil, nil),
            textRenderVars: binding.textRenderVars,
            clipMaskInverted: clipMaskInverted,
            fallbackTextures: fallbackTextures
        )
    }

    /// The scene's particle draw for `key` with the renderer entry and slot count its own JSON gives.
    private func particleGeometry(_ key: WPEParityParticleDrawKey, compositeOwnerID: String?,
                                  pipeline: WPEParityPipeline, shader: String, texture0: WPEParityUniformTexture?,
                                  frameCount: Int) throws(WPEParityFrameSkip) -> WPEParityFrameDrawPlan.Particles {
        let entry = plan.scene.scene.objects.lazy.compactMap { object -> WPEParitySceneParticleDraw? in
            guard object.id == key.objectID, case let .particle(particle) = object.kind else { return nil }
            return particle.draws.first { $0.key == key }
        }.first
        guard let entry, let emulation = pipeline.geometry,
              let prototype = WPEParityParticleScene.prototype(for: key, document: plan.document, assets: plan.scene.assets),
              prototype.renderers.indices.contains(key.renderer)
        else { throw .pipeline("\(shader): no geometry stage or particle renderer for \(key)") }
        let renderer = prototype.renderers[key.renderer]
        let vertices = prototype.slotCount * (renderer.kind == .ropeTrail ? renderer.segments : 1)
        let renderVar1 = entry.source.combos["SPRITESHEET", default: 0] != 0
            ? texture0.flatMap { WPEParityRenderVarState.spriteSheetRV1(texture: $0, frameCount: frameCount) } : nil
        return WPEParityFrameDrawPlan.Particles(
            key: key, layers: layers, perspective: entry.perspective,
            compositeOwnerID: compositeOwnerID, renderer: renderer, renderVar1: renderVar1,
            maxBytes: vertices * emulation.vertexStride, argumentBytes: pipeline.argumentBytes
        )
    }

    /// The anchor from the crop margins (orthographic scenes only), the block offset, and the translation of a glyph
    /// list (direct, or into the text FBO) or of the background quad (140258050, 140257d70).
    private func textPlacement(_ text: WPEParitySceneText,
                               _ draw: WPEParitySceneDraw) -> WPEParityFrameDrawPlan.TextPlacement {
        let translation: SIMD2<Float>? = text.layout.mesh.flatMap { mesh in
            switch draw.geometry {
            case .textGlyphs where draw.fillsComposite:
                WPEParityTextMatrices.fboGlyphTranslation(mesh, padding: text.padding)
            case .textGlyphs:
                WPEParityTextMatrices.glyphTranslation(mesh)
            case .textBackground:
                WPEParityTextMatrices.backgroundTranslation(mesh, padding: text.padding)
            default:
                nil
            }
        }
        return WPEParityFrameDrawPlan.TextPlacement(
            anchorOffset: WPEParityTextMatrices.anchorOffset(text.object.anchor, margins: layers.camera.cropMargins,
                                                             orthographic: text.orthographic),
            blockOffset: text.layout.blockOffset, translation: translation
        )
    }

    /// Gives every imported resource without an image, such as a skipped draw's layer, a transparent texel.
    mutating func fillImportedImages() throws(WPEParityFrameSkip) {
        for resource in layout.frames.flatMap(\.resources) where resource.lifetime == .imported {
            try loadLayerImage(resource.id, name: nil)
        }
    }

    // MARK: Textures

    private mutating func textureSource(
        _ source: WPEParityProgramBinding.TextureSource?, slot: Int32, shader: String, reads: [WPEResourceID]
    ) throws(WPEParityFrameSkip) -> WPEParityFrameDrawPlan.TextureSource {
        switch source {
        case nil:
            throw .texture("\(shader) slot \(slot) is unbound")
        case let .resource(id)?:
            // The graph orders only the reads the frame declares.
            guard reads.contains(id) else { throw .texture("\(shader) slot \(slot) samples \(id) outside \(reads)") }
            return .resource(id)
        case let .imported(id, asset)?:
            try loadLayerImage(id, name: asset)
            return .resource(id)
        case let .asset(name)?:
            return try .image(assetImage(name).texture)
        case let .textAtlas(key, atlas, scale, plane)?:
            guard let texture = textAtlases.textures[WPEParityTextAtlasTextures.Key(atlasKey: key, atlas: atlas, colorScale: scale, plane: plane)] else {
                throw .texture("\(shader) slot \(slot) samples text atlas \(key) \(atlas), which has no texture")
            }
            return .image(texture)
        }
    }

    private mutating func loadLayerImage(_ id: WPEResourceID, name: String?) throws(WPEParityFrameSkip) {
        guard layerImages[id] == nil else { return }
        guard let name else {
            layerImages[id] = try transparentTexture()
            return
        }
        let image = try assetImage(name)
        layerImages[id] = image.texture
        layerImageAssets[id] = image
    }

    private mutating func transparentTexture() throws(WPEParityFrameSkip) -> MTLTexture {
        if let transparent {
            return transparent
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw .texture("transparent texel") }
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4),
                        bytesPerRow: 4)
        transparent = texture
        return texture
    }

    private mutating func assetImage(_ name: String) throws(WPEParityFrameSkip) -> Image {
        if let cached = assetImages[name] {
            return cached
        }
        let path = "materials/\(name).tex"
        // WPE never reads a texture named "error" (1400ec220.c:164-165); either way the draw samples its checker.
        guard name != "error", let data = plan.scene.assets.data(path) else {
            Logger.warning("Parity texture \(path) is missing; drawing the checker placeholder", category: .wpeRender)
            let image: Image
            do {
                image = try WPEParityTextureLoader.placeholder(device: device)
            } catch {
                throw .texture("\(path): \(error)")
            }
            assetImages[name] = image
            return image
        }
        let span = WPEMappedByteSpan(data: data)
        let image: Image
        if case let .success(info) = WPETexDecoder().probe(span: span), info.flags & Self.videoFlag != 0 {
            image = try videoImage(span, info: info, path: path)
        } else {
            do {
                image = try WPEParityTextureLoader.load(span: span, device: device, userProperties: userProperties)
            } catch WPETexDecodeError.unsupportedAnimation {
                throw .videoTexture(path)
            } catch {
                throw .texture("\(path): \(error)")
            }
        }
        assetImages[name] = image
        return image
    }

    /// WPE samples a cleared BGRA texture of the TEXI size and stretches each new video frame into it
    /// (1400ec220.c:851-1054); the renderer creates the decoder and clears the texture.
    private mutating func videoImage(_ span: WPEMappedByteSpan, info: WPETexInfo,
                                     path: String) throws(WPEParityFrameSkip) -> Image {
        guard case let .success(payload) = WPETexDecoder().extractTexturePayload(span: span),
              let video = payload.videoPayload
        else { throw .videoTexture("\(path) has TEXI flag 0x20 but no video payload") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: info.width,
                                                                  height: info.height, mipmapped: false)
        descriptor.storageMode = .private
        // Render target for the clear, shader write for the MPS stretch.
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw .texture("\(path): video texture allocation failed")
        }
        texture.label = path
        videos.append(WPEParityVideoTextures.Stream(texture: texture, bytes: video.bytes))
        return Image(texture: texture, info: info)
    }

    /// Composites use the sampler WPE creates with them; images follow their TEXI flags.
    private func sampler(_ source: WPEParityFrameDrawPlan.TextureSource) throws(WPEParityFrameSkip) -> WPEParitySamplerState {
        let info: WPETexInfo?
        switch source {
        case let .resource(id):
            if let composite = frame.samplers[id] {
                return .wpe(filter: composite.filter == .point ? .point : .linear,
                            address: composite.address == .clamp ? .clamp : .wrap)
            }
            info = layerImageAssets[id]?.info
        case let .image(texture):
            info = assetImages.values.first { $0.texture === texture }?.info
        }
        guard let info else { return .wpe(filter: .linear, address: .clamp) }
        guard let sampler = WPEParitySamplerState.wpeFileTexture(flags: info.flags) else {
            throw .texture("unsupported file texture sampler flags 0x\(String(info.flags, radix: 16))")
        }
        return sampler
    }

    private func uniformTexture(_ source: WPEParityFrameDrawPlan.TextureSource) -> WPEParityUniformTexture? {
        var texture: MTLTexture
        let info: WPETexInfo?
        switch source {
        case let .resource(id):
            if let image = layerImages[id] {
                (texture, info) = (image, layerImageAssets[id]?.info)
            } else {
                guard let resource = resources[id] else { return nil }
                let (width, height) = (UInt32(resource.width), UInt32(resource.height))
                return WPEParityUniformTexture(textureWidth: width, textureHeight: height, imageWidth: width,
                                               imageHeight: height, mipMapInfo: Int32(resource.mipCount))
            }
        case let .image(image):
            (texture, info) = (image, assetImages.values.first { $0.texture === image }?.info)
        }
        let sprites = sprites(source)
        // A sprite sheet reports the image its first frame samples.
        texture = sprites.first?.texture ?? texture
        let imageWidth = info.map(\.imageWidth).flatMap { $0 > 0 ? $0 : nil } ?? texture.width
        let imageHeight = info.map(\.imageHeight).flatMap { $0 > 0 ? $0 : nil } ?? texture.height
        return WPEParityUniformTexture(textureWidth: UInt32(texture.width), textureHeight: UInt32(texture.height),
                                       imageWidth: UInt32(imageWidth), imageHeight: UInt32(imageHeight),
                                       mipMapInfo: Int32(texture.mipmapLevelCount),
                                       spriteFrame: sprites.first?.frame)
    }

    private func sprites(_ source: WPEParityFrameDrawPlan.TextureSource) -> [WPEParityFrameDrawPlan.SpriteStep] {
        switch source {
        case let .resource(id): layerImageAssets[id]?.sprites ?? []
        case let .image(texture): assetImages.values.first { $0.texture === texture }?.sprites ?? []
        }
    }

    // MARK: State and geometry

    private static func blend(_ description: WPEParityFrameDraw) -> WPEParityBlendState {
        switch description {
        case let .scene(draw):
            let mode: WPEParityBlendMode = switch draw.blend {
            case .normal: .normal
            case .translucent: .translucent
            case .additive: .additive
            case .alphaToCoverage: .alphaToCoverage
            }
            var modifiers: WPEParityBlendModifiers = draw.writeMask == .rgba ? .writeAlpha : []
            if draw.alphaMax {
                modifiers.insert(.alphaMax)
            }
            if draw.multipliesDestination {
                modifiers.insert(.multiply)
            }
            return .wpe(mode, modifiers: modifiers)
        case let .post(draw):
            switch draw.blend {
            case .normal: return .wpe(.normal, modifiers: .writeAlpha)
            case .translucent: return .wpe(.translucent)
            case .additive: return .wpe(.additive)
            }
        }
    }

    struct Vertex {
        var position: SIMD3<Float>
        var texcoord: SIMD2<Float>
        var blendIndices = SIMD4<UInt32>.zero
        var blendWeights = SIMD4<Float>.zero
        var normal = SIMD3<Float>(0, 0, 1)
    }

    /// One model sub-mesh using the preserved MDLV stream. The current parser supplies R16 indices;
    /// the separate native model index-type contract still needs verification.
    static func modelGeometry(_ mesh: WPEPuppetMesh, inputs: [WPEStageReflection.StageAttribute],
                              device: MTLDevice) throws(WPEParityFrameSkip)
        -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        if let stream = mesh.vertexStream {
            return try rawGeometry(stream, indices: WPEParityScenePuppet.indices(of: mesh), inputs: inputs,
                                   uvMax: .one, device: device)
        }
        return geometry(mesh.vertices.map {
            Vertex(position: $0.position, texcoord: $0.uv, blendIndices: SIMD4(truncatingIfNeeded: $0.skinBlendIndices),
                   blendWeights: $0.skinBlendWeights, normal: $0.normal)
        }, indices: WPEParityScenePuppet.indices(of: mesh), inputs: inputs, device: device)
    }

    /// Mesh0 of a puppet layer, or one of its clip segments, with its texcoords scaled by `uvMax`.
    static func puppetGeometry(_ puppet: WPEParityScenePuppet, segment: Int? = nil, uvMax: SIMD2<Float>,
                               inputs: [WPEStageReflection.StageAttribute],
                               device: MTLDevice) throws(WPEParityFrameSkip)
        -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        let indices = segment.map { Array(puppet.clipIndices[puppet.clipSegments[$0]]) } ?? puppet.indices
        if let stream = puppet.vertexStream {
            return try rawGeometry(stream, indices: indices, inputs: inputs, uvMax: uvMax, device: device)
        }
        return geometry(puppet.vertices.map {
            Vertex(position: $0.position, texcoord: $0.uv * uvMax,
                   blendIndices: SIMD4(truncatingIfNeeded: $0.skinBlendIndices), blendWeights: $0.skinBlendWeights)
        }, indices: indices, inputs: inputs, device: device)
    }

    /// Maps the immutable native stream to MSC's tightly packed stage inputs once at draw planning. Native
    /// input-layout types feed registers as raw 32-bit words, including uint BLENDINDICES and float NaN payloads.
    /// D3D11 missing format components are zero except W=1 in the source element's interpretation.
    static func rawVertexWords(_ stream: WPEPuppetVertexStream, inputs: [WPEStageReflection.StageAttribute],
                               uvMax: SIMD2<Float> = .one) throws(WPEParityFrameSkip) -> [UInt32] {
        let count = try rawVertexWordCount(stream, inputs: inputs)
        var words = [UInt32](repeating: 0, count: count)
        let failure = words.withUnsafeMutableBufferPointer { buffer -> WPEParityFrameSkip? in
            do throws(WPEParityFrameSkip) {
                try writeRawVertexWords(stream, inputs: inputs, uvMax: uvMax, to: buffer)
                return nil
            } catch {
                return error
            }
        }
        if let failure {
            throw failure
        }
        return words
    }

    static func rawVertexWordCount(_ stream: WPEPuppetVertexStream,
                                   inputs: [WPEStageReflection.StageAttribute]) throws(WPEParityFrameSkip) -> Int {
        var width = 0
        for input in inputs {
            guard (1 ... 4).contains(input.columns) else { throw .pipeline("invalid vertex input width") }
            let added = width.addingReportingOverflow(input.columns)
            guard !added.overflow else { throw .pipeline("vertex input width exceeds addressable storage") }
            width = added.partialValue
        }
        let count = stream.vertexCount.multipliedReportingOverflow(by: width)
        guard !count.overflow else { throw .pipeline("vertex input stream exceeds addressable storage") }
        return count.partialValue
    }

    /// ModelData writes straight into its immutable Metal upload, without a second full CPU word array.
    static func writeRawVertexWords(_ stream: WPEPuppetVertexStream, inputs: [WPEStageReflection.StageAttribute],
                                    uvMax: SIMD2<Float> = .one,
                                    to destination: UnsafeMutableBufferPointer<UInt32>) throws(WPEParityFrameSkip) {
        guard !stream.layout.hasSyntheticPosition else {
            throw .pipeline("MDLV vertex format is missing authored POSITION0")
        }
        guard stream.layout.stride > 0, stream.data.count % stream.layout.stride == 0,
              stream.layout.unsupportedFlags == 0 else {
            throw .pipeline("unsupported or malformed MDLV vertex format 0x\(String(stream.layout.format, radix: 16))")
        }
        struct Input {
            let attribute: WPEPuppetVertexAttribute
            let columns: Int
        }
        var resolved: [Input] = []
        for input in inputs.sorted(by: { $0.index < $1.index }) {
            guard (1 ... 4).contains(input.columns),
                  ["float", "int", "sint", "uint", "uint32"].contains(input.elementType.lowercased()) else {
                throw .pipeline("unsupported vertex input \(input.name):\(input.elementType)[\(input.columns)]")
            }
            let name = input.name.uppercased()
            let semantic = String(name.reversed().drop(while: { $0.isNumber }).reversed())
            let suffix = name.dropFirst(semantic.count)
            let index = suffix.isEmpty ? 0 : Int(suffix) ?? -1
            let attributes = stream.layout.attributes(semantic: semantic, index: index)
            guard attributes.count == 1, let attribute = attributes.first else {
                throw .pipeline("MDLV input \(input.name) has \(attributes.count) native elements")
            }
            resolved.append(Input(attribute: attribute, columns: input.columns))
        }
        let count = try rawVertexWordCount(stream, inputs: inputs)
        guard destination.count >= count else {
            throw .pipeline("vertex upload is shorter than its reflected input stream")
        }
        var output = 0
        stream.data.withUnsafeBytes { bytes in
            for vertex in 0 ..< stream.vertexCount {
                for input in resolved {
                    let attribute = input.attribute
                    for lane in 0 ..< input.columns {
                        var word: UInt32 = lane == 3
                            ? (attribute.componentType == .float32 ? Float(1).bitPattern : 1) : 0
                        if lane < attribute.componentCount {
                            let offset = vertex * stream.layout.stride + attribute.byteOffset + lane * 4
                            word = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                            // Only the puppet's first UV pair is adjusted for its albedo image; UV.zw/UV1+ survive.
                            if attribute.semantic == "TEXCOORD", attribute.semanticIndex == 0, lane < 2,
                               attribute.componentType == .float32, uvMax[lane] != 1 {
                                word = (Float(bitPattern: word) * uvMax[lane]).bitPattern
                            }
                        }
                        destination[output] = word
                        output += 1
                    }
                }
            }
        }
    }

    private static func rawGeometry(_ stream: WPEPuppetVertexStream, indices: [UInt16],
                                    inputs: [WPEStageReflection.StageAttribute], uvMax: SIMD2<Float>,
                                    device: MTLDevice) throws(WPEParityFrameSkip)
        -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        let words = try rawVertexWords(stream, inputs: inputs, uvMax: uvMax)
        guard let vertices = device.makeBuffer(length: max(16, words.count * 4), options: .storageModeShared),
              let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 2,
                                                  options: .storageModeShared) else { return nil }
        if !words.isEmpty {
            vertices.contents().copyMemory(from: words, byteCount: words.count * 4)
        }
        return (vertices, indexBuffer, indices.count)
    }

    /// One glyph list of a text layer, or its background quad from (0, 0) to the FBO size with the glyph quads'
    /// corner order and indices (R23 Q5).
    private static func textMesh(_ text: WPEParitySceneText,
                                 _ geometry: WPEParitySceneDraw.Geometry) -> (vertices: [Vertex], indices: [UInt16])? {
        switch geometry {
        case let .textGlyphs(list):
            guard let mesh = text.layout.mesh else { return nil }
            let glyphs = list == .mono ? mesh.mono : mesh.color
            return (glyphs.vertices.map { Vertex(position: SIMD3($0.x, $0.y, $0.z), texcoord: SIMD2($0.u, $0.v)) },
                    glyphs.indices)
        case .textBackground:
            let size = SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y))
            let corners: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0)]
            return (corners.map { Vertex(position: SIMD3($0 * size, 0), texcoord: SIMD2($0.x, 1 - $0.y)) },
                    [0, 2, 1, 1, 2, 3])
        default:
            return nil
        }
    }

    private static func geometry(_ vertices: [Vertex], indices: [UInt16], inputs: [WPEStageReflection.StageAttribute],
                                 device: MTLDevice) -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        guard let vertexBuffer = vertexBuffer(vertices, inputs: inputs, device: device),
              let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride,
                                                  options: .storageModeShared)
        else { return nil }
        return (vertexBuffer, indexBuffer, indices.count)
    }

    /// The vertices packed as the vertex reflection lists its inputs; BLENDINDICES stay integers.
    private static func vertexBuffer(_ vertices: [Vertex], inputs: [WPEStageReflection.StageAttribute],
                                     device: MTLDevice) -> MTLBuffer? {
        var words: [UInt32] = []
        for vertex in vertices {
            for input in inputs.sorted(by: { $0.index < $1.index }) {
                let name = input.name.lowercased()
                let floats: [Float] = if name.hasPrefix("position") {
                    [vertex.position.x, vertex.position.y, vertex.position.z, 1]
                } else if name == "texcoord0" {
                    [vertex.texcoord.x, vertex.texcoord.y, 0, 0]
                } else if name.hasPrefix("normal") {
                    [vertex.normal.x, vertex.normal.y, vertex.normal.z, 0]
                } else if name.hasPrefix("blendweight") {
                    (0 ..< 4).map { vertex.blendWeights[$0] }
                } else if name.hasPrefix("color") {
                    [1, 1, 1, 1]
                } else {
                    [0, 0, 0, 0]
                }
                let value = name.hasPrefix("blendindices") ? (0 ..< 4).map { vertex.blendIndices[$0] }
                    : floats.map(\.bitPattern)
                words += value.prefix(input.columns)
            }
        }
        // An input-less vertex stage still gets a buffer at the MSC vertex bind point.
        let length = max(16, words.count * MemoryLayout<UInt32>.stride)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        buffer.contents().copyMemory(from: words, byteCount: words.count * MemoryLayout<UInt32>.stride)
        return buffer
    }
}
#endif
