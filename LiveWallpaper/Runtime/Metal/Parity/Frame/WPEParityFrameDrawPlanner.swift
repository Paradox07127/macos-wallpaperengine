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

    let pipeline: WPEParityPipeline
    let depthStencil: WPEParityDepthStencilState
    let rasterizer: WPEParityRasterizerState
    let vertexBuffer: MTLBuffer
    /// One table per frame variant: on odd frames each FBO swap pair binds its other side.
    let textures: [[String: TextureSource]]
    let samplers: [String: WPEParitySamplerState]
    let uniforms: WPEParityUniformDraw
    /// The binding description's constants; the engine uniform set does not carry them.
    let constants: [String: WPECBufferValue]
    /// Constants a stage declares that neither the binding nor the engine uniform set supplies, so they stay zero.
    let zeroConstants: [String]

    func makeDraw(frame: WPEParityUniformFrame, variant: Int,
                  textures table: [WPEResourceID: MTLTexture]) throws -> WPEParityDraw {
        var draw = WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                                 vertexBuffer: vertexBuffer, primitiveType: .triangleStrip, vertexCount: 4)
        draw.constants = WPEParityUniformSet.values(frame: frame, draw: uniforms).merging(constants) { $1 }
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
        return draw
    }
}

/// Resolves frame draws against their compiled programs and the package's binding descriptions: pipeline,
/// geometry, textures, samplers and matrices.
struct WPEParityFrameDrawPlanner {
    static let pixelFormats: [String: MTLPixelFormat] = [
        "rgba8unorm": .rgba8Unorm, "rgba16float": .rgba16Float, "r8unorm": .r8Unorm, "rg8unorm": .rg8Unorm,
        "r16float": .r16Float, "rg16float": .rg16Float, "depth32float": .depth32Float,
    ]

    private struct Image {
        let texture: MTLTexture
        let info: WPETexInfo?
    }

