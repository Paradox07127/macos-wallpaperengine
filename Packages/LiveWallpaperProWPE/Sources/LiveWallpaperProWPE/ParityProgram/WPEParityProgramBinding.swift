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
        case textAtlas(key: String, atlas: WPEParityGlyphAtlasInstance.Atlas,
                       colorScale: Int = 1, plane: WPEParityGlyphAtlas.Plane = .primary)
        /// The morph-target texture of this puppet layer's mesh0.
        case morph(objectID: String)
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
    /// The native full RV0/1/2 and partial RV3.x write of this admitted glyph draw.
    public var textRenderVars: WPEParityTextDrawParameters?
    /// Bound slots, and unbound slots whose sampler annotation names a default texture.
    public var textures: [Int32: TextureSource]
    /// All original declaration loci, including ordinary user textures and unresolved merge diagnostics.
    public var userTextures: WPEParityProgramUserTextures = .init()
    /// Declarations eligible to replace this draw's authored asset fallback. Graph/atlas producers own other slots.
    public var userTextureSlots: [Int32: WPESceneUserTextureBinding] = [:]
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
        let resources = Set(frame.resources.map(\.id))
        let white = SIMD4<Float>(repeating: 1)
        // The first object with an id wins, as `first(where:)` would.
        let objects = Dictionary((description ?? scene.scene).objects.map { ($0.id, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var bindings: [Int: WPEParityProgramBinding] = [:]
        for (index, draw) in frame.draws {
            switch draw {
            case let .scene(draw):
                guard let material = scene.material(for: draw) else { continue }
                let object = objects[draw.objectID]
                // The producer assigns the native pass role once. Clip targets inherit their albedo/fill role;
                // masks and composite publication cannot multiply the layer colour a second time.
                var layerColor = draw.colorRole.usesLayerColor ? scene.layerColors[draw.objectID] : nil
                var fixedColor = white
                var atlas: WPEParityProgramBinding.TextureSource?
                var companion: WPEParityProgramBinding.TextureSource?
                var textRenderVars: WPEParityTextDrawParameters?
                if case let .text(text)? = object?.kind {
                    // 140258050.c:106-116, 184-191: glyphs take the live layer colour, the background quad its own.
                    switch draw.geometry {
                    case let .textGlyphs(list):
                        layerColor = scene.layerColors[draw.objectID]
                        let scale = list == .color ? text.layout.mesh?.colorAtlasScale ?? 1 : 1
                        atlas = .textAtlas(key: text.atlasKey, atlas: list, colorScale: scale)
                        if list == .color, text.layout.mesh?.glyphMode == .distanceField,
                           text.layout.mesh?.colorAtlasScale != nil {
                            companion = .textAtlas(key: text.atlasKey, atlas: list, colorScale: scale, plane: .companion)
                        }
                        textRenderVars = text.fieldParameters
                    case .textBackground:
                        fixedColor = text.background
                    default:
                        break
                    }
                }
                let (constants, names, uniforms) = resolve(material, assets: scene.assets,
                                                           layerColor: layerColor ?? fixedColor)
                var slots = textures(names, draw: draw, object: object, imported: imported,
                                     known: resources.union(draw.reads))
                slots[0] = atlas ?? slots[0]
                slots[1] = companion ?? slots[1]
                // 140206ae0.c:344-352: MORPHING binds the puppet's morph texture to slot 5.
                if draw.source?.combos["MORPHING"] == 1 {
                    slots[5] = .morph(objectID: draw.objectID)
                }
                bindings[index] = WPEParityProgramBinding(
                    constants: constants, textRenderVars: textRenderVars, textures: slots, userTextures: material.userTextures,
                    userTextureSlots: userTextureSlots(material.userTextures, textures: slots),
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
                let (materialConstants, names, _) = resolve(material, assets: scene.assets, layerColor: white)
                var constants = materialConstants
                let engine = draw.constants.mapValues { $0.count == 1 ? WPECBufferValue.float($0[0]) : .vector($0) }
                for stage in constants.keys {
                    constants[stage]?.merge(engine) { $1 }
                }
                var textures: [Int32: WPEParityProgramBinding.TextureSource] = [:]
                for (slot, name) in names where !name.isEmpty {
                    let id = WPEResourceID(name)
                    if name == "previous" {
                        textures[slot] = draw.reads.first.map { .resource($0) }
                    } else if resources.contains(id) {
                        textures[slot] = .resource(id)
                    } else {
                        textures[slot] = .asset(name)
                    }
                }
                // Engine reads own these slots even when a material or annotation names an asset there.
                for (slot, read) in draw.reads.enumerated() {
                    textures[Int32(slot)] = .resource(read)
                }
                bindings[index] = WPEParityProgramBinding(
                    constants: constants, textures: textures, userTextures: material.userTextures,
                    userTextureSlots: userTextureSlots(material.userTextures, textures: textures),
                    cullsBackFaces: material.cullsBackFaces, depthTest: false, depthWrite: false
                )
            }
        }
        return bindings
    }

    private static func userTextureSlots(_ declarations: WPEParityProgramUserTextures,
                                         textures: [Int32: WPEParityProgramBinding.TextureSource])
        -> [Int32: WPESceneUserTextureBinding] {
        declarations.slots.filter { slot, _ in
            switch textures[slot] {
            case .asset?, .imported?: true
            case .resource?, .textAtlas?, .morph?, nil: false
            }
        }
    }

    /// Material constants over annotation defaults, the layer colour, the texture name of each slot (bound, or the
    /// sampler annotation's default) and each stage's material uniforms.
    private static func resolve(_ material: WPEParityProgramMaterial, assets: WPEParityProgramAssets,
                                layerColor: SIMD4<Float>)
        -> ([WPEHLSLStage: [String: WPECBufferValue]], [Int32: String],
            [WPEHLSLStage: [String: WPEParityMaterialUniform]]) {
        let declarations = assets.shaderDeclarations(material.shader)
        // Engine codes 0x00–0x02.
        let color: [String: WPECBufferValue] = [
            "g_Color4": .vector([layerColor.x, layerColor.y, layerColor.z, layerColor.w]),
            "g_Color": .vector([layerColor.x, layerColor.y, layerColor.z]),
            "g_Alpha": .float(layerColor.w),
        ]
        let constants = declarations.uniforms.mapValues { uniforms in
            WPEParityProgramConstants.resolve(uniforms, values: material.constants).merging(color) { $1 }
        }

        let names = resolvedTextureNames(material, annotations: declarations.annotations)
        return (constants, names, declarations.uniforms)
    }

    /// Bound texture names and sampler defaults, shared with the native particle base-material probe.
    internal static func resolvedTextureNames(_ material: WPEParityProgramMaterial,
                                              assets: WPEParityProgramAssets) -> [Int32: String] {
        resolvedTextureNames(material, annotations: assets.shaderDeclarations(material.shader).annotations)
    }

    /// Preserve authored FBO/previous ordering and include engine RT defaults in the same candidate read chain.
    /// Annotation presence is not an allocation request: compiled active slots determine that before readiness.
    internal static func resolvedFrameTextureNames(_ material: WPEParityProgramMaterial,
                                                   engineFlags: WPEEngineComboFlags,
                                                   assets: WPEParityProgramAssets) -> [String] {
        var names = material.textureNames
        let candidates = resolvedTextureNames(material, assets: assets).sorted(by: { $0.key < $1.key })
            .filter { $0.value.hasPrefix("_rt_") && !names.contains($0.value) }
        guard !candidates.isEmpty else { return names }
        let declared = declaredSamplerSlots(material, engineFlags: engineFlags, assets: assets)
        for (slot, name) in candidates where material.textures[slot] != nil || declared.contains(slot) {
            names.append(name)
        }
        return names
    }

    /// Sampler slots whose declaration survives `#if` under the define set the program compiles with.
    private static func declaredSamplerSlots(_ material: WPEParityProgramMaterial, engineFlags: WPEEngineComboFlags,
                                             assets: WPEParityProgramAssets) -> Set<Int32> {
        let program = description(material, engineFlags: engineFlags, assets: assets)
        let defines = WPEComboResolver.resolve(
            passJSONCombos: program.passJSONCombos, blendingMode: Int32(material.blending.rawValue),
            annotations: assets.shaderDeclarations(material.shader).annotations,
            engineFlags: program.engineFlags, boundTextures: program.boundTextures
        )
        return assets.declaredSamplerSlots(material.shader, defines: defines) {
            // The prelude WPEHLSLRewriter.rewrite puts ahead of the combos.
            let prelude = "#define HLSL 1\n#define HLSL_SM40 1\n#define GS_ENABLED 1\n"
                + defines.map { "#define \($0.name) \($0.value)\n" }.joined()
            let sources = assets.expandedSources(material.shader)
            func active(_ source: String) -> String {
                // A source the preprocessor rejects does not compile, so it declares nothing.
                let text = try? WPEShaderPreprocessor.run(Latin1.bytes(prelude) + Array(source.utf8))
                return text.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
            }
            let annotations = WPEShaderAnnotationCombos(vertexSource: active(sources.vertex),
                                                        fragmentSource: active(sources.fragment))
            return Set(annotations.samplers.entries.map(\.key))
        }
    }

    private static func resolvedTextureNames(_ material: WPEParityProgramMaterial,
                                             annotations: WPEShaderAnnotationCombos) -> [Int32: String] {
        var names = material.textures
        for (slot, sampler) in annotations.samplers.entries where names[slot] == nil && !sampler.defaultTexture.isEmpty {
            names[slot] = sampler.defaultTexture
        }
        return names
    }

    /// Effect FBO names resolve through the pass `binds`, which the frame lists after the composite in `reads`.
    private static func textures(_ names: [Int32: String], draw: WPEParitySceneDraw, object: WPEParitySceneObject?,
                                 imported: Set<WPEResourceID>, known: Set<WPEResourceID>)
        -> [Int32: WPEParityProgramBinding.TextureSource] {
        var textures: [Int32: WPEParityProgramBinding.TextureSource] = [:]
        // Slot 0 of a draw outside an effect is its first read: the layer image, the snapshot a compose layer draws
        // over, or the bit4 composite. A material without textures still reads its layer image. Particles and models
        // read only the frame resources their materials name, in the slots that name them.
        let materialSlotsOnly = switch draw.geometry {
        case .particles, .modelMesh: true
        default: false
        }
        if !materialSlotsOnly, draw.effectID == nil, let first = draw.reads.first {
            if imported.contains(first), let name = names[0], name.hasPrefix("_rt_"),
               known.contains(WPEResourceID(name)) {
                textures[0] = .resource(WPEResourceID(name))
            } else {
                textures[0] = imported.contains(first) ? .imported(first, asset: names[0]) : .resource(first)
            }
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
            } else if name.hasPrefix("_rt_"), known.contains(WPEResourceID(name)) {
                textures[slot] = .resource(WPEResourceID(name))
            } else {
                textures[slot] = .asset(name)
            }
        }
        return textures
    }
}
