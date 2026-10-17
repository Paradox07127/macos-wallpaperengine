#if !LITE_BUILD
import CoreFoundation
import Foundation
import JavaScriptCore
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Admission into the existing canonical State and frame planner. This type owns no layers or model table.
enum WPEParityModelDataLayerAdmission {
    static func provider(
        plan: WPEParityFramePlan, device: MTLDevice,
        admitShape: @escaping (WPEParitySceneModelData.Shape, WPEParityModelDataMutation)
            throws -> (any WPEParityModelDataPreparedShape)?
    ) -> WPEParityScriptModelDataProvider {
        WPEParityScriptModelDataProvider(
            maximumArrayEntries: Int(UInt32.max), maximumBufferBytes: Int.max,
            maximumSingleBufferBytes: device.maxBufferLength,
            // Get-or-load by path with no registration lookup (14018c720.c:323-333).
            resolveMaterial: { value, _ in
                guard let path = value.toString() else {
                    throw WPEParityModelDataFailure.native(1)
                }
                // The complete native path composition contract remains separate.
                let bytes = Data(path.utf8)
                guard bytes.count <= 255, !bytes.contains(0), !path.contains("\\"), !path.contains("//") else {
                    throw WPEParityModelDataFailure.safety("material filename requires unqualified path conversion")
                }
                guard plan.scene.modelDataMesh(materialPath: path) != nil else {
                    throw WPEParityModelDataFailure.native(1)
                }
                return bytes
            },
            admitShape: admitShape
        )
    }

    /// The factory's class keys in 14018ff60.c:38-126 order: model > particle > image > sprite > text > light >
    /// sound > camera > shape > generic object.
    enum LayerClass: Equatable {
        case model, particle, image(String), sprite, text, light, sound, camera, shape, generic

        init(_ config: [String: Any]) {
            func string(_ key: String) -> String? {
                config[key] as? String
            }
            let model = config["model"]
            let numericModel = (model as? NSNumber).map { !WPEParityModelDataLayerAdmission.isBool($0) } ?? false
            if numericModel || model is String || model is [String: Any] {
                self = .model
            } else if string("particle") != nil {
                self = .particle
            } else if let image = string("image") {
                self = .image(image)
            } else if string("sprite") != nil {
                self = .sprite
            } else if config["text"] != nil {
                self = .text
            } else if string("light") != nil {
                self = .light
            } else if let sound = config["sound"], !(sound is NSNull) {
                self = .sound
            } else if string("camera") != nil {
                self = .camera
            } else {
                self = string("shape") != nil ? .shape : .generic
            }
        }
    }

