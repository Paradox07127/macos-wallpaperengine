import Foundation

/// User and device state that feeds WPE's global combos (Main+0x118 / Main+0x128).
public struct WPEParityProgramSettings: Sendable, Equatable {
    /// User bloom switch; bloom also needs scene `general.bloom` and a non-empty object table.
    public var bloom: Bool
    /// Postprocessing "ultra" or "displayhdr" (0x2000 / 0x6000).
    public var hdrPostProcessing: Bool
    /// User MSAA x2/x4/x8 that the device supports.
    public var msaa: Bool

    public init(bloom: Bool = true, hdrPostProcessing: Bool = false, msaa: Bool = false) {
        self.bloom = bloom
        self.hdrPostProcessing = hdrPostProcessing
        self.msaa = msaa
    }
}

/// A scene document, read with its wallpaper and WPE assets, turned into the parity frame inputs. Each albedo and
/// effect pass keeps its merged material so frame draws find the JSON their combos come from. The frame is composed
/// with MSAA off and no transparent sorting.
public struct WPEParityProgramScene: Sendable {
    struct MaterialKey: Hashable, Sendable {
        let objectID: String
        let effectID: String?
        let source: WPEParitySceneMaterialSource
    }

    public let scene: WPEParitySceneDescription
    public let postProcess: WPEParityPostProcessConfig
    public let engineFlags: WPEEngineComboFlags
    public let assets: WPEParityProgramAssets
    /// The `.mdl` of each layer with a `WPEParityScenePuppet`, keyed by object id; the bone animator needs it.
    public let puppetModels: [String: WPEPuppetModel]
    let materials: [MaterialKey: WPEParityProgramMaterial]
    /// Index of each effect material among its effect's scene `passes` overrides; albedo materials are absent.
    let overridePasses: [MaterialKey: Int]
    /// Image layer `g_Color4` (140207b50.c:81-100): colour × (HDR ? brightness : 1), alpha.
    let layerColors: [String: SIMD4<Float>]
    /// The image layers of `scene.objects`, in the same order, as their files declare them.
    private let authoredObjects: [WPEParityAuthoredObject]

