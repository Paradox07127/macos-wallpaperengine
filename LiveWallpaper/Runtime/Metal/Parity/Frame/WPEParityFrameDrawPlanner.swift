#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import simd

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
    static let videoFlag: UInt32 = 0x20

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
    var frame: WPEParityFrame
    var resources: [WPEResourceID: WPELogicalResource]
    /// Per frame variant of `layout`, its resources by id; a repeated id keeps its first declaration.
    private var variantResources: [[WPEResourceID: WPELogicalResource]]
    /// The plan's scene objects by id; a repeated id keeps the first object.
    private let objects: [String: WPEParitySceneObject]
    /// Colour and depth target bound at each draw operation; colour is nil for the depth-only shadow atlas.
    private var targets: [Int: (color: WPEResourceID?, depth: WPEResourceID?)]
    /// The scene camera and every layer's world matrix.
    private(set) var layers: WPEParityLayerTransformSet
    var assetImages: [String: Image] = [:]
    /// The same committed typed snapshot the Driver supplies, also used for assets first loaded by a later layout.
    var userProperties: WPESceneJSONValue
    /// nil uploads every imported texture in its authored format.
    let textureCompression: WPEParityTextureCompression?
    /// Imported layer images, filled as draws are planned.
    var layerImages: [WPEResourceID: MTLTexture] = [:]
    var layerImageAssets: [WPEResourceID: Image] = [:]
    var transparent: MTLTexture?
    /// Each morphing puppet layer's R16G16B16A16_SNORM target texture, built once.
    var morphTextures: [String: MTLTexture] = [:]
    /// Video .tex files the planned draws sample, filled as draws are planned.
    var videos: [WPEParityVideoTextures.Stream] = []

    /// Returns the planned streams and keeps only their textures, so the replan guard can still count them.
    mutating func takeVideoStreams() -> [WPEParityVideoTextures.Stream] {
        let streams = videos
        for index in videos.indices {
            videos[index].bytes = Data()
        }
        return streams
    }

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
         preservingVideoImages: [String: Image] = [:], userProperties: WPESceneJSONValue = .object([:]),
         textureCompression: WPEParityTextureCompression? = .resolve()) {
        self.device = device
        self.factory = factory
        self.plan = plan
        assetImages = preservingVideoImages
        self.userProperties = userProperties
        self.textureCompression = textureCompression
        layout = plan.layout
        frame = plan.frames[0]
        resources = Self.resources(frame)
        variantResources = Self.variantResources(layout)
        objects = Dictionary(plan.scene.scene.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        targets = Self.targets(frame)
        // No camera path or camera object zoom yet.
        let renderTargetSize = SIMD2(Float(plan.width), Float(plan.height))
        layers = WPEParityLayerTransformSet(document: plan.document, renderTargetSize: renderTargetSize,
                                            alignment: plan.alignment, cameraZoom: 1,
                                            textSizes: plan.scene.textSizes, imageSizes: plan.scene.imageSizes,
                                            puppetModels: plan.scene.puppetModels)
        layers.camera = WPEParityCamera(document: plan.document, renderTargetSize: renderTargetSize,
                                        alignment: plan.alignment,
                                        orthoWithoutPaths: plan.scene.engineFlags.orthographicProjection
                                            && plan.scene.cameraPaths.paths.isEmpty)
        lights = WPEParityUniformLights(document: plan.document, transforms: layers)
        textAtlases = WPEParityTextAtlasTextures(atlases: plan.scene.textAtlases)
        textAtlases.upload(device: device)
        for object in plan.scene.scene.objects {
            if case let .text(text) = object.kind {
                texts[object.id] = text
            }
        }
    }

    /// The TEXS frames of `objectID`'s own image; empty when it has no sprite sheet or no draw loaded it yet.
    func layerSprites(_ objectID: String) -> [WPEParityFrameDrawPlan.SpriteStep] {
        layerImageAssets[WPEParitySceneResource.layerImage(objectID)]?.sprites ?? []
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
                case .textAtlas, .morph: false
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
        variantResources = Self.variantResources(layout)
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
    /// `targets` and `resources` are `targets(frame)` and `resources(frame)`.
    mutating func prewarmPipeline(_ frame: WPEParityFrame, _ index: Int,
                                  targets: [Int: (color: WPEResourceID?, depth: WPEResourceID?)],
                                  resources: [WPEResourceID: WPELogicalResource], program: WPEParityProgram,
                                  artifact: WPEParityShaderArtifact) throws(WPEParityFrameSkip) {
        guard let description = frame.draws[index], let target = targets[index] else {
            throw .pipeline("Missing draw or target during pipeline preparation")
        }
        _ = try pipeline(description, target: target, resources: resources, program: program,
                         artifact: artifact)
    }

    private mutating func pipeline(_ description: WPEParityFrameDraw,
                                   target: (color: WPEResourceID?, depth: WPEResourceID?),
                                   resources: [WPEResourceID: WPELogicalResource], program: WPEParityProgram?,
                                   artifact: WPEParityShaderArtifact) throws(WPEParityFrameSkip) -> WPEParityPipeline {
        let shader = program?.shader ?? "operation"
        guard let attachment = (target.color ?? target.depth).flatMap({ resources[$0] }),
              let attachmentFormat = Self.pixelFormats[attachment.format] else {
            throw .pipeline("\(shader): unknown target format")
        }
        let colorFormat = target.color == nil ? MTLPixelFormat.invalid : attachmentFormat
        let depthFormat = target.depth.flatMap { resources[$0] }.flatMap { Self.pixelFormats[$0.format] } ?? .invalid
        let blend = Self.blend(description)
        let key = program.map {
            PipelineKey(program: $0.hlsl, blend: blend, color: colorFormat, depth: depthFormat,
                        samples: attachment.sampleCount)
        }
        if let key, let cached = pipelines[key] {
            return cached
        }
        do {
            let pipeline = try factory.makePipeline(artifact: artifact, blend: blend, colorPixelFormat: colorFormat,
                                                    depthStencilPixelFormat: depthFormat,
                                                    sampleCount: attachment.sampleCount)
            pipelineCreations += 1
            if let key {
                pipelines[key] = pipeline
            }
            return pipeline
        } catch {
            throw .pipeline("\(shader): \(error)")
        }
    }

    static func resources(_ frame: WPEParityFrame) -> [WPEResourceID: WPELogicalResource] {
        Dictionary(uniqueKeysWithValues: frame.resources.map { ($0.id, $0) })
    }

    private static func variantResources(_ layout: WPEParityFrameLayout) -> [[WPEResourceID: WPELogicalResource]] {
        layout.frames.map { Dictionary($0.resources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }

    static func targets(_ frame: WPEParityFrame) -> [Int: (color: WPEResourceID?, depth: WPEResourceID?)] {
        var targets: [Int: (color: WPEResourceID?, depth: WPEResourceID?)] = [:]
        var bound: (color: WPEResourceID?, depth: WPEResourceID?)?
        for (index, operation) in frame.operations.enumerated() {
            switch operation.kind {
            case let .setTargets(color, depth):
                bound = color.first.map { (color: $0.resource, depth: depth?.resource) }
                    ?? depth.map { (color: nil, depth: $0.resource) }
            case .draw:
                targets[index] = bound
            default:
                break
            }
        }
        return targets
    }

    /// `state` is the live state whose slots the renderer reads every frame.
    mutating func makePlan(_ index: Int, artifact: WPEParityShaderArtifact,
                           state: WPEParitySceneState) throws(WPEParityFrameSkip) -> WPEParityFrameDrawPlan {
        let shader = layout.programs[index]?.shader ?? "operation \(index)"
        guard let description = frame.draws[index], let target = targets[index],
              let attachment = (target.color ?? target.depth).flatMap({ resources[$0] }),
              Self.pixelFormats[attachment.format] != nil
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
        var mediaKinds = binding.userTextureSlots.reduce(into: [Int: WPEMediaSystemTexture]()) { slots, entry in
            if entry.key >= 0, let kind = WPEMediaSystemTexture(bindingName: entry.value.name) {
                slots[Int(entry.key)] = kind
            }
        }
        // Any other provider names a plain property whose user image replaces slots 0..9 (140154480.c:142-232,
        // 1401556e0.c:82-109); an unresolved declaration merge keeps the authored texture.
        let sceneTextures = binding.userTextures.diagnostics.isEmpty
        var userImageKeys = binding.userTextureSlots.reduce(into: [Int: (key: String, pads: Bool)]()) { slots, entry in
            let type = entry.value.type
            let plain = sceneTextures && Int(entry.key) < WPEParityUniformTextures.slotCount && type != "system"
                && WPEMediaSystemTexture(bindingName: entry.value.name) == nil
            if entry.key >= 0, type == "usershortcut" || plain {
                slots[Int(entry.key)] = (entry.value.name, type == "usershortcut")
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
            objects[draw.objectID]
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
        let samplerNames = Set(reflections.flatMap(\.1.resources).filter { $0.kind == .sampler }.map(\.name))
        mediaKinds = mediaKinds.filter { names.contains("g_Texture\($0.key)") }
        userImageKeys = userImageKeys.filter { names.contains("g_Texture\($0.key)") }
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
            // The rewriter declares this only for the shadow atlas, whose texFlags 0x08000000 pick it (140190c80.c:1533-1541).
            if samplerNames.contains(name + "SamplerComparisonState") {
                samplers[name + "SamplerComparisonState"] = .wpeComparison()
            } else {
                samplers[name + "SamplerState"] = try sampler(source)
            }
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
                        guard let target = variantResources[variant][id] else {
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
                    : draw.fillsComposite && draw.source == .composeLayer ? .composeCapture
                    : draw.fillsComposite ? .compositeFill(size: draw.logicalCompositeSize.map {
                        SIMD2(Float($0.x), Float($0.y))
                    } ?? SIMD2(Float(attachment.width), Float(attachment.height)))
                    : draw.multipliesDestination && draw.source == .flatTexture && draw.geometry == .fullscreenQuad ? .clipMaskMerge
                    : draw.fullscreenLayer ? .fullscreenLayer
                    : draw.geometry != .fullscreenQuad ? .layer
                    : draw.layerMatrices ? .lastEffectPass : .effectPass,
                compositeOwnerID: draw.compositeOwnerID,
                text: draw.source == .textClearAlpha ? nil : text.map { textPlacement($0, draw) }
            )
        case .post: nil
        }
        // The composite fill samples only the image part of a padded albedo texture.
        let uvMax = uniformTextures[0].map {
            SIMD2(Float($0.imageWidth) / Float($0.textureWidth), Float($0.imageHeight) / Float($0.textureHeight))
        } ?? .one
        let quad = placement.map { placed in
            switch placed.kind {
            case .compositeFill, .composeCapture:
                layers.quad(placed.objectID, kind: placed.kind, uvMax: uvMax)
            // 140209360.c:53-59: a plain layer's card mesh samples image/texture; sprite sheets keep 1.
            case .layer where uniformTextures[0]?.spriteFrame == nil:
                layers.quad(placed.objectID, kind: placed.kind, uvMax: uvMax)
            default:
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
            objects[draw.objectID]?.puppet
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
        } else if let modelMesh {
            guard let buffers = try Self.modelGeometry(modelMesh, inputs: artifact.vertex.reflection.vertexInputs,
                                                       device: device)
            else { throw .pipeline("vertex or index buffer allocation failed") }
            geometry = .mesh(vertices: buffers.vertices, indices: buffers.indices, indexCount: buffers.indexCount,
                             indexType: buffers.indexType)
        } else {
            let inputs = artifact.vertex.reflection.vertexInputs
            let buffers = if case let .scene(draw) = description, draw.geometry == .modelMesh {
                throw .pipeline("\(shader): \(draw.pass) has no model mesh")
            } else if let puppet {
                // Only the direct draw scales by uvMax; the bit4 draw samples a composite, whose uvMax is 1.
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
        // 0x1401556e0.c:149-213: the pass's usertexturereference, else the authored image (a sprite sheet's frame)
        // sets the slot aspect a user or system image is fitted to.
        func slotAspect(_ slot: Int) -> Float? {
            let authored = uniformTextures.indices.contains(slot) ? uniformTextures[slot] : nil
            let size = binding.userTextures.reference.map { SIMD2(Float($0.x), Float($0.y)) } ?? authored.map { texture in
                texture.spriteFrame.map { SIMD2(hypot($0.widthX, $0.widthY), hypot($0.heightX, $0.heightY)) }
                    ?? SIMD2(Float(texture.imageWidth), Float(texture.imageHeight))
            }
            let keeps = binding.userTextures.keepAspectSlots.contains(Int32(slot))
            return size.flatMap { $0.x > 0 && $0.y > 0 && !keeps ? $0.x / $0.y : nil }
        }
        let userImageSlots = userImageKeys.reduce(into: [Int: WPEUserImageSlot]()) { slots, entry in
            slots[entry.key] = WPEUserImageSlot(key: entry.value.key, aspect: slotAspect(entry.key), pads: entry.value.pads)
        }
        let mediaSlots = mediaKinds.reduce(into: [Int: (kind: WPEMediaSystemTexture, aspect: Float?)]()) { slots, entry in
            slots[entry.key] = (entry.value, slotAspect(entry.key))
        }
        var mediaGeometry: WPEParityFrameDrawPlan.Geometry?
        if mediaSlots[0] != nil || userImageSlots[0] != nil, uvMax != .one {
            let inputs = artifact.vertex.reflection.vertexInputs
            let paddedQuad = placement.map {
                switch $0.kind {
                case .compositeFill, .layer: true
                default: false
                }
            } ?? false
            let buffers: (vertices: MTLBuffer, indices: MTLBuffer, indexCount: Int)?
            if let puppet {
                buffers = try Self.puppetGeometry(puppet, segment: puppetSegment, uvMax: .one,
                                                  inputs: inputs, device: device)
            } else if let placement, paddedQuad {
                let full = layers.quad(placement.objectID, kind: placement.kind, uvMax: .one)
                buffers = Self.geometry(full.vertices.map { Vertex(position: $0.position, texcoord: $0.texcoord) },
                                        indices: WPEParityLayerQuad.indices, inputs: inputs, device: device)
            } else {
                buffers = nil
            }
            if let buffers {
                mediaGeometry = .mesh(vertices: buffers.vertices, indices: buffers.indices, indexCount: buffers.indexCount)
            } else if puppet != nil || paddedQuad {
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
        let castsShadow = if case let .scene(draw) = description {
            draw.target == WPEParitySceneResource.shadowAtlas
        } else {
            false
        }

        return WPEParityFrameDrawPlan(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: binding.depthTest, depthWrite: binding.depthWrite),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: !binding.cullsBackFaces, slopeDepthBias: castsShadow,
                             multisample: false),
            geometry: geometry,
            puppetID: puppetID,
            textures: textures,
            mediaSlots: mediaSlots,
            userImageSlots: userImageSlots,
            mediaGeometry: mediaGeometry,
            mediaFormatFailures: mediaFormatFailures,
            samplers: samplers,
            uniforms: uniforms,
            placement: placement,
            cameraMoves: layers.camera.parallaxAmount != nil || layers.camera.shake != nil,
            layerColor: binding.layerColorObjectID.flatMap { id in
                state.index(of: id).map { (object: $0, loaded: plan.state.index(of: id).map(plan.state.layerColor(at:))) }
            },
            materialPass: binding.materialPass.flatMap(state.passIndex(of:)),
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

    /// Gives every imported colour resource without an image, such as a skipped draw's layer, a transparent texel.
    /// A texel would replace the depth-only shadow atlas, so depth resources get none.
    mutating func fillImportedImages() throws(WPEParityFrameSkip) {
        for resource in layout.frames.flatMap(\.resources)
            where resource.lifetime == .imported && resource.format != WPEParitySceneResource.depthFormat {
            try loadLayerImage(resource.id, name: nil)
        }
    }
}
#endif
