import Darwin
import Foundation

/// User and device state that feeds WPE's global combos (Main+0x118 / Main+0x128).
public struct WPEParityProgramSettings: Sendable, Equatable {
    /// User bloom switch; bloom also needs scene `general.bloom` and a non-empty object table.
    public var bloom: Bool
    /// Postprocessing "ultra" or "displayhdr" (0x2000 / 0x6000).
    public var hdrPostProcessing: Bool
    /// One disables MSAA; otherwise the product has resolved a device-supported 2/4/8 sample count.
    public var msaaSampleCount: Int
    /// Native `general.reflection` controls Main+0x128 bit7 and refreshes requested scene snapshots.
    /// The product resolves its preference/default once; actual shader slots independently own the request.
    public var mipMappedFrameBufferEnabled: Bool
    /// Compatibility for callers that only selected on/off. There is one stored sample count.
    public var msaa: Bool {
        get { msaaSampleCount > 1 }
        set { msaaSampleCount = newValue ? max(2, msaaSampleCount) : 1 }
    }

    /// The wallpaper's raw `wec_*` / `wcc_*` preset settings.
    public var colorCorrection: WPEParityColorCorrection
    /// Postprocessing "displayhdr" on an HDR output (Main+0x128 bit14).
    public var displayHDR: Bool
    /// The target screen's maximum potential EDR value, in reference-white units (1 = SDR white).
    public var maximumPotentialEDR: Float
    /// User `general.shadows` quality (render context +0x1ac); 0 = off.
    public var shadowQuality: Int32

    public init(bloom: Bool = true, hdrPostProcessing: Bool = false, msaa: Bool = false,
                msaaSampleCount: Int? = nil, mipMappedFrameBufferEnabled: Bool = false,
                colorCorrection: WPEParityColorCorrection = WPEParityColorCorrection(),
                displayHDR: Bool = false, maximumPotentialEDR: Float = 1,
                shadowQuality: Int32 = WPEEngineComboFlags().shadowQuality) {
        self.bloom = bloom
        self.shadowQuality = shadowQuality
        self.hdrPostProcessing = hdrPostProcessing
        self.displayHDR = displayHDR
        self.maximumPotentialEDR = maximumPotentialEDR
        self.msaaSampleCount = msaaSampleCount ?? (msaa ? 2 : 1)
        self.mipMappedFrameBufferEnabled = mipMappedFrameBufferEnabled
        self.colorCorrection = colorCorrection
    }
}

