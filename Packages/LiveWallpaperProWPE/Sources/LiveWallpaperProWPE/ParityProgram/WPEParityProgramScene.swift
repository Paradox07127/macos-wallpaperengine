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

/// A scene document turned into the parity frame inputs, keeping each pass's material so frame draws can be traced
/// back to the JSON their combos come from. The frame is composed with MSAA off.
public struct WPEParityProgramScene: Sendable {
    public let scene: WPEParitySceneDescription
    public let postProcess: WPEParityPostProcessConfig
    public let engineFlags: WPEEngineComboFlags
    public let assets: WPEParityProgramAssets
    let albedo: [String: WPEParityProgramMaterial]
    let colorBlendModes: [String: Int]
    /// `<object>/<effect>` → material of each converted pass, nil for a copy command.
    let effectPasses: [String: [WPEParityProgramMaterial?]]

    public init(document: WPESceneDocument, assets: WPEParityProgramAssets, settings: WPEParityProgramSettings) {
        let general = document.sourceJSON["general"]
        let objects: [WPESceneJSONValue] = if case let .array(values)? = document.sourceJSON["objects"] {
            values
        } else {
            []
        }
        var flags = WPEEngineComboFlags()
        // 140186c90.c:356-393
        if case .object? = general?["orthogonalprojection"], let ortho = general?["orthogonalprojection"] {
            flags.orthographicProjection = Self.flag(ortho["auto"]) || (Self.flag(ortho["width"]) && Self.flag(ortho["height"]))
        }
        let sceneBloom = Self.flag(general?["bloom"])
        // 14010df40.c:299-335, 365, 519-552
        flags.hdr = sceneBloom && Self.flag(general?["hdr"]) && settings.hdrPostProcessing
        flags.backbufferMSAA = settings.msaa && objects.contains { $0["model"] != nil }
        engineFlags = flags
        self.assets = assets

        let width = Int(document.general.orthogonalProjection.width.rounded())
        let height = Int(document.general.orthogonalProjection.height.rounded())
        let format = flags.hdr ? "rgba16float" : WPEParitySceneResource.colorFormat
        var albedo: [String: WPEParityProgramMaterial] = [:]
        var colorBlendModes: [String: Int] = [:]
        var effectPasses: [String: [WPEParityProgramMaterial?]] = [:]
        var sceneObjects: [WPEParitySceneObject] = []
        for (index, image) in document.imageObjects.enumerated() {
            let model = assets.json(image.imageRelativePath)
            let materialPath = Self.string(model?["material"]) ?? image.materialRelativePath
            var material = materialPath.flatMap { WPEParityProgramMaterial(path: $0, assets: assets) }
            if let instance = image.materialInstance {
                material?.merge(combos: instance.combos, textures: instance.textures)
            }
            albedo[image.id] = material
            colorBlendModes[image.id] = image.colorBlendMode
            let objectWidth = image.size.map { Int($0.width.rounded()) } ?? width
            let objectHeight = image.size.map { Int($0.height.rounded()) } ?? height
            var effects: [WPEParitySceneEffect] = []
            for effect in image.effects {
                guard let file = assets.json(effect.fileRelativePath) else { continue }
                let converted = Self.effect(effect, file: file, assets: assets, width: objectWidth,
                                            height: objectHeight, backbufferFormat: format)
                effects.append(converted.effect)
                effectPasses["\(image.id)/\(effect.id)"] = converted.materials
            }
            let blend: WPEParitySceneBlend = if image.colorBlendMode == 31 {
                .additive
            } else {
                material.map { WPEParitySceneBlend($0.blending) } ?? .translucent
            }
            sceneObjects.append(WPEParitySceneObject(
                id: image.id, sortKey: document.objectPaintOrder[image.id] ?? index,
                visible: Self.visible(image.id, document), width: objectWidth, height: objectHeight,
                materialShader: material?.shader ?? "genericimage2", blend: blend,
                colorBlendMode: image.colorBlendMode,
                passthrough: Self.flag(model?["passthrough"]) || image.config.passthrough,
                copyBackground: image.copyBackground, fullscreen: Self.flag(model?["fullscreen"]),
                parentID: image.parentObjectID, effects: effects
            ))
        }
        self.albedo = albedo
        self.colorBlendModes = colorBlendModes
        self.effectPasses = effectPasses
        scene = WPEParitySceneDescription(width: width, height: height, backbufferFormat: format,
                                          clearColor: document.general.clearColor,
                                          clearEnabled: document.general.clearEnabled.resolvedValue,
                                          objects: sceneObjects)
        postProcess = WPEParityPostProcessConfig(sceneBloomEnabled: sceneBloom, userBloomEnabled: settings.bloom,
                                                 objectTableNonEmpty: !objects.isEmpty, hdrEnabled: flags.hdr,
                                                 backbufferWidth: width, backbufferHeight: height,
                                                 backbufferFormat: format)
    }