    public init(document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings) {
        let general = document.sourceJSON["general"]
        let bloomGeneral = document.resolvedGeneralJSON
        let objects = Self.array(document.sourceJSON["objects"])
        var flags = WPEEngineComboFlags()
        // 140186c90.c:356-393
        if case .object? = general?["orthogonalprojection"], let ortho = general?["orthogonalprojection"] {
            flags.orthographicProjection = Self.flag(ortho["auto"]) || (Self.flag(ortho["width"]) && Self.flag(ortho["height"]))
        }
        // Main+0x118 bits 23/24 (140186440.c:28-39).
        flags.fogDistance = Self.flag(general?["fogdistance"])
        flags.fogHeight = Self.flag(general?["fogheight"])
        // e0 starts at 0x26 (bloom on) and only keys present in the JSON change it (140186c90.c:130).
        let sceneBloom = bloomGeneral["bloom"].map { Self.flag($0) } ?? true
        // 14010df40.c:299-335, 365, 519-552
        flags.hdr = sceneBloom && Self.flag(general?["hdr"]) && settings.hdrPostProcessing
        flags.backbufferMSAA = settings.msaa && objects.contains { $0["model"] != nil }
        engineFlags = flags
        self.assets = assets

        let width = Int(document.general.orthogonalProjection.width.rounded())
        let height = Int(document.general.orthogonalProjection.height.rounded())
        let format = flags.hdr ? "rgba16float" : WPEParitySceneResource.colorFormat
        var authoredByID: [String: WPESceneJSONValue] = [:]
        for object in objects {
            guard let id = Self.string(object["id"]) ?? Self.number(object["id"]).map({ String(Int($0)) }) else {
                continue
            }
            authoredByID[id] = object
        }
        var materials: [MaterialKey: WPEParityProgramMaterial] = [:]
        var overridePasses: [MaterialKey: Int] = [:]
        var layerColors: [String: SIMD4<Float>] = [:]
        var puppetModels: [String: WPEPuppetModel] = [:]
        var authoredObjects: [WPEParityAuthoredObject] = []
        var sceneObjects: [WPEParitySceneObject] = []
        for (index, image) in document.imageObjects.enumerated() {
            let color = SIMD3<Float>(image.color) * (flags.hdr ? Float(image.brightness) : 1)
            layerColors[image.id] = SIMD4(color.x, color.y, color.z, Float(image.alpha))
            let isModel = image.imageRelativePath.lowercased().hasSuffix(".mdl")
            let model = isModel ? nil : assets.json(image.imageRelativePath)
            let materialPath = isModel
                ? Self.modelMaterialPath(image.imageRelativePath, assets: assets)
                : Self.string(model?["material"]) ?? image.materialRelativePath
            let albedoSource = materialPath.map { WPEParitySceneMaterialSource(materialPath: $0) }
            var material = materialPath.flatMap { WPEParityProgramMaterial(path: $0, assets: assets) }
            if let instance = image.materialInstance {
                // The instance merges over the pass JSON before annotation defaults fill missing keys (r3 Q1 J, Q4).
                material?.merge(combos: instance.combos, textures: instance.textures, constants: instance.constants)
            }
            let authored = authoredByID[image.id]
            if let albedoSource, let material {
                materials[MaterialKey(objectID: image.id, effectID: nil, source: albedoSource)] = material
            }
            let fullscreen = Self.flag(model?["fullscreen"])
            // catsout WPSceneParser.cpp binds a fullscreen layer's FBOs to the screen.
            let objectWidth = fullscreen ? width : image.size.map { Int($0.width.rounded()) } ?? width
            let objectHeight = fullscreen ? height : image.size.map { Int($0.height.rounded()) } ?? height
            var effects: [WPEParityAuthoredEffect] = []
            for effect in isModel ? [] : image.effects {
                guard let file = assets.json(effect.fileRelativePath) else { continue }
                let loaded = Self.effect(effect, file: file, assets: assets)
                effects.append(loaded.effect)
                for (source, material, pass) in loaded.materials {
                    let key = MaterialKey(objectID: image.id, effectID: effect.id, source: source)
                    materials[key] = material
                    overridePasses[key] = pass
                }
            }
            authoredObjects.append(WPEParityAuthoredObject(id: image.id, width: objectWidth, height: objectHeight,
                                                           effects: effects))
            let loadedPuppet = Self.string(model?["puppet"]).flatMap { Self.puppet($0, assets: assets) }
            let puppet = loadedPuppet?.puppet
            puppetModels[image.id] = loadedPuppet?.model
            // FUN_14020ae00: the albedo's TEXI flags are Texture+0x1c, where bit2 marks a sequence. A bit4 already
            // set by blend mode, ledsource or fog needs nothing here.
            let sequence = material?.textures[0].flatMap(assets.textureHeader(named:)).map { $0.flags & 4 != 0 }
            let puppetForcesComposite = puppet.map {
                !effects.isEmpty || sequence == true || $0.blendMeshIndex != nil
            } ?? false
            // A model's state comes from its material alone.
            let blend: WPEParitySceneBlend = if image.colorBlendMode == 31, !isModel {
                .additive
            } else {
                material.map { WPEParitySceneBlend($0.blending) } ?? .translucent
            }
            sceneObjects.append(WPEParitySceneObject(
                id: image.id, kind: isModel ? .model : .image, sortKey: document.objectPaintOrder[image.id] ?? index,
                visible: Self.visible(image.id, document), width: objectWidth, height: objectHeight,
                materialShader: material?.shader ?? "genericimage2", material: albedoSource, blend: blend,
                materialState: Self.materialState(materialPath.flatMap { assets.json($0)?["passes"]?[0] }),
                materialFog: material.map { Self.programHasFog($0, assets: assets) } ?? false,
                colorBlendMode: image.colorBlendMode,
                passthrough: Self.flag(model?["passthrough"]) || image.config.passthrough,
                copyBackground: image.copyBackground, fullscreen: fullscreen,
                ledSource: Self.flag(authored?["ledsource"]), puppetForcesComposite: puppetForcesComposite,
                puppet: puppet,
                noInterpolation: Self.flag(authored?["nointerpolation"]),
                clampUVs: Self.number(authored?["clampuvs"]).map { $0 != 0 } ?? true,
                parentID: image.parentObjectID
            ))
        }
        let scope = WPEParitySceneFBOScope(authoredObjects, backbufferFormat: format)
        var diagnostics: [WPEParitySceneDiagnostic] = []
        for index in sceneObjects.indices {
            sceneObjects[index].effects = scope.effects(of: authoredObjects[index], diagnostics: &diagnostics)
        }
        for (index, particle) in document.particleObjects.enumerated() {
            let draws = Self.particleDraws(objectID: particle.id, path: particle.particleRelativePath, assets: assets,
                                           diagnostics: &diagnostics)
            sceneObjects.append(WPEParitySceneObject(
                id: particle.id, kind: .particle(WPEParitySceneParticle(draws: draws)),
                sortKey: document.objectPaintOrder[particle.id] ?? index, visible: Self.visible(particle.id, document),
                width: 0, height: 0, parentID: particle.parentObjectID
            ))
        }
        self.materials = materials
        self.overridePasses = overridePasses
        self.layerColors = layerColors
        self.puppetModels = puppetModels
        self.authoredObjects = authoredObjects
        scene = WPEParitySceneDescription(width: width, height: height, backbufferFormat: format,
                                          clearColor: document.general.clearColor,
                                          clearEnabled: document.general.clearEnabled.resolvedValue,
                                          forcesLayerComposite: flags.fogDistance || flags.fogHeight,
                                          objects: sceneObjects, diagnostics: diagnostics)
        postProcess = WPEParityPostProcessConfig(sceneBloomEnabled: sceneBloom, userBloomEnabled: settings.bloom,
                                                 objectTableNonEmpty: !objects.isEmpty, hdrEnabled: flags.hdr,
                                                 bloomSettings: Self.bloomSettings(bloomGeneral),
                                                 backbufferWidth: width, backbufferHeight: height,
                                                 backbufferFormat: format)
    }

