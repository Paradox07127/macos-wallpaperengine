#if !LITE_BUILD
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

extension WPEParityFrameDrawPlanner {
    // MARK: Textures

    mutating func textureSource(
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
        case let .morph(objectID)?:
            if let texture = morphTextures[objectID] {
                return .image(texture)
            }
            guard let mesh = plan.scene.puppetModels[objectID]?.meshes.first,
                  let morph = WPEParityPuppetAnimator.morphTexels(mesh) else {
                throw .texture("\(shader) slot \(slot) samples the morph texture of \(objectID), which has no targets")
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Snorm, width: morph.side,
                                                                      height: morph.side, mipmapped: false)
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw .texture("morph texture of \(objectID)")
            }
            texture.replace(region: MTLRegionMake2D(0, 0, morph.side, morph.side), mipmapLevel: 0,
                            withBytes: morph.texels, bytesPerRow: morph.side * 4 * MemoryLayout<Int16>.size)
            morphTextures[objectID] = texture
            return .image(texture)
        }
    }

    mutating func loadLayerImage(_ id: WPEResourceID, name: String?) throws(WPEParityFrameSkip) {
        guard layerImages[id] == nil else { return }
        guard let name else {
            layerImages[id] = try transparentTexture()
            return
        }
        let image = try assetImage(name)
        layerImages[id] = image.texture
        layerImageAssets[id] = image
    }

    mutating func transparentTexture() throws(WPEParityFrameSkip) -> MTLTexture {
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

    mutating func assetImage(_ name: String) throws(WPEParityFrameSkip) -> Image {
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
                image = try WPEParityTextureLoader.load(span: span, device: device, userProperties: userProperties,
                                                        path: path, compression: textureCompression)
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
    func sampler(_ source: WPEParityFrameDrawPlan.TextureSource) throws(WPEParityFrameSkip) -> WPEParitySamplerState {
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

    func uniformTexture(_ source: WPEParityFrameDrawPlan.TextureSource) -> WPEParityUniformTexture? {
        var texture: MTLTexture
        let info: WPETexInfo?
        switch source {
        case let .resource(id):
            if let image = layerImages[id] {
                (texture, info) = (image, layerImageAssets[id]?.info)
            } else {
                guard let resource = resources[id] else { return nil }
                return Self.renderTargetUniformTexture(resource, logicalSizes: frame.logicalSizes)
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

    /// A target allocated below its logical size still reports the logical size, which shaders' texel maths assume.
    static func renderTargetUniformTexture(_ resource: WPELogicalResource,
                                           logicalSizes: [WPEResourceID: SIMD2<Int>]) -> WPEParityUniformTexture {
        let size = logicalSizes[resource.id] ?? SIMD2(resource.width, resource.height)
        let (width, height) = (UInt32(size.x), UInt32(size.y))
        return WPEParityUniformTexture(textureWidth: width, textureHeight: height, imageWidth: width,
                                       imageHeight: height, mipMapInfo: Int32(resource.mipCount))
    }

    func sprites(_ source: WPEParityFrameDrawPlan.TextureSource) -> [WPEParityFrameDrawPlan.SpriteStep] {
        switch source {
        case let .resource(id): layerImageAssets[id]?.sprites ?? []
        case let .image(texture): assetImages.values.first { $0.texture === texture }?.sprites ?? []
        }
    }
}
#endif
