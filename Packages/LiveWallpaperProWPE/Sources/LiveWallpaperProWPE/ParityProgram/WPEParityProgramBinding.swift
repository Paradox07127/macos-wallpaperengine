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
        /// A glyph atlas of `WPEParityProgramScene.textAtlases`; its CPU pixels are uploaded whole when dirty.
        case textAtlas(key: String, atlas: WPEParityGlyphAtlasInstance.Atlas)
    }

    /// One stage's uniform annotated with a material key.
    public struct MaterialConstant: Hashable, Sendable {
        /// HLSL name.
        public let name: String
        public let material: String
        public let components: Int
        public let angle: Bool

        public init(name: String, material: String, components: Int, angle: Bool = false) {
            self.name = name
            self.material = material
            self.components = components
            self.angle = angle
        }

        /// WPE reads as many numbers as the uniform has components; missing ones are 0.
        public func value(_ constant: WPEParitySceneState.Constant) -> WPECBufferValue {
            let floats = (0 ..< components).map { $0 < constant.count ? constant.value[$0] : 0 }
            return components == 1 ? .float(floats[0]) : .vector(floats)
        }
    }

    /// HLSL name → value for each stage the program has, from that stage's own annotations; of the engine `g_*`
    /// values only the layer colour and alpha are included.
    public var constants: [WPEHLSLStage: [String: WPECBufferValue]]
    /// Bound slots, and unbound slots whose sampler annotation names a default texture.
    public var textures: [Int32: TextureSource]
    /// Material `cullmode`.
    public var cullsBackFaces: Bool
    /// The material's depth state where the frame applies it (models, bit4 composites); off for every other draw.
    public var depthTest: Bool
    public var depthWrite: Bool
    /// The object whose live colour and alpha replace the loaded ones each frame; nil for draws that write 1.
    public var layerColorObjectID: String?
    /// The scene material pass whose live constants re-pack `constants`; nil for engine materials.
    public var materialPass: WPEParityMaterialPassKey?
    /// Per stage, the uniforms `materialPass` constants land in.
    public var materialConstants: [WPEHLSLStage: [MaterialConstant]] = [:]
}