/// A scene document, read with its wallpaper and WPE assets, turned into the parity frame inputs. Each albedo and
/// effect pass keeps its merged material so frame draws find the JSON their combos come from. The frame is composed
/// with one resolved MSAA sample count; transparent members draw in the view-distance order the scene state keeps.
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
    /// `camera.paths` as loaded, at the start of the first path.
    public let cameraPaths: WPEParityCameraPaths
    /// The `.mdl` of each layer with a `WPEParityScenePuppet`, keyed by object id; the bone animator needs it.
    public let puppetModels: [String: WPEPuppetModel]
    /// The `.mdl` of each model object, keyed by object id; its meshes line up with `WPEParitySceneModel.meshes`.
    public let models: [String: WPEPuppetModel]
    /// The glyph atlases of the text layers as planning left them, keyed by `WPEParitySceneText.atlasKey`.
    public let textAtlases: [String: WPEParityGlyphAtlasInstance]
    /// The frame owner rejects this scene instead of displaying a bitmap beneath a requested field material.
    public let textPreparationFailure: WPEParityTextPreparationError?
    /// Condition-accepted resource pass records, including commands and empty/failed materials, even when the
    /// effect is disabled. An absent key means the effect resource did not load; an empty array is a known zero.
    public let resolvedEffectRecords: [WPEParitySceneState.EffectKey: [WPEParityEffectPassRecord]]
    /// Original effect-local functions and compact declaration order, including disabled effects.
    public let resolvedMaterialFunctions: [WPEParitySceneState.EffectKey: WPEParityMaterialFunctions]
    let materials: [MaterialKey: WPEParityProgramMaterial]
    /// Index of each effect material among its effect's scene `passes` overrides; albedo materials are absent.
    let overridePasses: [MaterialKey: Int]
    /// Image and text layer `g_Color4` (140207b50.c:81-100, 140258050.c:184-191): colour × (HDR ? brightness : 1),
    /// alpha.
    private(set) var layerColors: [String: SIMD4<Float>]
    /// Script-created image layer id → the loaded template whose materials and colour its draws use.
    public private(set) var createdTemplates: [String: String] = [:]
    /// The image then text layers leading `scene.objects`, in the same order, as their files declare them.
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
        flags.shadowQuality = settings.shadowQuality
        WPEParityLightConfig(general: general, shadowQuality: flags.shadowQuality).apply(to: &flags)
        // e0 starts at 0x26 (bloom on) and only keys present in the JSON change it (140186c90.c:130).
        let sceneBloom = WPEParityScriptProperty.sceneBoolValue(fromJSON: bloomGeneral["bloom"]) ?? true
        // 14010df40.c:299-335, 365, 519-552
        flags.hdr = Self.hdrEnabled(document: document, settings: settings)
        // A serialized model:null is not a model object. Match the class that actually draws MDL meshes below.
        let hasModels = document.imageObjects.contains { $0.imageRelativePath.lowercased().hasSuffix(".mdl") }
        let samples = hasModels && [2, 4, 8].contains(settings.msaaSampleCount) ? settings.msaaSampleCount : 1
        flags.backbufferMSAA = samples > 1
        engineFlags = flags
        self.assets = assets

        let width = Int(document.general.orthogonalProjection.width.rounded())
        let height = Int(document.general.orthogonalProjection.height.rounded())
        let format = flags.hdr ? "rgba16float" : WPEParitySceneResource.colorFormat
        var authoredByID: [String: WPESceneJSONValue] = [:]
        // 140186c90.c:759-788: every id any object lists under "dependencies".
        var dependencyTargets: Set<String> = []
        for object in objects {
            for dependency in Self.array(object["dependencies"]) {
                if let id = Self.string(dependency) ?? Self.number(dependency).map({ String(Int($0)) }) {
                    dependencyTargets.insert(id)
                }
            }
            guard let id = Self.string(object["id"]) ?? Self.number(object["id"]).map({ String(Int($0)) }) else {
                continue
            }
            authoredByID[id] = object
        }
        var materials: [MaterialKey: WPEParityProgramMaterial] = [:]
        var overridePasses: [MaterialKey: Int] = [:]
        var resolvedEffectRecords: [WPEParitySceneState.EffectKey: [WPEParityEffectPassRecord]] = [:]
        var resolvedMaterialFunctions: [WPEParitySceneState.EffectKey: WPEParityMaterialFunctions] = [:]
        var layerColors: [String: SIMD4<Float>] = [:]
        var puppetModels: [String: WPEPuppetModel] = [:]
        var authoredObjects: [WPEParityAuthoredObject] = []
        var sceneObjects: [WPEParitySceneObject] = []
        var models: [String: WPEPuppetModel] = [:]
        for (index, image) in document.imageObjects.enumerated() {
            let isModel = image.imageRelativePath.lowercased().hasSuffix(".mdl")
            let modelFile = isModel
                ? assets.data(image.imageRelativePath).flatMap { try? WPEMdlParser.parse(data: $0) } : nil
            if !isModel {
                // FUN_1402222a0 draws models with g_Color4 = 1.
                let color = SIMD3<Float>(image.color) * (flags.hdr ? Float(image.brightness) : 1)
                layerColors[image.id] = SIMD4(color.x, color.y, color.z,
                                              WPEParitySceneState.nativeAlpha(image, authored: authoredByID[image.id]))
            }
            models[image.id] = modelFile
            let model = isModel ? nil : assets.json(image.imageRelativePath)
            let materialPath = isModel
                ? modelFile?.meshes.first?.materialPath
                : Self.string(model?["material"]) ?? image.materialRelativePath
            let albedoSource = materialPath.map { WPEParitySceneMaterialSource(materialPath: $0) }
            var material = materialPath.flatMap { WPEParityProgramMaterial(path: $0, assets: assets) }
            let authored = authoredByID[image.id]
            if let instance = image.materialInstance {
                // The instance merges over the pass JSON before annotation defaults fill missing keys (r3 Q1 J, Q4).
                material?.merge(combos: instance.combos, textures: instance.textures, constants: instance.constants,
                                userTextures: authored?["instance"]?["usertextures"],
                                userTextureBindings: instance.userTextures)
            }
            if let albedoSource, let material {
                materials[MaterialKey(objectID: image.id, effectID: nil, source: albedoSource)] = material
            }
            let fullscreen = Self.flag(model?["fullscreen"])
            // 140209360.c:26-49: an autosize model, not a projectlayer, takes its albedo's TEXI image size; a missing
            // or "error" albedo is the 6×6 placeholder (1400ec220.c:164-165, 223-226). A sprite sheet (TEXI flags & 4)
            // would take its TEXS frame size, which the package does not parse, so it keeps the authored size.
            let albedo = !fullscreen && Self.flag(model?["autosize"]) && !Self.flag(model?["projectlayer"])
                ? material?.textures[0].flatMap { $0.hasPrefix("_rt_") ? nil : $0 } : nil
            let albedoSize: SIMD2<Int>? = albedo.flatMap { name in
                name == "error" || assets.data("materials/\(name).tex") == nil ? SIMD2(6, 6)
                    : assets.textureHeader(named: name).flatMap {
                        $0.flags & 4 != 0 ? nil : SIMD2(Int($0.imageWidth), Int($0.imageHeight))
                    }
            }
            imageSizes[image.id] = albedoSize.map { SIMD2<Float>($0) }
            // catsout WPSceneParser.cpp binds a fullscreen layer's FBOs to the screen.
            let objectWidth = fullscreen ? width
                : albedoSize?.x ?? image.size.map { Int($0.width.rounded()) } ?? width
            let objectHeight = fullscreen ? height
                : albedoSize?.y ?? image.size.map { Int($0.height.rounded()) } ?? height
            let effects = Self.effects(isModel ? [] : image.effects, objectID: image.id, assets: assets,
                                       engineFlags: flags, materials: &materials, overridePasses: &overridePasses,
                                       records: &resolvedEffectRecords, functions: &resolvedMaterialFunctions, authored: authored)
            authoredObjects.append(WPEParityAuthoredObject(id: image.id, width: objectWidth, height: objectHeight,
                                                           effects: effects))
            let loadedPuppet = Self.string(model?["puppet"]).flatMap { Self.puppet($0, assets: assets) }
            var puppet = loadedPuppet?.puppet
            puppet?.albedoTexture = material?.textures[0]
            puppetModels[image.id] = loadedPuppet?.model
            // FUN_14020ae00: the albedo's TEXI flags are Texture+0x1c, where bit2 marks a sequence. A bit4 already
            // set by blend mode, ledsource or fog needs nothing here.
            let sequence = material?.textures[0].flatMap(assets.textureHeader(named:)).map { $0.flags & 4 != 0 }
            let puppetForcesComposite = puppet.map {
                !effects.isEmpty || sequence == true || $0.blendMeshIndex != nil
            } ?? false
            let baseBlend = material.map { WPEParitySceneBlend($0.blending) } ?? .translucent
            // A model's state comes from its material alone.
            let blend: WPEParitySceneBlend = image.colorBlendMode == 31 && !isModel ? .additive : baseBlend
            var kind = WPEParitySceneObject.Kind.image
            var frameReads: [String: [WPEResourceID]] = [:]
            if let materialPath, let material {
                frameReads[materialPath] = WPEParityAuthoredPass.frameReads(
                    WPEParityProgramBuilder.resolvedFrameTextureNames(material, engineFlags: flags, assets: assets)
                )
            }
            if image.isShapeQuad {
                kind = .shape(WPEParitySceneShape(points: Self.shapePoints(effects.first, objectID: image.id,
                                                                           materials: materials, assets: assets)))
            }
            if isModel {
                var meshes: [WPEParitySceneModelMesh] = []
                for (meshIndex, mesh) in (modelFile?.meshes ?? []).enumerated() {
                    let source = WPEParitySceneMaterialSource(materialPath: mesh.materialPath)
                    let meshMaterial = meshIndex == 0 ? material
                        : WPEParityProgramMaterial(path: mesh.materialPath, assets: assets)
                    if let meshMaterial {
                        materials[MaterialKey(objectID: image.id, effectID: nil, source: source)] = meshMaterial
                        frameReads[mesh.materialPath] = WPEParityAuthoredPass.frameReads(
                            WPEParityProgramBuilder.resolvedFrameTextureNames(meshMaterial, engineFlags: flags,
                                                                              assets: assets)
                        )
                    }
                    meshes.append(WPEParitySceneModelMesh(
                        material: meshMaterial == nil ? nil : source,
                        shader: meshMaterial?.shader ?? "generic4",
                        blend: meshMaterial.map { WPEParitySceneBlend($0.blending) } ?? .normal,
                        materialState: Self.materialState(assets.json(mesh.materialPath)?["passes"]?[0])
                    ))
                }
                kind = .model(WPEParitySceneModel(
                    meshes: meshes, castsShadow: Self.number(authored?["castshadow"]).map { $0 != 0 } ?? true
                ))
            }
            let passthrough = Self.flag(model?["passthrough"]) || image.config.passthrough
            // 1401fac50.c:267-279: base material blend, not the mode-31 override; shapes never join. A loaded model
            // joins unless a sub-mesh blends normal or A2C (140224c70.c:61, 258-262).
            let transparentMember = switch kind {
            case .image:
                ![.normal, .alphaToCoverage].contains(baseBlend) || passthrough && !image.copyBackground
            case let .model(sceneModel):
                modelFile != nil && sceneModel.meshes.allSatisfy { ![.normal, .alphaToCoverage].contains($0.blend) }
            default:
                false
            }
            sceneObjects.append(WPEParitySceneObject(
                id: image.id, kind: kind, sortKey: document.objectPaintOrder[image.id] ?? index,
                visible: Self.visible(image.id, document), width: objectWidth, height: objectHeight,
                materialShader: material?.shader ?? "genericimage2", material: image.isShapeQuad ? nil : albedoSource,
                blend: blend,
                materialState: Self.materialState(materialPath.flatMap { assets.json($0)?["passes"]?[0] }),
                materialFog: material.map { Self.programHasFog($0, assets: assets) } ?? false,
                // The parser gives a point-quad shape colorBlendMode 9; WPE keeps the authored key, which a shape's
                // draws never read.
                colorBlendMode: image.isShapeQuad ? Self.number(authored?["colorBlendMode"]).map { Int($0) } ?? 0
                    : image.colorBlendMode,
                passthrough: passthrough,
                copyBackground: image.copyBackground, fullscreen: fullscreen,
                ledSource: Self.flag(authored?["ledsource"]), puppetForcesComposite: puppetForcesComposite,
                puppet: puppet,
                noInterpolation: Self.flag(authored?["nointerpolation"]),
                clampUVs: Self.number(authored?["clampuvs"]).map { $0 != 0 } ?? true,
                parentID: image.parentObjectID,
                // Only object types 1 and 4, image and text, take the flags.
                dependencyTarget: kind == .image && dependencyTargets.contains(image.id),
                materialFrameReads: frameReads, transparentMember: transparentMember
            ))
        }
        // Text layers come next so `authoredObjects` still lines up with the leading scene objects.
        var diagnostics: [WPEParitySceneDiagnostic] = []
        let texts = WPEParityTextObject.textObjects(in: document)
        var textAtlases: [String: WPEParityGlyphAtlasInstance] = [:]
        var textFailure: WPEParityTextPreparationError?
        do {
            try WPEParityTextFieldAdmission.validate(texts)
        } catch {
            textFailure = error as? WPEParityTextPreparationError ?? .unqualifiedDistanceFieldGroup
        }
        if !texts.isEmpty, textFailure == nil {
            let pipeline = WPEParityTextPipeline(assets: assets, hdr: flags.hdr,
                                                 orthographic: flags.orthographicProjection)
            let schemas = Dictionary(document.textObjects.map { ($0.id, $0) }) { first, _ in first }
            let first = sceneObjects.count
            for (index, text) in texts.enumerated() {
                let schema = schemas[text.id]
                let effects = Self.effects(schema?.effects ?? [], objectID: text.id, assets: assets,
                                           engineFlags: flags, materials: &materials, overridePasses: &overridePasses,
                                           records: &resolvedEffectRecords, functions: &resolvedMaterialFunctions,
                                           authored: authoredByID[text.id])
                do {
                    try pipeline.add(text, effectCount: effects.count(where: \.enabled),
                                     glyphMode: WPEParityTextFieldAdmission.mode(for: text))
                } catch {
                    textFailure = error as? WPEParityTextPreparationError ?? .unqualifiedDistanceFieldGroup
                    break
                }
                guard let sceneText = pipeline.texts[text.id] else { continue }
                let color = text.color * (flags.hdr ? text.brightness : 1)
                layerColors[text.id] = SIMD4(color, text.alpha)
                authoredObjects.append(WPEParityAuthoredObject(id: text.id, width: sceneText.layout.fboSize.x,
                                                               height: sceneText.layout.fboSize.y, effects: effects))
                sceneObjects.append(.text(sceneText, sortKey: document.objectPaintOrder[text.id] ?? index,
                                          visible: Self.visible(text.id, document), parentID: schema?.parentObjectID))
                sceneObjects[sceneObjects.count - 1].dependencyTarget = dependencyTargets.contains(text.id)
            }
            pipeline.refreshUVs()
            for index in first ..< sceneObjects.count {
                guard let text = pipeline.texts[sceneObjects[index].id] else { continue }
                sceneObjects[index].kind = .text(text)
            }
            textAtlases = pipeline.atlases
        }
        self.textAtlases = textAtlases
        textPreparationFailure = textFailure
        let scope = WPEParitySceneFBOScope(authoredObjects, backbufferFormat: format)
        for index in sceneObjects.indices {
            sceneObjects[index].effects = scope.effects(of: authoredObjects[index], diagnostics: &diagnostics)
        }
        for (index, particle) in document.particleObjects.enumerated() {
            let draws = Self.particleDraws(objectID: particle.id, path: particle.particleRelativePath, assets: assets,
                                           diagnostics: &diagnostics)
            sceneObjects.append(WPEParitySceneObject(
                id: particle.id, kind: .particle(WPEParitySceneParticle(draws: draws)),
                sortKey: document.objectPaintOrder[particle.id] ?? index, visible: Self.visible(particle.id, document),
                width: 0, height: 0, parentID: particle.parentObjectID, transparentMember: true
            ))
        }
        // Groups are not scene objects; WPE's passthrough container walks through them (1401ecb20.c:150-163, 1401eca70.c:10-17).
        let ids = Set(sceneObjects.map(\.id))
        for index in sceneObjects.indices {
            var seen: Set<String> = [sceneObjects[index].id]
            var parent = document.objectParentByID[sceneObjects[index].id]
            while let id = parent, !ids.contains(id), seen.insert(id).inserted {
                parent = document.objectParentByID[id]
            }
            sceneObjects[index].parentID = parent.flatMap { ids.contains($0) ? $0 : nil }
        }
        self.materials = materials
        self.overridePasses = overridePasses
        self.resolvedEffectRecords = resolvedEffectRecords
        self.resolvedMaterialFunctions = resolvedMaterialFunctions
        self.layerColors = layerColors
        self.puppetModels = puppetModels
        self.models = models
        self.authoredObjects = authoredObjects
        scene = WPEParitySceneDescription(width: width, height: height, backbufferFormat: format,
                                          clearColor: document.general.clearColor,
                                          clearEnabled: document.general.clearEnabled.resolvedValue,
                                          msaaSamples: samples,
                                          // (e0 & 0x1008) == 0x1000 (14018aac0.c:169): bit 0x8, orthographic, never sorts.
                                          transparentSorting: Self.authoredBool(document, "transparentsorting")
                                              && !flags.orthographicProjection,
                                          forcesLayerComposite: flags.fogDistance || flags.fogHeight,
                                          shadowAtlas: flags.shadowQuality != 0 && [
                                              flags.spotShadowCookieLights, flags.spotShadowLights,
                                              flags.directionalShadowLights, flags.pointShadowLights,
                                          ].contains { $0 != 0 },
                                          objects: sceneObjects, diagnostics: diagnostics)
        let cameraPaths = WPEParityCameraPaths(camera: document.sourceJSON["camera"], assets: assets)
        self.cameraPaths = cameraPaths
        // camerafade is e0 bit2, on from 0x26; fade.json loads only with camera paths (140181af0.c:37-42).
        let cameraFade = bloomGeneral["camerafade"].map { Self.flag($0) } ?? true
        var post = WPEParityPostProcessConfig(sceneBloomEnabled: sceneBloom, userBloomEnabled: settings.bloom,
                                              objectTableNonEmpty: !objects.isEmpty, hdrEnabled: flags.hdr,
                                              displayHDREnabled: settings.displayHDR,
                                              maximumPotentialEDR: settings.maximumPotentialEDR,
                                              msaaSampleCount: samples,
                                              qualityMipMappedFrameBufferEnabled: settings.mipMappedFrameBufferEnabled,
                                              bloomSettings: Self.bloomSettings(bloomGeneral),
                                              colorCorrectionEnabled: settings.colorCorrection.drawn,
                                              fadeActive: cameraFade && !cameraPaths.paths.isEmpty,
                                              backbufferWidth: width, backbufferHeight: height,
                                              backbufferFormat: format)
        post.colorCorrection = settings.colorCorrection
        postProcess = post
    }

    /// The native HDR allocation predicate, also used before the product plans its physical render extent.
    public static func hdrEnabled(document: WPESceneDocument, settings: WPEParityProgramSettings) -> Bool {
        authoredBool(document, "bloom") && authoredBool(document, "hdr") && settings.hdrPostProcessing
    }

    /// 10df40 uses10d850: an object unwraps its immediate "value", then116b90 requires bool true.
    /// This load-time getter does not read the runtime user-property override used by bloom setters.
    private static func authoredBool(_ document: WPESceneDocument, _ key: String) -> Bool {
        let raw = document.sourceJSON["general"]?[key]
        let value = if case .object? = raw {
            raw?["value"]
        } else {
            raw
        }
        return value == .bool(true)
    }

    /// `scene` with each image and text layer effect enabled as `visible` says. FBO declarations follow the enabled set, as a
    /// load with that set gives them.
    public func scene(effectVisible visible: (_ objectID: String, _ effectID: String) -> Bool = { _, _ in true },
                      textSizes: [String: SIMD2<Int>] = [:], logicalViewport: SIMD2<Int>? = nil)
        -> WPEParitySceneDescription {
        var authored = authoredObjects
        for object in authored.indices {
            // Resize the declaration before the scope resolves foreign readers of a shared FBO.
            if scene.objects[object].fullscreen, let size = logicalViewport {
                authored[object].width = size.x
                authored[object].height = size.y
            } else if let size = textSizes[authored[object].id] {
                authored[object].width = size.x
                authored[object].height = size.y
            }
            for effect in authored[object].effects.indices {
                authored[object].effects[effect].enabled = visible(authored[object].id,
                                                                   authored[object].effects[effect].id)
            }
        }
        let scope = WPEParitySceneFBOScope(authored, backbufferFormat: scene.backbufferFormat)
        var description = scene
        if let logicalViewport {
            (description.width, description.height) = (logicalViewport.x, logicalViewport.y)
        }
        var diagnostics: [WPEParitySceneDiagnostic] = []
        for index in authored.indices {
            description.objects[index].width = authored[index].width
            description.objects[index].height = authored[index].height
            description.objects[index].effects = scope.effects(of: authored[index], diagnostics: &diagnostics)
        }
        return description
    }

    /// Each text layer's FBO size, the size its transform draws the final composite with.
    public var textSizes: [String: SIMD2<Float>] {
        var sizes: [String: SIMD2<Float>] = [:]
        for object in scene.objects {
            guard case let .text(text) = object.kind else { continue }
            sizes[object.id] = SIMD2(Float(text.layout.fboSize.x), Float(text.layout.fboSize.y))
        }
        return sizes
    }

    /// Each image layer whose size its albedo gives (140209360.c:26-49): the placeholder's 6×6 or the TEXI image size.
    public private(set) var imageSizes: [String: SIMD2<Float>] = [:]

    /// Loads each effect file and records the merged material of every pass under `objectID`.
    private static func effects(_ effects: [WPESceneImageEffect], objectID: String, assets: WPEParityProgramAssets,
                                engineFlags: WPEEngineComboFlags,
                                materials: inout [MaterialKey: WPEParityProgramMaterial],
                                overridePasses: inout [MaterialKey: Int],
                                records: inout [WPEParitySceneState.EffectKey: [WPEParityEffectPassRecord]],
                                functions: inout [WPEParitySceneState.EffectKey: WPEParityMaterialFunctions],
                                authored: WPESceneJSONValue? = nil) -> [WPEParityAuthoredEffect] {
        var loaded: [WPEParityAuthoredEffect] = []
        for effect in effects {
            guard let file = assets.json(effect.fileRelativePath) else { continue }
            let configuration = Self.array(authored?["effects"]).enumerated().first { index, value in
                (Self.string(value["id"]) ?? Self.number(value["id"]).map { String(Int($0)) } ?? "\(index)") == effect.id
            }?.element
            let result = Self.effect(effect, objectID: objectID, file: file, assets: assets, engineFlags: engineFlags,
                                     combos: configuration?["combos"], userTextureConfiguration: configuration)
            records[.init(objectID: objectID, effectID: effect.id)] = result.records
            functions[.init(objectID: objectID, effectID: effect.id)] = result.effect.materialFunctions
            loaded.append(result.effect)
            for (source, material, pass) in result.materials {
                let key = MaterialKey(objectID: objectID, effectID: effect.id, source: source)
                materials[key] = material
                overridePasses[key] = pass
            }
        }
        return loaded
    }

    /// Only authored keys override WPE's defaults, after user-property resolution (1401730d0.c:35-49).
    static func bloomSettings(_ general: WPESceneJSONValue) -> WPEParityBloomSettings {
        var settings = WPEParityBloomSettings()
        settings.strength = WPEParityScriptProperty.sceneFloatValue(fromJSON: general["bloomstrength"]) ?? settings.strength
        settings.threshold = WPEParityScriptProperty.sceneFloatValue(fromJSON: general["bloomthreshold"]) ?? settings.threshold
        settings.hdrStrength = WPEParityScriptProperty.sceneFloatValue(fromJSON: general["bloomhdrstrength"]) ?? settings.hdrStrength
        settings.hdrThreshold = WPEParityScriptProperty.sceneFloatValue(fromJSON: general["bloomhdrthreshold"]) ?? settings.hdrThreshold
        settings.hdrFeather = WPEParityScriptProperty.sceneFloatValue(fromJSON: general["bloomhdrfeather"]) ?? settings.hdrFeather
        settings.hdrScatter = WPEParityScriptProperty.sceneFloatValue(fromJSON: general["bloomhdrscatter"]) ?? settings.hdrScatter
        settings.hdrIterations = WPEParityScriptProperty.bloomIterationsValue(fromJSON: general["bloomhdriterations"])
            .map(Int.init) ?? settings.hdrIterations
        settings.tint = WPEParityScriptProperty.bloomTintValue(fromJSON: general["bloomtint"]) ?? settings.tint
        return settings
    }

    /// Maps each created layer to its template for the material and colour lookups below.
    public mutating func adoptCreatedLayers(_ templates: [String: String]) {
        createdTemplates = templates
        for (id, template) in templates {
            layerColors[id] = layerColors[template]
        }
    }

    /// The merged pass JSON `draw` uses; an engine (util) material is read from its file with the engine's combos.
    func material(for draw: WPEParitySceneDraw) -> WPEParityProgramMaterial? {
        guard let source = draw.source else { return nil }
        var stored = source
        (stored.combos, stored.textures) = ([:], [:])
        let objectID = createdTemplates[draw.objectID] ?? draw.objectID
        var material = materials[MaterialKey(objectID: objectID, effectID: draw.effectID, source: stored)]
            ?? WPEParityProgramMaterial(path: source.materialPath, pass: source.materialPass, assets: assets)
        material?.merge(combos: source.combos, textures: source.textures)
        if let shader = source.shader {
            material?.shader = shader
        }
        return material
    }

    /// Script ModelData uses the same first material pass, blend and depth/cull parsing as file model meshes.
    public func modelDataMesh(materialPath: String) -> WPEParitySceneModelMesh? {
        guard let material = WPEParityProgramMaterial(path: materialPath, assets: assets) else { return nil }
        return WPEParitySceneModelMesh(
            material: .init(materialPath: materialPath), shader: material.shader,
            blend: WPEParitySceneBlend(material.blending),
            materialState: Self.materialState(assets.json(materialPath)?["passes"]?[0])
        )
    }

    public func modelDataFrameReads(materialPath: String) -> [WPEResourceID] {
        guard let material = WPEParityProgramMaterial(path: materialPath, assets: assets) else { return [] }
        return WPEParityAuthoredPass.frameReads(
            WPEParityProgramBuilder.resolvedFrameTextureNames(material, engineFlags: engineFlags, assets: assets)
        )
    }

    /// The scene material pass whose constants `draw` uses; nil for engine materials, which the scene cannot set.
    func passKey(for draw: WPEParitySceneDraw) -> WPEParityMaterialPassKey? {
        guard var stored = draw.source else { return nil }
        (stored.combos, stored.textures) = ([:], [:])
        let key = MaterialKey(objectID: createdTemplates[draw.objectID] ?? draw.objectID, effectID: draw.effectID,
                              source: stored)
        guard materials[key] != nil else { return nil }
        return WPEParityMaterialPassKey(objectID: draw.objectID, effectID: draw.effectID, pass: overridePasses[key] ?? 0)
    }

    /// A post-process draw's material file, or its own name as the shader when the file is missing, with the
    /// draw's combos and asset textures.
    func engineMaterial(_ draw: WPEParityPostProcessDraw) -> WPEParityProgramMaterial {
        var material = WPEParityProgramMaterial(path: draw.material, assets: assets)
            ?? WPEParityProgramMaterial(shader: draw.shader)
        material.combos.merge(draw.combos) { $1 }
        material.textures.merge(draw.textures) { $1 }
        return material
    }

    /// 0x14020744c: the material's own combos, shader defaults included, decide whether its composite keeps FOG.
    private static func programHasFog(_ material: WPEParityProgramMaterial, assets: WPEParityProgramAssets) -> Bool {
        let description = WPEParityProgramDescription(material: material, engineFlags: WPEEngineComboFlags(),
                                                      boundTextures: [:])
        let defines = WPEComboResolver.resolve(passJSONCombos: description.passJSONCombos,
                                               blendingMode: Int32(material.blending.rawValue),
                                               annotations: assets.shaderDeclarations(material.shader).annotations,
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

    /// 140260190.c:80-166: the first effect's first material pass, enabled or not, gives the points when its program
    /// declares all four material keys; a key the material does not set holds its annotation default.
    private static func shapePoints(_ effect: WPEParityAuthoredEffect?, objectID: String,
                                    materials: [MaterialKey: WPEParityProgramMaterial],
                                    assets: WPEParityProgramAssets) -> [SIMD2<Float>]? {
        guard let effect, let source = effect.passes.first(where: { $0.source != nil })?.source,
              let material = materials[MaterialKey(objectID: objectID, effectID: effect.id, source: source)]
        else { return nil }
        let declarations = assets.shaderDeclarations(material.shader)
        let uniforms = [WPEHLSLStage.vertex, .fragment].flatMap { (declarations.uniforms[$0] ?? [:]).values }
        var points: [SIMD2<Float>] = []
        for index in 0 ..< 4 {
            let key = "point\(index)"
            guard let uniform = uniforms.first(where: { $0.material == key }),
                  let value = material.constants[key] ?? uniform.defaultValue, value.count >= 2
            else { return nil }
            points.append(SIMD2(Float(value[0]), Float(value[1])))
        }
        return points
    }

    /// Mesh0 of a model JSON `"puppet"` (FUN_1401fbae0); puppet+0x390 is the first mesh with flag bit 1.
    private static func puppet(_ path: String,
                               assets: WPEParityProgramAssets) -> (puppet: WPEParityScenePuppet, model: WPEPuppetModel)? {
        guard let data = assets.data(path), let model = try? WPEMdlParser.parse(data: data),
              let mesh = model.meshes.first else { return nil }
        let puppet = WPEParityScenePuppet(vertices: mesh.vertices, indices: WPEParityScenePuppet.indices(of: mesh),
                                          boneCount: model.bones.count,
                                          skinned: mesh.vertexFormat & 0x800000 != 0 && !model.bones.isEmpty,
                                          blendMeshIndex: model.meshes.firstIndex { $0.flags & 2 != 0 },
                                          parts: mesh.parts, clipGroups: WPEParityPuppetClipGroup.groups(of: mesh),
                                          vertexStream: mesh.vertexStream, skinningAlpha: mesh.flags & 4 != 0)
        return (puppet, model)
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

    private static func effect(_ effect: WPESceneImageEffect, objectID: String,
                               file: WPESceneJSONValue, assets: WPEParityProgramAssets,
                               engineFlags: WPEEngineComboFlags, combos: WPESceneJSONValue?, userTextureConfiguration: WPESceneJSONValue?)
        -> (effect: WPEParityAuthoredEffect,
            materials: [(WPEParitySceneMaterialSource, WPEParityProgramMaterial, pass: Int)],
            records: [WPEParityEffectPassRecord]) {
        let filePasses = array(file["passes"])
        var swapPartners: [String: String] = [:]
        for pass in filePasses where string(pass["command"]) == "swap"
            && WPEParityAuthoredFBO.conditionsMatch(pass["conditions"], combos: combos) {
            guard let first = string(pass["source"]), let second = string(pass["target"]) else { continue }
            swapPartners[first] = second
            swapPartners[second] = first
        }
        var fbos: [WPEParityAuthoredFBO] = []
        for case let .object(fbo) in array(file["fbos"]) {
            guard WPEParityAuthoredFBO.conditionsMatch(fbo["conditions"], combos: combos) else { continue }
            guard let name = string(fbo["name"]), let format = string(fbo["format"]) else { continue }
            let clear = fboClear(fbo["clear"])
            fbos.append(WPEParityAuthoredFBO(name: name, scale: jsonNumber(fbo["scale"]) ?? 1, fit: jsonNumber(fbo["fit"]),
                                             format: format,
                                             swapPartner: swapPartners[name],
                                             unique: fbo["unique"] == .bool(true),
                                             explicitWidth: jsonNumber(fbo["width"]), explicitHeight: jsonNumber(fbo["height"]),
                                             initialClear: clear.initial, scriptClear: clear.stored, repeats: string(fbo["uvs"]) == "repeat"))
        }
        var passes: [WPEParityAuthoredPass] = []
        var materials: [(WPEParitySceneMaterialSource, WPEParityProgramMaterial, pass: Int)] = []
        var records: [WPEParityEffectPassRecord] = []
        for (passIndex, pass) in filePasses.enumerated() {
            guard WPEParityAuthoredFBO.conditionsMatch(pass["conditions"], combos: combos) else { continue }
            // 1401e7170:434-447,673-679: every accepted file pass enters the native 0x30-byte record array;
            // scene overrides still use the original file index, including commands and rejected conditions.
            let recordIndex = records.count
            // Native reads material before command (1401e7170:449–476), even when the draw consumer is unavailable.
            let path = string(pass["material"])
            records.append(.init(filePassIndex: passIndex, materialPass: nil, materialPath: path))
            if let command = string(pass["command"]) {
                if command == "swap", let first = string(pass["source"]), let second = string(pass["target"]) {
                    passes.append(WPEParityAuthoredPass(kind: .swap(first: first, second: second),
                                                        shader: "commands/swap", target: nil, textures: [],
                                                        compose: false, blend: .normal, source: nil))
                } else if command == "copy" {
                    let source = string(pass["source"]).flatMap { $0 == "previous" ? nil : $0 }
                    passes.append(WPEParityAuthoredPass(kind: .copy(source: source), shader: "commands/copy",
                                                        target: string(pass["target"]), textures: [], compose: false,
                                                        blend: .normal, source: nil))
                }
                continue
            }
            guard let path,
                  var material = WPEParityProgramMaterial(path: path, assets: assets) else { continue }
            if passIndex < effect.passOverrides.count {
                let override = effect.passOverrides[passIndex]
                material.merge(combos: override.combos, textures: override.textures, constants: override.constants,
                               userTextures: userTextureConfiguration?["passes"]?[passIndex]?["usertextures"],
                               userTextureBindings: override.userTextures)
            }
            for case let .object(bind) in array(pass["bind"]) {
                guard WPEParityAuthoredFBO.conditionsMatch(bind["conditions"], combos: combos) else { continue }
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
                textures: WPEParityProgramBuilder.resolvedFrameTextureNames(material, engineFlags: engineFlags,
                                                                            assets: assets),
                compose: pass["compose"] == .bool(true), blend: WPEParitySceneBlend(material.blending), source: source,
                materialState: Self.materialState(assets.json(path)?["passes"]?[0])
            ))
            materials.append((source, material, passIndex))
            records[recordIndex] = .init(filePassIndex: passIndex,
                                         materialPass: .init(objectID: objectID, effectID: effect.id, pass: passIndex),
                                         materialPath: path)
        }
        let targets = fbos.map { WPEParityMaterialFunctions.Target(name: $0.name, clearColor: $0.scriptClear) }
        var functions: [WPEParityMaterialFunctions.Function] = []
        if case let .object(entries)? = file["functions"] {
            for (name, value) in entries where !name.isEmpty {
                guard case .object = value, case let .string(action)? = value["action"],
                      action.utf8.elementsEqual("clear".utf8), case let .array(names)? = value["fbos"] else { continue }
                let count = names.reduce(0) { count, value in
                    guard case let .string(name) = value, !name.isEmpty,
                          targets.contains(where: { $0.name.utf8.elementsEqual(name.utf8) }) else { return count }
                    return count + 1
                }
                if count > 0 {
                    functions.append(.init(name: name, clearCount: count))
                }
            }
        }
        let metadata = WPEParityMaterialFunctions(functions: functions, targets: targets)
        return (WPEParityAuthoredEffect(id: effect.id, enabled: effect.visible, fbos: fbos, passes: passes,
                                        materialFunctions: metadata), materials, records)
    }

    /// A bare JSON number; unlike `number`, an object's `value` does not count.
    static func jsonNumber(_ value: WPESceneJSONValue?) -> Double? {
        guard case let .number(number)? = value else { return nil }
        return number
    }

    /// 1401e7170:245-324: atof writes each channel before checking its following ASCII-space separator.
    /// Partial strings retain written channels even though only a complete (or empty) string enables initial clear.
    private static func fboClear(_ value: WPESceneJSONValue?) -> (stored: WPEClearColor, initial: WPEClearColor?) {
        let zero = WPEClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard case let .string(text)? = value else { return (zero, nil) }
        return text.withCString { start in
            if start.pointee == 0 {
                return (zero, zero)
            }
            var cursor = start
            var channels = [Double](repeating: 0, count: 4)
            var complete = true
            for index in 0 ..< 4 {
                channels[index] = Double(Float(atof(cursor)))
                if index < 3 {
                    while cursor.pointee != 0, cursor.pointee != 32 {
                        cursor += 1
                    }
                    guard cursor.pointee != 0 else {
                        complete = false
                        break
                    }
                    while cursor.pointee == 32 {
                        cursor += 1
                    }
                }
            }
            let stored = WPEClearColor(red: channels[0], green: channels[1], blue: channels[2], alpha: channels[3])
            return (stored, complete ? stored : nil)
        }
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
        let members = scene.scene.objects.filter(\.transparentMember)
        self.init(document: document, hdr: scene.engineFlags.hdr, constants: constants,
                  transparentMembers: Set(members.map(\.id)),
                  fullscreenMembers: Set(members.filter(\.fullscreen).map(\.id)))
    }
}

extension WPEParitySceneBlend {
    init(_ mode: WPEParityBlendMode) {
        switch mode {
        case .translucent: self = .translucent
        case .additive: self = .additive
        case .normal: self = .normal
        case .alphaToCoverage: self = .alphaToCoverage
        }
    }
}

extension WPEParityProgramMaterial {
    /// `passes[pass]` of a material file.
    init?(path: String, pass index: Int = 0, assets: WPEParityProgramAssets) {
        typealias Scene = WPEParityProgramScene
        guard let document = assets.json(path), let pass = document["passes"]?[index],
              let shader = Scene.string(pass["shader"]) else {
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
                constants[key] = WPEParityProgramConstants.components(value, userValues: assets.userValues)
            }
        }
        self.init(shader: shader, path: path, blending: Self.blendMode(Scene.string(pass["blending"])),
                  combos: combos, textures: textures, constants: constants,
                  cullsBackFaces: Scene.string(pass["cullmode"])?.lowercased() != "nocull",
                  userTextures: .init(material: document["usertextures"], pass: pass["usertextures"]))
        if case let .object(entries)? = pass["constantshadervalues"] {
            for (key, value) in entries {
                if case .string? = value["user"] {
                    userConstants[key] = value
                }
            }
        }
    }

    /// Texture names in slot order.
    var textureNames: [String] {
        textures.sorted { $0.key < $1.key }.map(\.value)
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
                        constants: [String: WPESceneShaderConstantValue] = [:],
                        userTextures: WPESceneJSONValue? = nil,
                        userTextureBindings: [WPESceneUserTextureBinding]? = nil) {
        for (key, value) in combos {
            self.combos[key] = Int32(truncatingIfNeeded: value)
        }
        for (slot, name) in textures {
            self.textures[Int32(slot)] = name
        }
        for (key, value) in constants {
            self.constants[key] = WPEParityProgramConstants.components(value)
            userConstants[key] = nil
        }
        if userTextures != nil || userTextureBindings?.isEmpty == false {
            self.userTextures = .init(material: self.userTextures.material, pass: self.userTextures.pass,
                                      override: userTextures, overrideBindings: userTextureBindings)
        }
    }
}