    /// An engine draw uses `materials/util/<name>.json`; `combine_hdr` has no such file and names its shader.
    func engineMaterial(_ name: String) -> WPEParityProgramMaterial {
        WPEParityProgramMaterial(path: "materials/util/\(name).json", assets: assets)
            ?? WPEParityProgramMaterial(shader: name)
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

    private static func effect(_ effect: WPESceneImageEffect, file: WPESceneJSONValue, assets: WPEParityProgramAssets,
                               width: Int, height: Int, backbufferFormat: String)
        -> (effect: WPEParitySceneEffect, materials: [WPEParityProgramMaterial?]) {
        var fbos: [WPEParitySceneFBO] = []
        for case let .object(fbo) in array(file["fbos"]) {
            guard let name = string(fbo["name"]) else { continue }
            let scale = max(1, Int(number(fbo["scale"]) ?? 1))
            let format = string(fbo["format"]).map { $0 == "rgba_backbuffer" ? backbufferFormat : $0 }
            fbos.append(WPEParitySceneFBO(name: name, width: max(1, width / scale), height: max(1, height / scale),
                                          format: format.flatMap(metalFormat) ?? WPEParitySceneResource.colorFormat))
        }
        let declared = Set(fbos.map(\.name))
        var passes: [WPEParityScenePass] = []
        var materials: [WPEParityProgramMaterial?] = []
        var materialIndex = 0
        for pass in array(file["passes"]) {
            if let command = string(pass["command"]) {
                guard command == "copy", let target = string(pass["target"]), declared.contains(target) else { continue }
                let source = string(pass["source"])
                guard source == "previous" || source.map(declared.contains) == true else { continue }
                passes.append(WPEParityScenePass(shader: "commands/copy", target: target,
                                                 kind: .copy(source: source == "previous" ? nil : source)))
                materials.append(nil)
                continue
            }
            guard let path = string(pass["material"]),
                  var material = WPEParityProgramMaterial(path: path, assets: assets) else { continue }
            // Scene overrides line up with the effect's material passes.
            if materialIndex < effect.passOverrides.count {
                let override = effect.passOverrides[materialIndex]
                material.merge(combos: override.combos, textures: override.textures)
            }
            materialIndex += 1
            var binds: [String] = []
            for case let .object(bind) in array(pass["bind"]) {
                guard let name = string(bind["name"]), let index = number(bind["index"]) else { continue }
                material.textures[Int32(index)] = name
                if declared.contains(name), name != string(pass["target"]), !binds.contains(name) {
                    binds.append(name)
                }
            }
            if material.textures[0] == nil {
                material.textures[0] = "previous"
            }
            let target = string(pass["target"]).flatMap { declared.contains($0) ? $0 : nil }
            passes.append(WPEParityScenePass(
                shader: material.shader, target: target, binds: binds, compose: pass["compose"] == .bool(true),
                readsFullFrameBuffer: material.textures.values.contains(WPESceneAliasName.fullFrameBuffer),
                blend: WPEParitySceneBlend(material.blending)
            ))
            materials.append(material)
        }
        return (WPEParitySceneEffect(id: effect.id, enabled: effect.visible, passes: passes, fbos: fbos), materials)
    }

    private static func metalFormat(_ format: String) -> String? {
        switch format.lowercased() {
        case "rgba8888", "rgba8unorm": "rgba8unorm"
        case "rgba16f", "rgba_half", "rgba16161616f", "rgba16float": "rgba16float"
        case "r8", "r8unorm": "r8unorm"
        case "rg88": "rg8unorm"
        case "r16f": "r16float"
        case "rg1616f": "rg16float"
        default: nil
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

private extension WPEParitySceneBlend {
    init(_ mode: WPEParityBlendMode) {
        switch mode {
        case .translucent: self = .translucent
        case .additive: self = .additive
        case .normal, .alphaToCoverage: self = .normal
        }
    }
}

extension WPEParityProgramMaterial {
    /// `passes[0]` of a material file.
    init?(path: String, assets: WPEParityProgramAssets) {
        typealias Scene = WPEParityProgramScene
        guard let pass = assets.json(path)?["passes"]?[0], let shader = Scene.string(pass["shader"]) else {
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
        let blending: WPEParityBlendMode = switch Scene.string(pass["blending"])?.lowercased() {
        case "translucent": .translucent
        case "additive": .additive
        case "alphatocoverage": .alphaToCoverage
        default: .normal
        }
        self.init(shader: shader, path: path, blending: blending, combos: combos, textures: textures)
    }

    /// Scene instance or effect-pass override; null texture slots keep the base.
    mutating func merge(combos: [String: Int], textures: [Int: String]) {
        for (key, value) in combos {
            self.combos[key] = Int32(truncatingIfNeeded: value)
        }
        for (slot, name) in textures {
            self.textures[Int32(slot)] = name
        }
    }
}