public extension WPEParityProgramBuilder {
    /// Keyed by draw operation index like `frame.draws`; a draw without a material file has none.
    static func bindings(frame: WPEParityFrame, scene: WPEParityProgramScene,
                         description: WPEParitySceneDescription? = nil) -> [Int: WPEParityProgramBinding] {
        let imported = Set(frame.resources.filter { $0.lifetime == .imported }.map(\.id))
        let white = SIMD4<Float>(repeating: 1)
        var bindings: [Int: WPEParityProgramBinding] = [:]
        for (index, draw) in frame.draws {
            switch draw {
            case let .scene(draw):
                guard let material = scene.material(for: draw) else { continue }
                let object = (description ?? scene.scene).objects.first { $0.id == draw.objectID }
                // 1401e8aa0.c:1092-1095: effect, compose and passthrough draws run with colour and alpha 1.
                // A puppet's albedo adds skinning combos and clip textures to the layer material.
                var layerSource = draw.source
                layerSource?.combos = object?.material?.combos ?? [:]
                layerSource?.textures = object?.material?.textures ?? [:]
                let albedo = draw.effectID == nil && layerSource != nil && layerSource == object?.material
                var layerColor = albedo ? scene.layerColors[draw.objectID] : nil
                var fixedColor = white
                var atlas: WPEParityProgramBinding.TextureSource?
                if case let .text(text)? = object?.kind {
                    // 140258050.c:106-116, 184-191: glyphs take the live layer colour, the background quad its own.
                    switch draw.geometry {
                    case let .textGlyphs(list):
                        layerColor = scene.layerColors[draw.objectID]
                        atlas = .textAtlas(key: text.atlasKey, atlas: list)
                    case .textBackground:
                        fixedColor = text.background
                    default:
                        break
                    }
                }
                let (constants, names, uniforms) = resolve(material, assets: scene.assets,
                                                           layerColor: layerColor ?? fixedColor)
                var slots = textures(names, draw: draw, object: object, imported: imported)
                slots[0] = atlas ?? slots[0]
                bindings[index] = WPEParityProgramBinding(
                    constants: constants, textures: slots,
                    cullsBackFaces: material.cullsBackFaces, depthTest: draw.depthTest, depthWrite: draw.depthWrite,
                    layerColorObjectID: layerColor == nil ? nil : draw.objectID,
                    materialPass: scene.passKey(for: draw),
                    materialConstants: uniforms.mapValues { stage in
                        stage.values.sorted { $0.name < $1.name }.map {
                            WPEParityProgramBinding.MaterialConstant(name: $0.name, material: $0.material,
                                                                     components: $0.components, angle: $0.angle)
                        }
                    }
                )
            case let .post(draw):
                let material = scene.engineMaterial(draw)
                var (constants, _, _) = resolve(material, assets: scene.assets, layerColor: white)
                let engine = draw.constants.mapValues { $0.count == 1 ? WPECBufferValue.float($0[0]) : .vector($0) }
                for stage in constants.keys {
                    constants[stage]?.merge(engine) { $1 }
                }
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

    /// Material constants over annotation defaults, the layer colour, the texture name of each slot (bound, or the
    /// sampler annotation's default) and each stage's material uniforms.
    private static func resolve(_ material: WPEParityProgramMaterial, assets: WPEParityProgramAssets,
                                layerColor: SIMD4<Float>)
        -> ([WPEHLSLStage: [String: WPECBufferValue]], [Int32: String],
            [WPEHLSLStage: [String: WPEParityMaterialUniform]]) {
        let sources = WPEParityProgramResolver.expandedSources(shader: material.shader, sources: assets)
        var stages: [WPEHLSLStage: String] = [.vertex: sources.vertex, .fragment: sources.fragment]
        stages[.geometry] = sources.geometry
        // Engine codes 0x00–0x02.
        let color: [String: WPECBufferValue] = [
            "g_Color4": .vector([layerColor.x, layerColor.y, layerColor.z, layerColor.w]),
            "g_Color": .vector([layerColor.x, layerColor.y, layerColor.z]),
            "g_Alpha": .float(layerColor.w),
        ]
        let uniforms = stages.mapValues(WPEParityProgramConstants.uniforms)
        let constants = uniforms.mapValues { uniforms in
            WPEParityProgramConstants.resolve(uniforms, values: material.constants).merging(color) { $1 }
        }

        var names = material.textures
        let annotations = WPEShaderAnnotationCombos(vertexSource: sources.vertex, fragmentSource: sources.fragment)
        for (slot, sampler) in annotations.samplers.entries where names[slot] == nil && !sampler.defaultTexture.isEmpty {
            names[slot] = sampler.defaultTexture
        }
        return (constants, names, uniforms)
    }

    /// Effect FBO names resolve through the pass `binds`, which the frame lists after the composite in `reads`.
    private static func textures(_ names: [Int32: String], draw: WPEParitySceneDraw, object: WPEParitySceneObject?,
                                 imported: Set<WPEResourceID>) -> [Int32: WPEParityProgramBinding.TextureSource] {
        var textures: [Int32: WPEParityProgramBinding.TextureSource] = [:]
        // Slot 0 of a draw outside an effect is its first read: the layer image, the snapshot a compose layer draws
        // over, or the bit4 composite. A material without textures still reads its layer image. Particles and models
        // read only the frame resources their materials name, in the slots that name them.
        let materialSlotsOnly = switch draw.geometry {
        case .particles, .modelMesh: true
        default: false
        }
        if !materialSlotsOnly, draw.effectID == nil, let first = draw.reads.first {
            textures[0] = imported.contains(first) ? .imported(first, asset: names[0]) : .resource(first)
        }
        let effect = object?.effects.first { $0.id == draw.effectID }
        let binds = draw.passIndex.flatMap { index in effect.map { $0.passes[index].binds } } ?? []
        // A shape pass reads no composite, so its first read is a bind.
        let previous = if case .shape = object?.kind {
            nil as WPEResourceID?
        } else {
            draw.reads.first
        }
        let bindsStart = previous == nil ? 0 : 1
        for (slot, name) in names where textures[slot] == nil && !name.isEmpty {
            if name == "previous" {
                textures[slot] = previous.map { .resource($0) }
            } else if let position = binds.firstIndex(of: name), position + bindsStart < draw.reads.count {
                textures[slot] = .resource(draw.reads[position + bindsStart])
            } else if name.hasPrefix("_rt_") {
                textures[slot] = .resource(WPEResourceID(name))
            } else {
                textures[slot] = .asset(name)
            }
        }
        return textures
    }
}