    /// `scene` with each image layer effect enabled as `visible` says. FBO declarations follow the enabled set, as a
    /// load with that set gives them.
    public func scene(effectVisible visible: (_ objectID: String, _ effectID: String) -> Bool)
        -> WPEParitySceneDescription {
        var authored = authoredObjects
        for object in authored.indices {
            for effect in authored[object].effects.indices {
                authored[object].effects[effect].enabled = visible(authored[object].id,
                                                                   authored[object].effects[effect].id)
            }
        }
        let scope = WPEParitySceneFBOScope(authored, backbufferFormat: scene.backbufferFormat)
        var description = scene
        var diagnostics: [WPEParitySceneDiagnostic] = []
        for index in authored.indices {
            description.objects[index].effects = scope.effects(of: authored[index], diagnostics: &diagnostics)
        }
        return description
    }

    /// Only authored keys override WPE's defaults, after user-property resolution (1401730d0.c:35-49).
    static func bloomSettings(_ general: WPESceneJSONValue) -> WPEParityBloomSettings {
        var settings = WPEParityBloomSettings()
        func value(_ key: String) -> Float? {
            number(general[key]).map(Float.init)
        }
        settings.strength = value("bloomstrength") ?? settings.strength
        settings.threshold = value("bloomthreshold") ?? settings.threshold
        settings.hdrStrength = value("bloomhdrstrength") ?? settings.hdrStrength
        settings.hdrThreshold = value("bloomhdrthreshold") ?? settings.hdrThreshold
        settings.hdrFeather = value("bloomhdrfeather") ?? settings.hdrFeather
        settings.hdrScatter = value("bloomhdrscatter") ?? settings.hdrScatter
        settings.hdrIterations = value("bloomhdriterations").map { Int($0) } ?? settings.hdrIterations
        if let tintValue = general["bloomtint"],
           let tint = WPEParityProgramConstants.components(tintValue),
           tint.count == 3 {
            settings.tint = SIMD3<Float>(Float(tint[0]), Float(tint[1]), Float(tint[2]))
        }
        return settings
    }

