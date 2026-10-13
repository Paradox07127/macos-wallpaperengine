#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Metal
import MetalKit
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
        /// Point lists the particle systems write each frame, one draw per batch.
        case particles(Particles)
    }

    struct Particles {
        let key: WPEParityParticleDrawKey
        let layers: WPEParityLayerTransformSet
        let worldSpace: Bool
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
    let geometry: Geometry
    /// The skinned puppet layer whose animator supplies the vertex stage's `g_Bones`.
    let puppetID: String?
    /// One table per frame variant: on odd frames each FBO swap pair binds its other side.
    let textures: [[String: TextureSource]]
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
    /// Per stage, declared constants that neither the binding nor the engine uniform set supplies, so they stay zero.
    let zeroConstants: [WPEHLSLStage: [String]]
    /// The binding's g_RenderVar0/1, which also land in the scene-wide store particle draws read (R22 Q3).
    let renderVarWrites: (rv0: SIMD4<Float>?, rv1: SIMD4<Float>?)
    /// Declared textures the frame does not have, bound to a transparent texel.
    let fallbackTextures: [String]

    struct Placement {
        let layers: WPEParityLayerTransformSet
        let objectID: String
        let kind: WPEParityLayerDrawKind
        let compositeOwnerID: String?
        var text: TextPlacement?

        func draw(parallax: SIMD2<Float>, camera: WPEParityCamera? = nil,
                  layers live: WPEParityLayerTransformSet? = nil) -> WPEParityUniformDraw {
            var layers = live ?? layers
            if let camera {
                layers.camera = camera
            }
            var placed = layers.draw(objectID, kind: kind, compositeOwnerID: compositeOwnerID, parallax: parallax)
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
            var matrices = WPEParityUniformMatrices(model: model, view: layers.view(objectID, parallax: parallax),
                                                    projection: layers.projection(objectID))
            if let ownerID = compositeOwnerID, let owner = layers.layers[ownerID] {
                matrices = WPEParityLayerTransform.compositeMatrices(parentModel: layers.model(ownerID),
                                                                     parentSize: owner.size, childModel: model)
            }
            placed.effectPass = WPEParityUniformEffectPass(
                layerModel: matrices.model, layerModelViewProjection: matrices.modelViewProjection,
                size: layers.layers[objectID]?.size ?? .zero, isLastPass: kind == .layer
            )
            if kind == .layer {
                placed.matrices = matrices
            }
            return placed
        }
    }

    /// A text layer draw's model terms (R23 Q6): every draw but the FBO glyphs moves with slot16, the layer model
    /// between T(anchor) and T(block offset).
    struct TextPlacement {
        let anchorOffset: SIMD2<Float>
        let blockOffset: SIMD2<Float>
        /// The glyph or background translation; nil for the clearalpha quad, effect passes and the final composite.
        let translation: SIMD2<Float>?
    }

    /// `parallax` is `WPEParityUniformParallax.smoothed` for the frame; `camera` is the frame's shaken camera.
    /// `layers` holds the live layer transforms once any moved; nil keeps the planned matrices.
    func frameUniforms(parallax: SIMD2<Float>, camera: WPEParityCamera? = nil,
                       layers: WPEParityLayerTransformSet? = nil) -> WPEParityUniformDraw {
        guard let placement, cameraMoves || layers != nil else { return uniforms }
        let placed = placement.draw(parallax: parallax, camera: camera, layers: layers)
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
                  layerColor: SIMD4<Float>? = nil) throws -> WPEParityDraw {
        guard case let .mesh(vertices, indices, indexCount) = geometry else {
            throw WPEParityExecutionError.geometryDrawUnsupported
        }
        var state = try drawState(frame: frame,
                                  uniforms: frameUniforms(parallax: frame.parallax.smoothed, camera: camera,
                                                          layers: layers),
                                  variant: variant, table: table, textureSlots: &textureSlots, puppets: puppets,
                                  constants: constants ?? self.constants)
        if let color = layerColor {
            for stage in state.constants.keys {
                state.constants[stage]?["g_Color4"] = .vector([color.x, color.y, color.z, color.w])
                state.constants[stage]?["g_Color"] = .vector([color.x, color.y, color.z])
                state.constants[stage]?["g_Alpha"] = .float(color.w)
            }
        }
        var draw = WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                                 constants: state.constants, textures: state.textures, samplers: samplers,
                                 vertexBuffer: vertices, primitiveType: .triangle, vertexCount: 4)
        draw.indexBuffer = indices
        draw.indexCount = indexCount
        return draw
    }

    /// One point-list draw per batch of live particles, its vertices copied into `arena`; none without live particles,
    /// which also leaves `renderVars`, the scene-wide g_RenderVar store, untouched (R22 Q3). `layers` holds the live
    /// layer transforms once any moved.
    func makeParticleDraws(frame: WPEParityUniformFrame, camera: WPEParityCamera, variant: Int,
                           textures table: [WPEResourceID: MTLTexture], arena: WPEParityFrameArena.Frame,
                           textureSlots: inout [String: WPECBufferValue], renderVars: inout WPEParityRenderVarState,
                           particles: inout WPEParityParticleFrame,
                           layers live: WPEParityLayerTransformSet? = nil) throws -> [WPEParityDraw] {
        guard case let .particles(particle) = geometry else { throw WPEParityExecutionError.geometryDrawUnsupported }
        let batches = particles.scene.batches(for: particle.key)
        guard !batches.isEmpty else { return [] }
        var layers = live ?? particle.layers
        layers.camera = camera
        var uniforms = uniforms
        uniforms.matrices = WPEParityParticleMatrices.draw(
            layers, objectID: particle.key.objectID,
            childLocal: particles.scene.childLocal(for: particle.key) ?? matrix_identity_float4x4,
            worldSpace: particle.worldSpace, perspective: particle.perspective,
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
        let state = try drawState(frame: frame, uniforms: uniforms, variant: variant, table: table,
                                  textureSlots: &textureSlots, puppets: [:], constants: constants,
                                  engineExtras: orientation)

        var draws: [WPEParityDraw] = []
        for batch in batches {
            guard let allocation = particles.upload(batch, argumentBytes: particle.argumentBytes, to: arena) else {
                continue
            }
            // R16 Q3: RV1 (SPRITESHEET only), then the entry's partial RV0.
            if let renderVar1 = particle.renderVar1 {
                renderVars.setRV1(renderVar1)
            }
            renderVars.apply(batch.renderVar0)
            let (rv0, rv1) = (renderVars.rv0, renderVars.rv1)
            let values: [String: WPECBufferValue] = [
                "g_RenderVar0": .vector([rv0.x, rv0.y, rv0.z, rv0.w]),
                "g_RenderVar1": .vector([rv1.x, rv1.y, rv1.z, rv1.w]),
            ]
            var draw = WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                                     constants: state.constants.mapValues { $0.merging(values) { $1 } },
                                     textures: state.textures, samplers: samplers, vertexBuffer: allocation.buffer,
                                     primitiveType: .point, vertexCount: batch.count)
            draw.vertexBufferOffset = allocation.offset
            draw.dropsWhenArenaIsFull = true
            draws.append(draw)
        }
        return draws
    }

    /// Per-stage constants (engine set, `engineExtras`, then the binding's `constants`) and the textures of `variant`.
    private func drawState(frame: WPEParityUniformFrame, uniforms: WPEParityUniformDraw, variant: Int,
                           table: [WPEResourceID: MTLTexture], textureSlots: inout [String: WPECBufferValue],
                           puppets: [String: WPEParityPuppetAnimator],
                           constants: [WPEHLSLStage: [String: WPECBufferValue]],
                           engineExtras: [String: WPECBufferValue] = [:])
        throws -> (constants: [WPEHLSLStage: [String: WPECBufferValue]], textures: [String: MTLTexture]) {
        var uniforms = uniforms
        var spriteTextures: [String: MTLTexture] = [:]
        for (slot, steps) in sprites where slot < uniforms.textures.count {
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
        let info: WPETexInfo?
        var sprites: [WPEParityFrameDrawPlan.SpriteStep] = []
    }

    /// TEXI flag 0x4: the file carries TEXS sprite frames.
    private static let spriteFlag: UInt32 = 0x4
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
    let layers: WPEParityLayerTransformSet
    private var assetImages: [String: Image] = [:]
    /// Imported layer images, filled as draws are planned.
    private(set) var layerImages: [WPEResourceID: MTLTexture] = [:]
    private var layerImageAssets: [WPEResourceID: Image] = [:]
    private var transparent: MTLTexture?
    /// Video .tex files the planned draws sample, filled as draws are planned.
    private(set) var videos: [WPEParityVideoTextures.Stream] = []
    private var pipelines: [PipelineKey: WPEParityPipeline] = [:]
    /// Pipeline states built, over the planner's life; draws with the same program and state share one.
    private(set) var pipelineCreations = 0
    /// The text layers' atlas textures, uploaded at load.
    private(set) var textAtlases: WPEParityTextAtlasTextures

    init(device: MTLDevice, factory: WPEParityPipelineFactory, plan: WPEParityFramePlan) {
        self.device = device
        self.factory = factory
        self.plan = plan
        layout = plan.layout
        frame = plan.frames[0]
        resources = Self.resources(frame)
        targets = Self.targets(frame)
        // No camera path or camera object zoom yet.
        layers = WPEParityLayerTransformSet(document: plan.document,
                                            renderTargetSize: SIMD2(Float(plan.width), Float(plan.height)),
                                            alignment: plan.alignment, cameraZoom: 1,
                                            textSizes: plan.scene.textSizes)
        textAtlases = WPEParityTextAtlasTextures(atlases: plan.scene.textAtlases)
        textAtlases.upload(device: device)
    }

    /// Plans later draws from `layout`; loaded images and built pipelines carry over.
    mutating func use(_ layout: WPEParityFrameLayout) {
        self.layout = layout
        frame = layout.frames[0]
        resources = Self.resources(frame)
        targets = Self.targets(frame)
    }

    /// Builds the pipeline draw `index` of `frame` needs, so a later plan of the same draw finds it.
    mutating func prewarmPipeline(_ frame: WPEParityFrame, _ index: Int, program: WPEParityProgram,
                                  artifact: WPEParityShaderArtifact) {
        guard let description = frame.draws[index], let target = Self.targets(frame)[index] else { return }
        _ = try? pipeline(description, target: target, resources: Self.resources(frame), program: program,
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
        let pipeline = try pipeline(description, target: target, resources: resources, program: layout.programs[index],
                                    artifact: artifact)

        let particleKey: WPEParityParticleDrawKey? = if case let .scene(draw) = description,
                                                        case let .particles(key) = draw.geometry {
            key
        } else {
            nil
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
        for name in names.sorted() {
            guard name.hasPrefix("g_Texture"), let slot = Int32(name.dropFirst("g_Texture".count)) else {
                throw .texture("\(shader) declares \(name)")
            }
            for (variant, binding) in bindings.enumerated() {
                guard case let .draw(operation) = layout.frames[variant].operations[index].kind else {
                    throw .pipeline("operation \(index) is not a draw in frame variant \(variant)")
                }
                do throws(WPEParityFrameSkip) {
                    textures[variant][name] = try textureSource(binding.textures[slot], slot: slot, shader: shader,
                                                                reads: operation.reads.map(\.resource))
                } catch .texture(_) where particleKey != nil {
                    textures[variant][name] = try .image(transparentTexture())
                    if variant == 0 {
                        fallbackTextures.append(name)
                    }
                }
            }
            guard let source = textures[0][name] else { continue }
            samplers[name + "SamplerState"] = sampler(source)
            if slot < uniformTextures.count {
                uniformTextures[Int(slot)] = uniformTexture(source)
                sprites[Int(slot)] = self.sprites(source)
            }
        }

        let text: WPEParitySceneText? = if case let .scene(draw) = description,
                                           let object = plan.scene.scene.objects.first(where: { $0.id == draw.objectID }),
                                           case let .text(sceneText) = object.kind {
            sceneText
        } else {
            nil
        }
        // Post-process draws have no layer and keep the effect-pass matrices; particle draws place themselves per frame.
        let placement: WPEParityFrameDrawPlan.Placement? = switch description {
        case .scene where particleKey != nil: nil
        case let .scene(draw):
            WPEParityFrameDrawPlan.Placement(
                layers: layers, objectID: draw.objectID,
                kind: draw.fillsComposite ? .compositeFill(size: SIMD2(Float(color.width), Float(color.height)))
                    : draw.geometry == .fullscreenQuad ? .effectPass : .layer,
                compositeOwnerID: draw.compositeOwnerID,
                text: text.map { textPlacement($0, draw) }
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
        let puppet: WPEParityScenePuppet? = if case let .scene(draw) = description, draw.geometry == .puppetMesh {
            plan.scene.scene.objects.first { $0.id == draw.objectID }?.puppet
        } else {
            nil
        }
        let puppetID = puppet?.skinned == true ? placement?.objectID : nil
        let geometry: WPEParityFrameDrawPlan.Geometry
        var placed = placement?.draw(parallax: .zero) ?? WPEParityUniformDraw(matrices: .effectPass)
        if let particleKey, case let .scene(draw) = description {
            let particles = try particleGeometry(particleKey, compositeOwnerID: draw.compositeOwnerID,
                                                 pipeline: pipeline, shader: shader, texture0: uniformTextures[0],
                                                 frameCount: sprites[0]?.count ?? 0)
            geometry = .particles(particles)
            placed.matrices = WPEParityParticleMatrices.draw(
                layers, objectID: particleKey.objectID, childLocal: matrix_identity_float4x4,
                worldSpace: particles.worldSpace, perspective: particles.perspective,
                compositeOwnerID: particles.compositeOwnerID, parallax: .zero
            )
        } else {
            let inputs = artifact.vertex.reflection.vertexInputs
            let buffers = if let puppet {
                // R12 B3: only the direct draw scales by uvMax; the bit4 draw samples a composite, whose uvMax is 1.
                Self.puppetGeometry(puppet, uvMax: uvMax, inputs: inputs, device: device)
            } else if case let .scene(draw) = description, let text, let mesh = Self.textMesh(text, draw.geometry) {
                Self.geometry(mesh.vertices, indices: mesh.indices, inputs: inputs, device: device)
            } else {
                Self.geometry(quad.vertices.map { Vertex(position: $0.position, texcoord: $0.texcoord) },
                              indices: WPEParityLayerQuad.indices, inputs: inputs, device: device)
            }
            guard let buffers else { throw .pipeline("vertex or index buffer allocation failed") }
            geometry = .mesh(vertices: buffers.vertices, indices: buffers.indices, indexCount: buffers.indexCount)
        }
        let uniforms = WPEParityUniformDraw(matrices: placed.matrices, effectPass: placed.effectPass,
                                            textures: uniformTextures)

        let probe = WPEParityUniformFrame(clock: WPEParityClock(), daytime: 0,
                                          screen: WPEParityUniformScreen(clientWidth: 1, clientHeight: 1),
                                          pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
                                          eyePosition: layers.camera.eyePosition, view: layers.camera.view)
        var engine = Set(WPEParityUniformSet.values(frame: probe, draw: uniforms).keys)
        if puppetID != nil {
            engine.insert("g_Bones")
        }
        if particleKey != nil {
            engine.formUnion(["g_OrientationForward", "g_OrientationRight", "g_OrientationUp", "g_RenderVar0",
                              "g_RenderVar1"])
        }
        var zeroConstants: [WPEHLSLStage: [String]] = [:]
        for (stage, reflection) in reflections {
            let declared = Set(reflection.cbuffers.flatMap(\.variables).map(\.name))
            let supplied = engine.union(binding.constants[stage]?.keys.map(\.self) ?? [])
            zeroConstants[stage] = declared.subtracting(supplied).sorted()
        }
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
            zeroConstants: zeroConstants,
            renderVarWrites: particleKey == nil ? (renderVar("g_RenderVar0"), renderVar("g_RenderVar1")) : (nil, nil),
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
              let system = WPEParityParticleProbe.system(for: key, document: plan.document, assets: plan.scene.assets),
              system.renderers.indices.contains(key.renderer)
        else { throw .pipeline("\(shader): no geometry stage or particle renderer for \(key)") }
        let renderer = system.renderers[key.renderer]
        let vertices = system.position.count * (renderer.kind == .ropeTrail ? renderer.segments : 1)
        let renderVar1 = entry.source.combos["SPRITESHEET", default: 0] != 0
            ? texture0.flatMap { WPEParityRenderVarState.spriteSheetRV1(texture: $0, frameCount: frameCount) } : nil
        return WPEParityFrameDrawPlan.Particles(
            key: key, layers: layers, worldSpace: entry.worldSpace, perspective: entry.perspective,
            compositeOwnerID: compositeOwnerID, renderer: renderer, renderVar1: renderVar1,
            maxBytes: vertices * emulation.vertexStride, argumentBytes: WPEParityDrawEncoder.argumentBytes(pipeline)
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
        case let .textAtlas(key, atlas)?:
            guard let texture = textAtlases.textures[WPEParityTextAtlasTextures.Key(atlasKey: key, atlas: atlas)] else {
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
        guard let data = plan.scene.assets.data(path) else {
            throw .texture("\(path) not found")
        }
        let span = WPEMappedByteSpan(data: data)
        let image: Image
        if case let .success(info) = WPETexDecoder().probe(span: span), info.flags & Self.videoFlag != 0 {
            image = try videoImage(span, info: info, path: path)
        } else {
            do {
                image = try Self.image(span, device: device)
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

    /// Uploads a .tex's first image and, for a TEXS sprite sheet, every other image its frames sample.
    static func image(_ span: WPEMappedByteSpan, device: MTLDevice) throws -> Image {
        let decoder = WPETexDecoder()
        let info = try decoder.probe(span: span).get()
        let first = try upload(decoder.decode(span: span).get(), device: device)
        guard info.flags & spriteFlag != 0 else { return Image(texture: first, info: info) }
        let payload = try decoder.extractTexturePayload(span: span).get()
        var images = [0: first]
        func texture(_ frame: WPETexAnimationFrame) throws -> MTLTexture {
            if let uploaded = images[frame.imageID] {
                return uploaded
            }
            guard let mip = frame.mipmaps.first else { throw WPETexDecodeError.missingBitmapBlock }
            let uploaded = try upload(rgbaImage(mip, info: payload.info).makeCGImage(), device: device)
            images[frame.imageID] = uploaded
            return uploaded
        }
        let sprites = try (payload.animationTrack?.frames ?? []).compactMap { frame in
            try sprite(frame, info: payload.info).map {
                try WPEParityFrameDrawPlan.SpriteStep(frame: $0, texture: texture(frame), duration: frame.duration)
            }
        }
        return Image(texture: first, info: info, sprites: sprites)
    }

    /// A sheet image's top mip decoded to RGBA as `WPETexDecoder.decode` decodes image 0.
    private static func rgbaImage(_ mip: WPETexTextureMipmap, info: WPETexInfo) throws -> DecodedRGBAImage {
        let (bytes, width, height, index) = (mip.bytes, mip.width, mip.height, mip.index)
        switch info.format {
        case .rgba8888:
            return try WPETexPixelDecoder.decodeRGBA8888(bytes, width: width, height: height, mipmap: index)
        case .r8:
            return try WPETexPixelDecoder.decodeR8(bytes, width: width, height: height, mipmap: index)
        case .rg88:
            return try WPETexPixelDecoder.decodeRG88(bytes, width: width, height: height, mipmap: index,
                                                     alphaChannelPriority: info.isRG88LuminanceAlpha)
        case let format? where [.dxt1, .dxt3, .dxt5, .bc7].contains(format):
            return try WPETexMetalTranscoder.transcode(bytes, format: format, width: width, height: height,
                                                       mipmap: index)
        default:
            throw WPETexDecodeError.unsupportedFormat(code: info.textureFormatCode)
        }
    }

    /// The decoded RGBA image as an unmipped private texture.
    private static func upload(_ image: CGImage, device: MTLDevice) throws -> MTLTexture {
        try MTKTextureLoader(device: device).newTexture(cgImage: WPERasterImageAlpha.straightImage(image), options: [
            .SRGB: false,
            .generateMipmaps: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
        ])
    }

    /// Composites use the sampler WPE creates with them; images follow their TEXI flags.
    private func sampler(_ source: WPEParityFrameDrawPlan.TextureSource) -> WPEParitySamplerState {
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
        return .wpe(filter: info.noInterpolation ? .point : .linear, address: info.clampUVs ? .clamp : .wrap)
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

    /// A TEXS frame back in sheet pixels; the decoder divides it by the frame image's mip 0 size.
    private static func sprite(_ frame: WPETexAnimationFrame, info: WPETexInfo) -> WPEParityUniformSpriteFrame? {
        guard let sampling = frame.samplingDescriptor else { return nil }
        let mip = frame.mipmaps.first
        let size = SIMD2(Float(mip?.width ?? info.width), Float(mip?.height ?? info.height))
        let (rotation, translation) = (sampling.rotation, sampling.translation)
        return WPEParityUniformSpriteFrame(
            x: translation.x * size.x, y: translation.y * size.y,
            widthX: rotation.x * size.x, widthY: rotation.y * size.x,
            heightX: rotation.z * size.y, heightY: rotation.w * size.y,
            imageWidth: size.x, imageHeight: size.y
        )
    }

    // MARK: State and geometry

    private static func blend(_ description: WPEParityFrameDraw) -> WPEParityBlendState {
        switch description {
        case let .scene(draw):
            let mode: WPEParityBlendMode = switch draw.blend {
            case .normal: .normal
            case .translucent: .translucent
            case .additive: .additive
            }
            var modifiers: WPEParityBlendModifiers = draw.writeMask == .rgba ? .writeAlpha : []
            if draw.alphaMax {
                modifiers.insert(.alphaMax)
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
    }

    /// Mesh0 of a puppet layer with its texcoords scaled by `uvMax`.
    static func puppetGeometry(_ puppet: WPEParityScenePuppet, uvMax: SIMD2<Float>,
                               inputs: [WPEStageReflection.StageAttribute],
                               device: MTLDevice) -> (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)? {
        geometry(puppet.vertices.map {
            Vertex(position: $0.position, texcoord: $0.uv * uvMax,
                   blendIndices: SIMD4(truncatingIfNeeded: $0.skinBlendIndices), blendWeights: $0.skinBlendWeights)
        }, indices: puppet.indices, inputs: inputs, device: device)
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