    /// Image configs without effects load their model by path; image configs with effects clone a loaded template,
    /// whose class, puppet, video, child and dependency limits `removable` also checks. Numeric models keep the
    /// ModelData transaction; the other classes are not created at runtime yet.
    static func create(plan: WPEParityFramePlan, removable: @escaping (String, UInt32?) -> Bool)
        -> (String, inout WPEParitySceneState) -> WPEParityScriptEngine.CreatedLayer? {
        let templates = plan.document.imageObjects.filter { image in
            plan.scene.scene.objects.contains { $0.id == image.id && $0.kind == .image }
                && image.parentObjectID == nil && removable(image.id, nil)
        }
        return { json, state in
            // 14018ba00.c:37-42: a config that does not parse creates nothing.
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                Logger.warning("Layer admission: createLayer config is not a JSON object", category: .wpeRender)
                return nil
            }
            let layerClass = LayerClass(object)
            if layerClass == .model, object["model"] is NSNumber {
                return Self.create(json, state: &state)
            }
            guard case let .image(path) = layerClass else {
                Logger.warning("Layer admission: runtime creation of \(layerClass) layers is not supported yet",
                               category: .wpeRender)
                return nil
            }
            // 1401e7170.c:161, 441-464 rebuild each entry's descriptors and pass materials; only the template's
            // loaded effects have prepared materials here.
            guard let effects = (object["effects"] as? [Any]).flatMap({
                $0.isEmpty ? nil : WPESceneJSONValue(jsonValue: $0)
            }) else {
                return Self.loadImage(object, path: path, plan: plan, state: &state)
            }
            let name = object["name"] as? String
            guard let template = templates.first(where: { $0.imageRelativePath == path && $0.name == name })
                ?? templates.first(where: { $0.imageRelativePath == path }) else {
                Logger.warning("Image layer admission: no loaded template with effects qualifies for \(path)",
                               category: .wpeRender)
                return nil
            }
            let loaded = plan.document.resolvedObjectsJSON.first { entry in
                switch entry["id"] {
                case let .number(number)?: String(Int(number)) == template.id
                case let .string(id)?: id == template.id
                default: false
                }
            }
            guard loaded?["effects"] == effects else {
                Logger.warning("Image layer admission: effects differ from template \(template.id)", category: .wpeRender)
                return nil
            }
            return Self.admitImage(object) { id, configure in
                try state.appendImageLayer(cloning: template.id, id: id, adopting: plan.state, configure: configure)
            }
        }
    }

    /// The image branch loads the config's own model; fields the config omits keep the layer ctor's defaults.
    private static func loadImage(_ config: [String: Any], path: String, plan: WPEParityFramePlan,
                                  state: inout WPEParitySceneState) -> WPEParityScriptEngine.CreatedLayer? {
        let image = WPEParitySceneState.CreatedImage(model: path, config: config)
        guard let description = plan.scene.createdImageObject(id: "", image: image) else {
            Logger.warning("Image layer admission: image model \(path) is unavailable", category: .wpeRender)
            return nil
        }
        // Video decoders are built only at renderer init, so nothing would update this texture.
        guard !plan.scene.createdImageTextures(image).contains(where: {
            (plan.scene.assets.textureHeader(named: $0)?.flags ?? 0) & WPEParityFrameDrawPlanner.videoFlag != 0
        }) else {
            Logger.warning("Image layer admission: unsupported video texture in \(path)", category: .wpeRender)
            return nil
        }
        return Self.admitImage(config) { id, configure in
            try state.appendImageLayer(image, id: id, transparent: description.transparentMember,
                                       fullscreen: description.fullscreen, configure: configure)
        }
    }

    /// 14018ba00 parses the config before its factory; `append` adds the layer and applies the config's fields.
    private static func admitImage(
        _ config: [String: Any], append: (UInt64?, (inout WPEParitySceneState.Object) -> Void) throws -> UInt64
    ) -> WPEParityScriptEngine.CreatedLayer? {
        let unsupported = ["parent", "video"].filter { config[$0] != nil }
            + ["dependencies"].filter { (config[$0] as? [Any])?.isEmpty == false }
        guard unsupported.isEmpty else {
            Logger.warning("Image layer admission: unsupported \(unsupported)", category: .wpeRender)
            return nil
        }
        // 1401a38f0.c:21-41: only a nonzero numeric id is explicit.
        let explicitID = (config["id"] as? NSNumber).flatMap { number in
            isBool(number) ? nil : UInt64(exactly: number.doubleValue)
        }.flatMap { $0 > 0 ? $0 : nil }
        func value(_ key: String) -> Any? {
            let raw = config[key]
            return (raw as? [String: Any]).map { $0["value"] } ?? raw
        }
        do {
            let number = try append(explicitID) { object in
                if let origin = WPEValueParser.vector3(config["origin"]) {
                    object.origin = SIMD3(origin)
                }
                if let scale = WPEValueParser.vector3(config["scale"]) ?? WPEValueParser.double(value("scale")).map({
                    SIMD3(repeating: $0)
                }) {
                    object.scale = SIMD3(scale)
                }
                if let angles = WPEValueParser.vector3(config["angles"]) {
                    object.angles = SIMD3(angles)
                }
                if let color = WPEValueParser.vector3(config["color"]) {
                    object.color = SIMD3(color)
                }
                if let alpha = WPEValueParser.double(value("alpha")) {
                    object.alpha = Float(alpha)
                }
                if let brightness = WPEValueParser.double(value("brightness")) {
                    object.brightness = Float(brightness)
                }
                if let visible = WPEValueParser.bool(value("visible")) {
                    object.visible = visible
                }
            }
            var prepared = config
            prepared["id"] = NSNumber(value: number)
            let data = try JSONSerialization.data(withJSONObject: prepared)
            return String(bytes: data, encoding: .utf8).map { .init(id: String(number), configJSON: $0) }
        } catch {
            Logger.warning("Image layer admission: \(error)", category: .wpeRender)
            return nil
        }
    }

    /// Literal identity, TRS and perspective form the bounded warm model transaction. Other classes,
    /// parents/effects/placement and new scripted dependencies require their actual resource adoption first.
    static func create(_ json: String, state: inout WPEParitySceneState) -> WPEParityScriptEngine.CreatedLayer? {
        do {
            guard var config = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  Set(config.keys).isSubset(of: ["id", "name", "model", "origin", "scale", "angles", "visible",
                                                 "perspective"]),
                  config.values.allSatisfy(isLiteral),
                  config["perspective"].map({ ($0 as? NSNumber).map(isBool) == true }) ?? true else {
                throw WPEParityModelDataFailure.safety("dynamic model layer configuration is outside the admitted literal subset")
            }
            // 1401a38f0.c:21-41: only a nonzero numeric id is explicit; anything else takes the counter.
            let explicitID = (config["id"] as? NSNumber).flatMap { isBool($0) ? nil : UInt64(exactly: $0.doubleValue) }
                .flatMap { $0 > 0 ? $0 : nil }
            guard let id = UInt32(exactly: explicitID ?? state.automaticObjectID()) else {
                throw WPEParityModelDataFailure.safety("dynamic model layer requires a UInt32 id")
            }
            config["id"] = NSNumber(value: id)
            for field in ["origin", "angles"] {
                if let value = config[field], WPEValueParser.vector3(value) == nil {
                    throw WPEParityModelDataFailure.safety("dynamic model layer requires a literal \(field) vector")
                }
            }
            if let scale = config["scale"], WPEValueParser.vector3(scale) == nil, WPEValueParser.double(scale) == nil {
                throw WPEParityModelDataFailure.safety("dynamic model layer requires a literal scale")
            }
            guard let descriptor = WPESceneDocumentParser.parseModelDataLayerConfiguration(config),
                  descriptor.id == String(id), let model = state.modelData(descriptor.modelDataToken),
                  model.shapes.allSatisfy({ $0.prepared is WPEParityModelDataMetalShape }) else {
                throw WPEParityModelDataFailure.safety("numeric model has no prepared canonical shape consumer")
            }
            try state.appendModelDataLayer(descriptor)
            let prepared = try JSONSerialization.data(withJSONObject: config)
            return String(bytes: prepared, encoding: .utf8).map { .init(id: descriptor.id, configJSON: $0) }
        } catch {
            Logger.warning("ModelData layer admission: \(error)", category: .wpeRender)
            return nil
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isLiteral(_ value: Any) -> Bool {
        if value is [String: Any] {
            return false
        }
        if let array = value as? [Any] {
            return array.allSatisfy(isLiteral)
        }
        return true
    }
}
#endif