    let device: MTLDevice
    let factory: WPEParityPipelineFactory
    let plan: WPEParityFramePlan
    private let frame: WPEParityFrame
    private let resources: [WPEResourceID: WPELogicalResource]
    /// Colour and depth target bound at each draw operation.
    private let targets: [Int: (color: WPEResourceID, depth: WPEResourceID?)]
    private let objects: [String: WPESceneImageObject]
    private let sizes: [String: SIMD2<Float>]
    let view: simd_float4x4
    let projection: simd_float4x4
    let eyePosition: SIMD3<Float>
    private var assetImages: [String: Image] = [:]
    /// Imported layer images, filled as draws are planned.
    private(set) var layerImages: [WPEResourceID: MTLTexture] = [:]
    private var layerImageInfo: [WPEResourceID: WPETexInfo] = [:]

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
        objects = Dictionary(plan.document.imageObjects.map { ($0.id, $0) }) { first, _ in first }
        sizes = Dictionary(plan.scene.scene.objects.map { ($0.id, SIMD2(Float($0.width), Float($0.height))) }) { $1 }
        // 2D camera: the ortho canvas, y up, centred on the screen.
        let ortho = plan.document.general.orthogonalProjection
        let canvas = SIMD2(Float(ortho.width), Float(ortho.height))
        var view = matrix_identity_float4x4
        view.columns.3 = SIMD4(-canvas.x / 2, -canvas.y / 2, 0, 1)
        self.view = view
        projection = WPEParityUniformMatrices.ortho(halfWidth: canvas.x / 2, halfHeight: canvas.y / 2, depth: 1000)
        eyePosition = WPEParityUniformParallax.eyePosition2D(eye: .zero, ortho: canvas)
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
            }
        }

        let (objectID, fullscreen) = switch description {
        case let .scene(draw): (Optional(draw.objectID), draw.geometry == .fullscreenQuad)
        case .post: (String?.none, true)
        }
        let placement = placement(objectID: objectID, fullscreen: fullscreen)
        guard let vertexBuffer = Self.quad(half: placement.half, inputs: artifact.vertex.reflection.vertexInputs,
                                           device: device)
        else { throw .pipeline("vertex buffer allocation failed") }
        let uniforms = WPEParityUniformDraw(matrices: placement.matrices, effectPass: placement.effectPass,
                                            textures: uniformTextures)

        let declared = Set((artifact.vertex.reflection.cbuffers + artifact.fragment.reflection.cbuffers)
            .flatMap(\.variables).map(\.name))
        let probe = WPEParityUniformFrame(clock: WPEParityClock(), daytime: 0,
                                          screen: WPEParityUniformScreen(clientWidth: 1, clientHeight: 1),
                                          pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
                                          eyePosition: eyePosition, view: view)
        let supplied = Set(WPEParityUniformSet.values(frame: probe, draw: uniforms).keys).union(binding.constants.keys)

        return WPEParityFrameDrawPlan(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: binding.depthTest, depthWrite: binding.depthWrite),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: !binding.cullsBackFaces, slopeDepthBias: false,
                             multisample: false),
            vertexBuffer: vertexBuffer,
            textures: textures,
            samplers: samplers,
            uniforms: uniforms,
            constants: binding.constants,
            zeroConstants: declared.subtracting(supplied).sorted()
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
        layerImageInfo[id] = image.info
    }

    private mutating func assetImage(_ name: String) throws(WPEParityFrameSkip) -> Image {
        if let cached = assetImages[name] {
            return cached
        }
        guard let data = plan.scene.assets.data("materials/\(name).tex") else {
            throw .texture("materials/\(name).tex not found")
        }
        let span = WPEMappedByteSpan(data: data)
        let decoder = WPETexDecoder()
        do {
            let info = try decoder.probe(span: span).get()
            let cgImage = try WPERasterImageAlpha.straightImage(decoder.decode(span: span).get())
            let texture = try MTKTextureLoader(device: device).newTexture(cgImage: cgImage, options: [
                .SRGB: false,
                .generateMipmaps: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue),
            ])
            let image = Image(texture: texture, info: info)
            assetImages[name] = image
            return image
        } catch WPETexDecodeError.unsupportedAnimation {
            throw .videoTexture("materials/\(name).tex")
        } catch {
            throw .texture("materials/\(name).tex: \(error)")
        }
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
            info = layerImageInfo[id]
        case let .image(texture):
            info = assetImages.values.first { $0.texture === texture }?.info
        }
        guard let info else { return .wpe(filter: .linear, address: .clamp) }
        return .wpe(filter: info.noInterpolation ? .point : .linear, address: info.clampUVs ? .clamp : .wrap)
    }

    private func uniformTexture(_ source: WPEParityFrameDrawPlan.TextureSource) -> WPEParityUniformTexture? {
        let texture: MTLTexture
        let info: WPETexInfo?
        switch source {
        case let .resource(id):
            if let image = layerImages[id] {
                (texture, info) = (image, layerImageInfo[id])
            } else {
                guard let resource = resources[id] else { return nil }
                let (width, height) = (UInt32(resource.width), UInt32(resource.height))
                return WPEParityUniformTexture(textureWidth: width, textureHeight: height, imageWidth: width,
                                               imageHeight: height, mipMapInfo: Int32(resource.mipCount))
            }
        case let .image(image):
            (texture, info) = (image, assetImages.values.first { $0.texture === image }?.info)
        }
        let imageWidth = info.map(\.imageWidth).flatMap { $0 > 0 ? $0 : nil } ?? texture.width
        let imageHeight = info.map(\.imageHeight).flatMap { $0 > 0 ? $0 : nil } ?? texture.height
        return WPEParityUniformTexture(textureWidth: UInt32(texture.width), textureHeight: UInt32(texture.height),
                                       imageWidth: UInt32(imageWidth), imageHeight: UInt32(imageHeight),
                                       mipMapInfo: Int32(texture.mipmapLevelCount))
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

    /// The one place matrices and quad extent are derived: a layer mesh sits at its object's transform in the
    /// ortho canvas, a fullscreen quad uses the effect-pass matrices.
    private func placement(objectID: String?, fullscreen: Bool)
        -> (matrices: WPEParityUniformMatrices, effectPass: WPEParityUniformEffectPass?, half: SIMD2<Float>) {
        let object = objectID.flatMap { objects[$0] }
        let size = objectID.flatMap { sizes[$0] } ?? .zero
        let layerModel = object.map(Self.model) ?? matrix_identity_float4x4
        let layer = WPEParityUniformMatrices(model: layerModel, view: view, projection: projection)
        let effectPass = object.map { _ in
            WPEParityUniformEffectPass(layerModel: layerModel, layerModelViewProjection: layer.modelViewProjection,
                                       size: size, isLastPass: !fullscreen)
        }
        return (fullscreen ? .effectPass : layer, effectPass, fullscreen ? SIMD2<Float>(1, 1) : size / 2)
    }

    /// Translation, then rotation Z·Y·X in radians, then scale, all in ortho canvas units.
    private static func model(_ object: WPESceneImageObject) -> simd_float4x4 {
        let angles = SIMD3<Float>(object.angles)
        func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> simd_float4x4 {
            simd_float4x4(simd_quatf(angle: angle, axis: axis))
        }
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(SIMD3<Float>(object.origin), 1)
        let scale = simd_float4x4(diagonal: SIMD4(SIMD3<Float>(object.scale), 1))
        return translation * rotation(angles.z, [0, 0, 1]) * rotation(angles.y, [0, 1, 0])
            * rotation(angles.x, [1, 0, 0]) * scale
    }

    /// Triangle strip TL, BL, TR, BR packed as the vertex reflection lists its inputs; texcoord v = 0 is the top row.
    private static func quad(half: SIMD2<Float>, inputs: [WPEStageReflection.StageAttribute],
                             device: MTLDevice) -> MTLBuffer? {
        let corners: [(position: SIMD2<Float>, uv: SIMD2<Float>)] = [
            ([-half.x, half.y], [0, 0]), ([-half.x, -half.y], [0, 1]),
            ([half.x, half.y], [1, 0]), ([half.x, -half.y], [1, 1]),
        ]
        var floats: [Float] = []
        for corner in corners {
            for input in inputs.sorted(by: { $0.index < $1.index }) {
                let name = input.name.lowercased()
                let value: [Float] = if name.hasPrefix("position") {
                    [corner.position.x, corner.position.y, 0, 1]
                } else if name == "texcoord0" {
                    [corner.uv.x, corner.uv.y, 0, 0]
                } else if name.hasPrefix("color") {
                    [1, 1, 1, 1]
                } else {
                    [0, 0, 0, 0]
                }
                floats += value.prefix(input.columns)
            }
        }
        // An input-less vertex stage still gets a buffer at the MSC vertex bind point.
        let length = max(16, floats.count * MemoryLayout<Float>.stride)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        buffer.contents().copyMemory(from: floats, byteCount: floats.count * MemoryLayout<Float>.stride)
        return buffer
    }
}
#endif
