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
    let textures: [String: TextureSource]
    let samplers: [String: WPEParitySamplerState]
    let uniforms: WPEParityUniformDraw
    /// Object and post-process values the engine uniform set does not carry.
    let constants: [String: WPECBufferValue]

    func makeDraw(frame: WPEParityUniformFrame, textures table: [WPEResourceID: MTLTexture]) throws -> WPEParityDraw {
        var draw = WPEParityDraw(pipeline: pipeline, depthStencil: depthStencil, rasterizer: rasterizer,
                                 vertexBuffer: vertexBuffer, primitiveType: .triangleStrip, vertexCount: 4)
        draw.constants = WPEParityUniformSet.values(frame: frame, draw: uniforms).merging(constants) { $1 }
        draw.samplers = samplers
        for (name, source) in textures {
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

/// Resolves frame draws against their compiled programs: pipeline, geometry, textures, samplers and matrices.
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
    /// Imported layer images, filled as albedo draws are planned.
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
        guard let description = frame.draws[index], let material = plan.materials[index],
              case let .draw(operation) = frame.operations[index].kind,
              let target = targets[index], let color = resources[target.color],
              let colorFormat = Self.pixelFormats[color.format]
        else { throw .pipeline("operation \(index) has no draw, material or known target format") }
        let depthFormat = target.depth.flatMap { resources[$0] }.flatMap { Self.pixelFormats[$0.format] } ?? .invalid
        let pipeline: WPEParityPipeline
        do {
            pipeline = try factory.makePipeline(artifact: artifact, blend: Self.blend(description),
                                                colorPixelFormat: colorFormat, depthStencilPixelFormat: depthFormat,
                                                sampleCount: color.sampleCount)
        } catch {
            throw .pipeline("\(material.shader): \(error)")
        }

        var reads: [WPEResourceID] = []
        var objectID: String?
        var fullscreen = true
        switch description {
        case let .scene(draw):
            (reads, objectID, fullscreen) = (draw.reads, draw.objectID, draw.geometry == .fullscreenQuad)
            if draw.effectID == nil, let image = reads.first, resources[image]?.lifetime == .imported {
                try loadLayerImage(image, name: material.textures[0])
            }
        case let .post(draw):
            reads = draw.reads
        }

        var textures: [String: WPEParityFrameDrawPlan.TextureSource] = [:]
        var samplers: [String: WPEParitySamplerState] = [:]
        var uniformTextures = [WPEParityUniformTexture?](repeating: nil, count: WPEParityUniformTextures.slotCount)
        let names = Set((artifact.vertex.reflection.resources + artifact.fragment.reflection.resources)
            .filter { $0.kind == .texture }.map(\.name))
        for name in names.sorted() {
            guard name.hasPrefix("g_Texture"), let slot = Int(name.dropFirst("g_Texture".count)) else {
                throw .texture("\(material.shader) declares \(name)")
            }
            let source = try textureSource(slot, description: description, material: material, reads: reads)
            textures[name] = source
            samplers[name + "SamplerState"] = sampler(source)
            if slot < uniformTextures.count {
                uniformTextures[slot] = uniformTexture(source)
            }
        }

        let object = objectID.flatMap { objects[$0] }
        let size = objectID.flatMap { sizes[$0] } ?? .zero
        let layerModel = object.map(Self.model) ?? matrix_identity_float4x4
        let layer = WPEParityUniformMatrices(model: layerModel, view: view, projection: projection)
        let effectPass = object.map { _ in
            WPEParityUniformEffectPass(layerModel: layerModel, layerModelViewProjection: layer.modelViewProjection,
                                       size: size, isLastPass: !fullscreen)
        }
        let half = fullscreen ? SIMD2<Float>(1, 1) : size / 2
        guard let vertexBuffer = Self.quad(half: half, inputs: artifact.vertex.reflection.vertexInputs, device: device)
        else { throw .pipeline("vertex buffer allocation failed") }

        return WPEParityFrameDrawPlan(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: operation.depthTest, depthWrite: operation.depthWrite),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: vertexBuffer,
            textures: textures,
            samplers: samplers,
            uniforms: WPEParityUniformDraw(matrices: fullscreen ? .effectPass : layer, effectPass: effectPass,
                                           textures: uniformTextures),
            constants: Self.constants(description, object: object)
        )
    }

    // MARK: Textures

    private mutating func textureSource(
        _ slot: Int, description: WPEParityFrameDraw, material: WPEParityProgramMaterial, reads: [WPEResourceID]
    ) throws(WPEParityFrameSkip) -> WPEParityFrameDrawPlan.TextureSource {
        let fullFrame = WPEParitySceneResource.fullFrameBuffer
        guard case let .scene(draw) = description else {
            guard slot < reads.count else { throw .texture("\(material.shader) samples slot \(slot) of \(reads)") }
            return .resource(reads[slot])
        }
        let name = material.textures[Int32(slot)] ?? defaultTexture(slot, shader: material.shader)
        // Slot 0 of an albedo-style draw is its first read: the layer image, the snapshot or the composite.
        if let first = reads.first, name == "previous" || (slot == 0 && (draw.effectID == nil || name == nil)) {
            return .resource(first)
        }
        guard let name, !name.isEmpty else { throw .texture("\(material.shader) slot \(slot) is unbound") }
        if name == fullFrame.rawValue, reads.contains(fullFrame) {
            return .resource(fullFrame)
        }
        if plan.fboNames.contains(name) {
            var binds: [String] = []
            for bound in material.textures.sorted(by: { $0.key < $1.key }).map(\.value)
                where plan.fboNames.contains(bound) && !binds.contains(bound) {
                binds.append(bound)
            }
            guard let position = binds.firstIndex(of: name), position + 1 < reads.count else {
                throw .texture("\(material.shader) FBO \(name) is not among the reads \(reads)")
            }
            return .resource(reads[position + 1])
        }
        return try .image(assetImage(name).texture)
    }

    private func defaultTexture(_ slot: Int, shader: String) -> String? {
        func source(_ suffix: String) -> String {
            plan.scene.assets.shaderSource(named: "shaders/\(shader).\(suffix)")
                .flatMap { String(bytes: $0, encoding: .isoLatin1) } ?? ""
        }
        let annotations = WPEShaderAnnotationCombos(vertexSource: source("vert"), fragmentSource: source("frag"))
        return annotations.samplers[Int32(slot)].map(\.defaultTexture)
    }

    private mutating func loadLayerImage(_ id: WPEResourceID, name: String?) throws(WPEParityFrameSkip) {
        guard layerImages[id] == nil else { return }
        guard let name else {
            // A material without textures (solid layers) still reads its layer image in the frame.
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

    private static func constants(_ description: WPEParityFrameDraw,
                                  object: WPESceneImageObject?) -> [String: WPECBufferValue] {
        if case let .post(draw) = description {
            return draw.bloomParameters.mapValues { .vector([$0.x, $0.y, $0.z, $0.w]) }
        }
        guard let object else { return [:] }
        let color = SIMD3<Float>(object.color)
        let alpha = Float(object.alpha)
        return [
            "g_Color4": .vector([color.x, color.y, color.z, alpha]),
            "g_Color": .vector([color.x, color.y, color.z]),
            "g_Alpha": .float(alpha),
            "g_UserAlpha": .float(alpha),
            "g_Brightness": .float(Float(object.brightness)),
        ]
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
