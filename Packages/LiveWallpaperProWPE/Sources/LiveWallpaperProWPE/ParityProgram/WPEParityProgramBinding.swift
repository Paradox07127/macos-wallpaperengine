/// What one draw binds besides its program: material and layer constants, the source of each texture slot, and
/// the raster and depth state.
public struct WPEParityProgramBinding: Sendable {
    public enum TextureSource: Hashable, Sendable {
        /// A frame resource: layer composite, effect FBO or `_rt_*` target.
        case resource(WPEResourceID)
        /// A layer image the frame imports, holding `materials/<asset>.tex`; nil when the material binds none.
        case imported(WPEResourceID, asset: String?)
        /// `materials/<name>.tex`.
        case asset(String)
    }

    /// HLSL name → value; of the engine `g_*` values only the layer colour and alpha are included.
    public var constants: [String: WPECBufferValue]
    /// Bound slots, and unbound slots whose sampler annotation names a default texture.
    public var textures: [Int32: TextureSource]
    /// Material `cullmode`.
    public var cullsBackFaces: Bool
    /// The material's depth state where the frame applies it (models, bit4 composites); off for every other draw.
    public var depthTest: Bool
    public var depthWrite: Bool
}

public extension WPEParityProgramBuilder {
    /// Keyed by draw operation index like `frame.draws`; a draw without a material file has none.
    static func bindings(frame: WPEParityFrame, scene: WPEParityProgramScene) -> [Int: WPEParityProgramBinding] {
        let imported = Set(frame.resources.filter { $0.lifetime == .imported }.map(\.id))
        let white = SIMD4<Float>(repeating: 1)
        var bindings: [Int: WPEParityProgramBinding] = [:]
        for (index, draw) in frame.draws {
            switch draw {
            case let .scene(draw):
                guard let material = scene.material(for: draw) else { continue }
                let object = scene.scene.objects.first { $0.id == draw.objectID }
                // 1401e8aa0.c:1092-1095: effect, compose and passthrough draws run with colour and alpha 1.
                let albedo = draw.effectID == nil && draw.source != nil && draw.source == object?.material
                let (constants, names) = resolve(material, assets: scene.assets,
                                                 layerColor: albedo ? scene.layerColors[draw.objectID] ?? white : white)
                bindings[index] = WPEParityProgramBinding(
                    constants: constants, textures: textures(names, draw: draw, object: object, imported: imported),
                    cullsBackFaces: material.cullsBackFaces, depthTest: draw.depthTest, depthWrite: draw.depthWrite
                )
            case let .post(draw):
                let material = scene.engineMaterial(draw)
                var (constants, _) = resolve(material, assets: scene.assets, layerColor: white)
                constants.merge(draw.bloomParameters.mapValues { .vector([$0.x, $0.y, $0.z, $0.w]) }) { $1 }
                var textures: [Int32: WPEParityProgramBinding.TextureSource] = [:]
                for (slot, read) in draw.reads.enumerated() {
                    textures[Int32(slot)] = .resource(read)
                }
                bindings[index] = WPEParityProgramBinding(
                    constants: constants, textures: textures,
                    cullsBackFaces: material.cullsBackFaces, depthTest: false, depthWrite: false
                )
            }
        }
        return bindings
    }

    /// Material constants over annotation defaults, the layer colour, and the texture name of each slot: bound, or
    /// the sampler annotation's default.
    private static func resolve(_ material: WPEParityProgramMaterial, assets: WPEParityProgramAssets,
                                layerColor: SIMD4<Float>) -> ([String: WPECBufferValue], [Int32: String]) {
        let sources = WPEParityProgramResolver.expandedSources(shader: material.shader, sources: assets)
        let uniforms = WPEParityProgramConstants.uniforms(vertex: sources.vertex, fragment: sources.fragment)
        var constants = WPEParityProgramConstants.resolve(uniforms, values: material.constants)
        // Engine codes 0x00–0x02.
        constants["g_Color4"] = .vector([layerColor.x, layerColor.y, layerColor.z, layerColor.w])
        constants["g_Color"] = .vector([layerColor.x, layerColor.y, layerColor.z])
        constants["g_Alpha"] = .float(layerColor.w)

        var names = material.textures
        let annotations = WPEShaderAnnotationCombos(vertexSource: sources.vertex, fragmentSource: sources.fragment)
        for (slot, sampler) in annotations.samplers.entries where names[slot] == nil && !sampler.defaultTexture.isEmpty {
            names[slot] = sampler.defaultTexture
        }
        return (constants, names)
    }

    /// Effect FBO names resolve through the pass `binds`, which the frame lists after the composite in `reads`.
    private static func textures(_ names: [Int32: String], draw: WPEParitySceneDraw, object: WPEParitySceneObject?,
                                 imported: Set<WPEResourceID>) -> [Int32: WPEParityProgramBinding.TextureSource] {
        var textures: [Int32: WPEParityProgramBinding.TextureSource] = [:]
        // Slot 0 of a draw outside an effect is its first read: the layer image, the snapshot a compose layer draws
        // over, or the bit4 composite. A material without textures still reads its layer image.
        if draw.effectID == nil, let first = draw.reads.first {
            textures[0] = imported.contains(first) ? .imported(first, asset: names[0]) : .resource(first)
        }
        let effect = object?.effects.first { $0.id == draw.effectID }
        let binds = draw.passIndex.flatMap { index in effect.map { $0.passes[index].binds } } ?? []
        for (slot, name) in names where textures[slot] == nil && !name.isEmpty {
            if name == "previous" {
                textures[slot] = draw.reads.first.map { .resource($0) }
            } else if let position = binds.firstIndex(of: name), position + 1 < draw.reads.count {
                textures[slot] = .resource(draw.reads[position + 1])
            } else if name.hasPrefix("_rt_") {
                textures[slot] = .resource(WPEResourceID(name))
            } else {
                textures[slot] = .asset(name)
            }
        }
        return textures
    }
}
