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

    let pipeline: WPEParityPipeline
    let depthStencil: WPEParityDepthStencilState
    let rasterizer: WPEParityRasterizerState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int
    /// The skinned puppet layer whose animator supplies the vertex stage's `g_Bones`.
    let puppetID: String?
    /// One table per frame variant: on odd frames each FBO swap pair binds its other side.
    let textures: [[String: TextureSource]]
    let samplers: [String: WPEParitySamplerState]
    let uniforms: WPEParityUniformDraw
    /// Set when camera parallax or camerashake moves the view, so the layer matrices are recomputed every frame.
    let placement: Placement?
    /// TEXS frames of each sprite-sheet slot, shown in turn for their durations.
    let sprites: [Int: [SpriteStep]]
    /// The binding description's constants per stage; the engine uniform set does not carry them.
    let constants: [WPEHLSLStage: [String: WPECBufferValue]]
    /// Per stage, declared constants that neither the binding nor the engine uniform set supplies, so they stay zero.
    let zeroConstants: [WPEHLSLStage: [String]]

    struct Placement {
        let layers: WPEParityLayerTransformSet
        let objectID: String
        let kind: WPEParityLayerDrawKind
        let compositeOwnerID: String?

        func draw(parallax: SIMD2<Float>, camera: WPEParityCamera? = nil) -> WPEParityUniformDraw {
            var layers = layers
            if let camera {
                layers.camera = camera
            }
            return layers.draw(objectID, kind: kind, compositeOwnerID: compositeOwnerID, parallax: parallax)
        }
    }

    /// `parallax` is `WPEParityUniformParallax.smoothed` for the frame; `camera` is the frame's shaken camera.
    func frameUniforms(parallax: SIMD2<Float>, camera: WPEParityCamera? = nil) -> WPEParityUniformDraw {
        guard let placed = placement?.draw(parallax: parallax, camera: camera) else { return uniforms }
        var uniforms = uniforms
        (uniforms.matrices, uniforms.effectPass) = (placed.matrices, placed.effectPass)
        return uniforms
    }

    /// `textureSlots` holds the last TEXS rotation and translation written to each slot, across draws and frames.
    /// `puppets` holds this frame's bone animator of each skinned puppet layer.
    func makeDraw(frame: WPEParityUniformFrame, camera: WPEParityCamera? = nil, variant: Int,
                  textures table: [WPEResourceID: MTLTexture], textureSlots: inout [String: WPECBufferValue],
                  puppets: [String: WPEParityPuppetAnimator]) throws -> WPEParityDraw {
        var draw = WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                                 vertexBuffer: vertexBuffer, primitiveType: .triangle, vertexCount: 4)
        draw.indexBuffer = indexBuffer
        draw.indexCount = indexCount
        var uniforms = frameUniforms(parallax: frame.parallax.smoothed, camera: camera)
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
        for stage in [WPEHLSLStage.vertex, .fragment] {
            draw.constants[stage] = engine.merging(constants[stage] ?? [:]) { $1 }
        }
        if let animator = puppetID.flatMap({ puppets[$0] }) {
            draw.constants[.vertex, default: [:]].merge(animator.values) { $1 }
        }
        draw.samplers = samplers
        for (name, source) in textures[variant] {
            switch source {
            case let .resource(id):
                guard let texture = table[id] else { throw WPEParityGraphExecutionError.missingTexture(id) }
                draw.textures[name] = texture
            case let .image(texture):
                draw.textures[name] = texture
            }
        }
        draw.textures.merge(spriteTextures) { $1 }
        return draw
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

    let device: MTLDevice
    let factory: WPEParityPipelineFactory
    let plan: WPEParityFramePlan
    private let frame: WPEParityFrame
    private let resources: [WPEResourceID: WPELogicalResource]
    /// Colour and depth target bound at each draw operation.
    private let targets: [Int: (color: WPEResourceID, depth: WPEResourceID?)]
    /// The scene camera and every layer's world matrix.
    let layers: WPEParityLayerTransformSet
    private var assetImages: [String: Image] = [:]
    /// Imported layer images, filled as draws are planned.
    private(set) var layerImages: [WPEResourceID: MTLTexture] = [:]
    private var layerImageAssets: [WPEResourceID: Image] = [:]
    /// Video .tex files the planned draws sample, filled as draws are planned.
    private(set) var videos: [WPEParityVideoTextures.Stream] = []

    init(device: MTLDevice, factory: WPEParityPipelineFactory, plan: WPEParityFramePlan) {
        self.device = device
        self.factory = factory
        self.plan = plan
        frame = plan.frames[0]
        resources = Dictionary(uniqueKeysWithValues: frame.resources.map { ($0.id, $0) })
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
        self.targets = targets
        // No user alignment crop and no camera path or camera object zoom yet.
        layers = WPEParityLayerTransformSet(document: plan.document,
                                            renderTargetSize: SIMD2(Float(plan.width), Float(plan.height)),
                                            alignment: .noCrop, cameraZoom: 1)
    }

    mutating func makePlan(_ index: Int,
                           artifact: WPEParityShaderArtifact) throws(WPEParityFrameSkip) -> WPEParityFrameDrawPlan {
        let shader = plan.programs[index]?.shader ?? "operation \(index)"
        guard let description = frame.draws[index], let target = targets[index], let color = resources[target.color],
              let colorFormat = Self.pixelFormats[color.format]
        else { throw .pipeline("operation \(index) has no draw or known target format") }
        let bindings = plan.bindings.compactMap { $0[index] }
        guard let binding = bindings.first, bindings.count == plan.frames.count else { throw .noMaterial }
        let depthFormat = target.depth.flatMap { resources[$0] }.flatMap { Self.pixelFormats[$0.format] } ?? .invalid
        let pipeline: WPEParityPipeline
        do {
            pipeline = try factory.makePipeline(artifact: artifact, blend: Self.blend(description),
                                                colorPixelFormat: colorFormat, depthStencilPixelFormat: depthFormat,
                                                sampleCount: color.sampleCount)
        } catch {
            throw .pipeline("\(shader): \(error)")
        }

        var textures = [[String: WPEParityFrameDrawPlan.TextureSource]](repeating: [:], count: bindings.count)
        var samplers: [String: WPEParitySamplerState] = [:]
        var uniformTextures = [WPEParityUniformTexture?](repeating: nil, count: WPEParityUniformTextures.slotCount)
        var sprites: [Int: [WPEParityFrameDrawPlan.SpriteStep]] = [:]
        let names = Set((artifact.vertex.reflection.resources + artifact.fragment.reflection.resources)
            .filter { $0.kind == .texture }.map(\.name))
        for name in names.sorted() {
            guard name.hasPrefix("g_Texture"), let slot = Int32(name.dropFirst("g_Texture".count)) else {
                throw .texture("\(shader) declares \(name)")
            }
            for (variant, binding) in bindings.enumerated() {
                guard case let .draw(operation) = plan.frames[variant].operations[index].kind else {
                    throw .pipeline("operation \(index) is not a draw in frame variant \(variant)")
                }
                textures[variant][name] = try textureSource(binding.textures[slot], slot: slot, shader: shader,
                                                            reads: operation.reads.map(\.resource))
            }
            guard let source = textures[0][name] else { continue }
            samplers[name + "SamplerState"] = sampler(source)
            if slot < uniformTextures.count {
                uniformTextures[Int(slot)] = uniformTexture(source)
                sprites[Int(slot)] = self.sprites(source)
            }
        }

        // Post-process draws have no layer and keep the effect-pass matrices.
        let placement: WPEParityFrameDrawPlan.Placement? = switch description {
        case let .scene(draw):
            WPEParityFrameDrawPlan.Placement(
                layers: layers, objectID: draw.objectID,
                kind: draw.fillsComposite ? .compositeFill(size: SIMD2(Float(color.width), Float(color.height)))
                    : draw.geometry == .fullscreenQuad ? .effectPass : .layer,
                compositeOwnerID: draw.compositeOwnerID
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
        let inputs = artifact.vertex.reflection.vertexInputs
        let geometry = if let puppet {
            // R12 B3: only the direct draw scales by uvMax; the bit4 draw samples a composite, whose uvMax is 1.
            Self.puppetGeometry(puppet, uvMax: uvMax, inputs: inputs, device: device)
        } else {
            Self.geometry(quad.vertices.map { Vertex(position: $0.position, texcoord: $0.texcoord) },
                          indices: WPEParityLayerQuad.indices, inputs: inputs, device: device)
        }
        guard let geometry else { throw .pipeline("vertex or index buffer allocation failed") }
        let puppetID = puppet?.skinned == true ? placement?.objectID : nil
        let placed = placement?.draw(parallax: .zero) ?? WPEParityUniformDraw(matrices: .effectPass)
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
        var zeroConstants: [WPEHLSLStage: [String]] = [:]
        for (stage, reflection) in [(WPEHLSLStage.vertex, artifact.vertex.reflection),
                                    (.fragment, artifact.fragment.reflection)] {
            let declared = Set(reflection.cbuffers.flatMap(\.variables).map(\.name))
            let supplied = engine.union(binding.constants[stage]?.keys.map(\.self) ?? [])
            zeroConstants[stage] = declared.subtracting(supplied).sorted()
        }

        return WPEParityFrameDrawPlan(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: binding.depthTest, depthWrite: binding.depthWrite),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: !binding.cullsBackFaces, slopeDepthBias: false,
                             multisample: false),
            vertexBuffer: geometry.vertices,
            indexBuffer: geometry.indices,
            indexCount: geometry.indexCount,
            puppetID: puppetID,
            textures: textures,
            samplers: samplers,
            uniforms: uniforms,
            placement: layers.camera.parallaxAmount == nil && layers.camera.shake == nil ? nil : placement,
            sprites: sprites.filter { !$0.value.isEmpty },
            constants: binding.constants,
            zeroConstants: zeroConstants
        )
    }

    /// Gives every imported resource without an image, such as a skipped draw's layer, a transparent texel.
    mutating func fillImportedImages() throws(WPEParityFrameSkip) {
        for resource in plan.frames.flatMap(\.resources) where resource.lifetime == .imported {
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
        }
    }

    private mutating func loadLayerImage(_ id: WPEResourceID, name: String?) throws(WPEParityFrameSkip) {
        guard layerImages[id] == nil else { return }
        guard let name else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1,
                                                                      mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw .texture("placeholder for \(id)")
            }
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 0, count: 4),
                            bytesPerRow: 4)
            layerImages[id] = texture
            return
        }
        let image = try assetImage(name)
        layerImages[id] = image.texture
        layerImageAssets[id] = image
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