    /// The merged pass JSON `draw` uses; an engine (util) material is read from its file with the engine's combos.
    func material(for draw: WPEParitySceneDraw) -> WPEParityProgramMaterial? {
        guard let source = draw.source else { return nil }
        var stored = source
        stored.combos = [:]
        var material = materials[MaterialKey(objectID: draw.objectID, effectID: draw.effectID, source: stored)]
            ?? WPEParityProgramMaterial(path: source.materialPath, pass: source.materialPass, assets: assets)
        material?.merge(combos: source.combos, textures: [:])
        if let shader = source.shader {
            material?.shader = shader
        }
        return material
    }

    /// The scene material pass whose constants `draw` uses; nil for engine materials, which the scene cannot set.
    func passKey(for draw: WPEParitySceneDraw) -> WPEParityMaterialPassKey? {
        guard var stored = draw.source else { return nil }
        stored.combos = [:]
        let key = MaterialKey(objectID: draw.objectID, effectID: draw.effectID, source: stored)
        guard materials[key] != nil else { return nil }
        return WPEParityMaterialPassKey(objectID: draw.objectID, effectID: draw.effectID, pass: overridePasses[key] ?? 0)
    }

    /// A post-process draw's material file, or its own name as the shader when the file is missing.
    func engineMaterial(_ draw: WPEParityPostProcessDraw) -> WPEParityProgramMaterial {
        WPEParityProgramMaterial(path: draw.material, assets: assets) ?? WPEParityProgramMaterial(shader: draw.shader)
    }

    /// 0x14020744c: the material's own combos, shader defaults included, decide whether its composite keeps FOG.
    private static func programHasFog(_ material: WPEParityProgramMaterial, assets: WPEParityProgramAssets) -> Bool {
        let sources = WPEParityProgramResolver.expandedSources(shader: material.shader, sources: assets)
        let description = WPEParityProgramDescription(material: material, engineFlags: WPEEngineComboFlags(),
                                                      boundTextures: [:])
        let defines = WPEComboResolver.resolve(passJSONCombos: description.passJSONCombos,
                                               blendingMode: Int32(material.blending.rawValue),
                                               vertexSource: sources.vertex, fragmentSource: sources.fragment,
                                               engineFlags: description.engineFlags, boundTextures: [:])
        return defines.contains { $0.name == "FOG" && $0.value != "0" }
    }

    /// 140155fc0.c:713-738: only the non-default values of these keys change state.
    static func materialState(_ pass: WPESceneJSONValue?) -> WPEParitySceneMaterialState {
        func value(_ key: String) -> String? {
            string(pass?[key])?.lowercased()
        }
        let alphaWriting: WPEParitySceneMaterialState.AlphaWriting = switch value("alphawriting") {
        case "enabled": .enabled
        case "disabled": .disabled
        default: .inherit
        }
        return WPEParitySceneMaterialState(depthTest: value("depthtest") != "disabled",
                                           depthWrite: value("depthwrite") != "disabled",
                                           cullsBackFaces: value("cullmode") != "nocull", alphaWriting: alphaWriting)
    }

    /// The material of the model's first mesh.
    private static func modelMaterialPath(_ path: String, assets: WPEParityProgramAssets) -> String? {
        assets.data(path).flatMap { try? WPEMdlParser.parse(data: $0).meshes.first?.materialPath }
    }

    /// Mesh0 of a model JSON `"puppet"`; its indices are u16 as WPE draws them (FUN_1401fbae0).
    private static func puppet(_ path: String,
                               assets: WPEParityProgramAssets) -> (puppet: WPEParityScenePuppet, model: WPEPuppetModel)? {
        guard let data = assets.data(path), let model = try? WPEMdlParser.parse(data: data),
              let mesh = model.meshes.first else { return nil }
        let boneIndices = firstMeshFormat(data).map { $0 & 0x800000 != 0 } ?? false
        let puppet = WPEParityScenePuppet(vertices: mesh.vertices,
                                          indices: mesh.indices.map { UInt16(truncatingIfNeeded: $0) },
                                          boneCount: model.bones.count, skinned: boneIndices && !model.bones.isEmpty)
        return (puppet, model)
    }

    /// Mesh0's vertex format, found the way `WPEMdlParser` walks the MDLV header; the parser does not expose it.
    private static func firstMeshFormat(_ data: Data) -> UInt32? {
        let bytes = [UInt8](data)
        guard bytes.count >= 21, let version = String(bytes: bytes[4 ..< 8], encoding: .ascii).flatMap(Int.init) else {
            return nil
        }
        func uint32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return (0 ..< 4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        let features = WPEMdlvFeatures(version: version)
        guard let headerFormat = uint32(9), let skins = uint32(13) else { return nil }
        guard features.perMeshFlags else { return headerFormat }
        var offset = 21
        for _ in 0 ..< skins {
            guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
            offset = end + 1
        }
        // Mesh flag 2 carries one more u32, then the bounds.
        guard let flag = uint32(offset) else { return nil }
        offset += (flag == 2 ? 8 : 4) + (features.meshBounds ? 24 : 0)
        return uint32(offset)
    }

    /// The object's own visible flag ANDed with every ancestor's.
    private static func visible(_ id: String, _ document: WPESceneDocument) -> Bool {
        var current: String? = id
        var seen: Set<String> = []
        while let object = current, seen.insert(object).inserted {
            if document.ownVisibilityByID[object] == false {
                return false
            }
            current = document.objectParentByID[object]
        }
        return true
    }

    private static func effect(_ effect: WPESceneImageEffect, file: WPESceneJSONValue, assets: WPEParityProgramAssets)
        -> (effect: WPEParityAuthoredEffect,
            materials: [(WPEParitySceneMaterialSource, WPEParityProgramMaterial, pass: Int)]) {
        let filePasses = array(file["passes"])
        var swapPartners: [String: String] = [:]
        for pass in filePasses where string(pass["command"]) == "swap" {
            guard let first = string(pass["source"]), let second = string(pass["target"]) else { continue }
            swapPartners[first] = second
            swapPartners[second] = first
        }
        var fbos: [WPEParityAuthoredFBO] = []
        for case let .object(fbo) in array(file["fbos"]) {
            guard let name = string(fbo["name"]) else { continue }
            fbos.append(WPEParityAuthoredFBO(name: name, scale: number(fbo["scale"]) ?? 1, fit: number(fbo["fit"]),
                                             format: string(fbo["format"]) ?? "rgba8888",
                                             swapPartner: swapPartners[name]))
        }
        var passes: [WPEParityAuthoredPass] = []
        var materials: [(WPEParitySceneMaterialSource, WPEParityProgramMaterial, pass: Int)] = []
        var materialIndex = 0
        for (passIndex, pass) in filePasses.enumerated() {
            if let command = string(pass["command"]) {
                // A swap is carried by the FBOs' swap partners.
                guard command == "copy" else { continue }
                let source = string(pass["source"]).flatMap { $0 == "previous" ? nil : $0 }
                passes.append(WPEParityAuthoredPass(kind: .copy(source: source), shader: "commands/copy",
                                                    target: string(pass["target"]), textures: [], compose: false,
                                                    blend: .normal, source: nil))
                continue
            }
            guard let path = string(pass["material"]),
                  var material = WPEParityProgramMaterial(path: path, assets: assets) else { continue }
            // Scene overrides line up with the effect's material passes.
            if materialIndex < effect.passOverrides.count {
                let override = effect.passOverrides[materialIndex]
                material.merge(combos: override.combos, textures: override.textures, constants: override.constants)
            }
            materialIndex += 1
            for case let .object(bind) in array(pass["bind"]) {
                guard let name = string(bind["name"]), let index = number(bind["index"]) else { continue }
                material.textures[Int32(index)] = name
            }
            if material.textures[0] == nil {
                material.textures[0] = "previous"
            }
            if let blending = string(pass["blending"]) {
                material.blending = WPEParityProgramMaterial.blendMode(blending)
            }
            let source = WPEParitySceneMaterialSource(materialPath: path, effectFile: effect.fileRelativePath,
                                                      effectPass: passIndex)
            passes.append(WPEParityAuthoredPass(
                kind: .draw, shader: material.shader, target: string(pass["target"]),
                textures: material.textures.sorted { $0.key < $1.key }.map(\.value),
                compose: pass["compose"] == .bool(true), blend: WPEParitySceneBlend(material.blending), source: source
            ))
            materials.append((source, material, materialIndex - 1))
        }
        return (WPEParityAuthoredEffect(id: effect.id, enabled: effect.visible, fbos: fbos, passes: passes), materials)
    }

    static func array(_ value: WPESceneJSONValue?) -> [WPESceneJSONValue] {
        if case let .array(values)? = value {
            values
        } else {
            []
        }
    }

    static func string(_ value: WPESceneJSONValue?) -> String? {
        if case let .string(text)? = value {
            text
        } else {
            nil
        }
    }

    static func number(_ value: WPESceneJSONValue?) -> Double? {
        switch value {
        case let .number(number)?: number
        case let .bool(flag)?: flag ? 1 : 0
        case let .object(envelope)?: number(envelope["value"])
        default: nil
        }
    }

    static func flag(_ value: WPESceneJSONValue?) -> Bool {
        (number(value) ?? 0) != 0
    }
}

public extension WPEParitySceneState {
    /// Every material pass the scene can set, seeded with the merged constants its bindings were built from.
    init(scene: WPEParityProgramScene, document: WPESceneDocument) {
        var constants: [WPEParityMaterialPassKey: [String: [Double]]] = [:]
        for (key, material) in scene.materials {
            constants[WPEParityMaterialPassKey(objectID: key.objectID, effectID: key.effectID,
                                               pass: scene.overridePasses[key] ?? 0)] = material.constants
        }
        self.init(document: document, hdr: scene.engineFlags.hdr, constants: constants)
    }
}

extension WPEParitySceneBlend {
    init(_ mode: WPEParityBlendMode) {
        switch mode {
        case .translucent: self = .translucent
        case .additive: self = .additive
        case .normal, .alphaToCoverage: self = .normal
        }
    }
}

extension WPEParityProgramMaterial {
    /// `passes[pass]` of a material file.
    init?(path: String, pass index: Int = 0, assets: WPEParityProgramAssets) {
        typealias Scene = WPEParityProgramScene
        guard let pass = assets.json(path)?["passes"]?[index], let shader = Scene.string(pass["shader"]) else {
            return nil
        }
        var combos: [String: Int32] = [:]
        if case let .object(entries)? = pass["combos"] {
            for (key, value) in entries {
                combos[key] = Scene.number(value).map { Int32($0) } ?? 0
            }
        }
        var textures: [Int32: String] = [:]
        for (slot, texture) in Scene.array(pass["textures"]).enumerated() {
            if let name = Scene.string(texture) {
                textures[Int32(slot)] = name
            }
        }
        var constants: [String: [Double]] = [:]
        if case let .object(entries)? = pass["constantshadervalues"] {
            for (key, value) in entries {
                constants[key] = WPEParityProgramConstants.components(value)
            }
        }
        self.init(shader: shader, path: path, blending: Self.blendMode(Scene.string(pass["blending"])),
                  combos: combos, textures: textures, constants: constants,
                  cullsBackFaces: Scene.string(pass["cullmode"])?.lowercased() != "nocull")
    }

    static func blendMode(_ raw: String?) -> WPEParityBlendMode {
        switch raw?.lowercased() {
        case "translucent": .translucent
        case "additive": .additive
        case "alphatocoverage": .alphaToCoverage
        default: .normal
        }
    }

    /// Scene instance or effect-pass override; null texture slots keep the base.
    mutating func merge(combos: [String: Int], textures: [Int: String],
                        constants: [String: WPESceneShaderConstantValue] = [:]) {
        for (key, value) in combos {
            self.combos[key] = Int32(truncatingIfNeeded: value)
        }
        for (slot, name) in textures {
            self.textures[Int32(slot)] = name
        }
        for (key, value) in constants {
            self.constants[key] = WPEParityProgramConstants.components(value)
        }
    }
}
