/// User-property bindings of a parity scene and the live writes a change makes (R24 Q5 step 1). SceneScript
/// properties and event 4 are not run; a target the parity renderer does not update live asks for a reload.
public enum WPEParityUserProperties {
    /// The bloom constants WPE refreshes on the next frame (R24 Q5); the bloom switch, `hdr` and the HDR pyramid depth
    /// change the post-process chain and reload.
    private static let liveGeneralFields: Set = [
        "cameraparallaxdelay", "cameraparallaxmouseinfluence", "bloomstrength", "bloomthreshold", "bloomtint",
        "bloomhdrstrength", "bloomhdrthreshold", "bloomhdrfeather", "bloomhdrscatter",
    ]

    /// Text layer fields that only move glyphs, which a live re-layout redraws (the enum fields never bind).
    private static let liveTextFields: Set = [
        "text", "font", "pointsize", "padding", "spacing", "maxwidth", "maxrows", "limitwidth", "limitrows",
        "limituseellipsis", "blockalign",
    ]

    /// Every user property the scene JSON binds, with each target it reaches. Object fields of image layers, groups
    /// and particles, effect visibility and material constants of image layers, the layout fields of text layers, the
    /// per-frame parallax terms and the bloom constants are `.incremental`; anything else is `.reload`.
    public static func bindings(document: WPESceneDocument) -> [String: [WPEScenePropertyBinding]] {
        let layers = Set(WPEParityLayerTransform.layers(document: document).map(\.id))
        let images = Set(document.imageObjects.map(\.id))
        let particles = Set(document.particleObjects.map(\.id))
        let texts = Set(WPEParityTextObject.textObjects(in: document).map(\.id))
        let objects = WPEParityProgramScene.array(document.sourceJSON["objects"])
        var result: [String: [WPEScenePropertyBinding]] = [:]
        func target(_ path: [String], scripted: Bool) -> (WPEScenePropertyBindingTarget, WPEScenePropertyBindingKind,
                                                          Bool) {
            guard path.first == "objects", path.count > 2, let index = Int(path[1]), index < objects.count,
                  let id = WPEParitySceneAnimations.id(objects[index]) else {
                let name = path.dropFirst(path.first == "general" ? 1 : 0).joined(separator: ".")
                return (.generalField(name: name), .general, !scripted && liveGeneralFields.contains(name))
            }
            let field = Array(path.dropFirst(2))
            let reload = (WPEScenePropertyBindingTarget.objectResource(objectID: id, field: field.joined(separator: ".")),
                          WPEScenePropertyBindingKind.resource, false)
            guard !scripted else { return reload }
            if field.count == 1, let property = WPEParitySceneState.Property(rawValue: field[0]), layers.contains(id) {
                let owner: WPEScenePropertyBindingTarget = images.contains(id) ? .imageObject(id: id)
                    : particles.contains(id) ? .particleObject(id: id) : .groupObject(id: id)
                return switch property {
                case .visible: (owner, .visible, true)
                case .alpha: (owner, .alpha, true)
                case .color: (owner, .color, true)
                case .brightness: (owner, .brightness, true)
                case .origin, .scale, .angles: (.objectResource(objectID: id, field: field[0]), .resource, true)
                }
            }
            if texts.contains(id), field.count == 1, liveTextFields.contains(field[0]) {
                return (.textObject(id: id), .resource, true)
            }
            guard images.contains(id) else { return reload }
            if field.count == 3, field[0] == "instance", field[1] == "constantshadervalues" {
                return (.shaderUniform(objectID: id, effectID: nil, passID: nil, name: field[2]), .uniform, true)
            }
            guard field.count > 2, field[0] == "effects", let effect = Int(field[1]) else { return reload }
            let effectID = objects[index]["effects"]?[effect].flatMap(WPEParitySceneAnimations.id) ?? field[1]
            if field.count == 3, field[2] == "visible" {
                return (.imageEffect(objectID: id, effectID: effectID), .visible, true)
            }
            if field.count == 6, field[2] == "passes", field[4] == "constantshadervalues", let pass = Int(field[3]) {
                return (.shaderUniform(objectID: id, effectID: effectID, passID: pass, name: field[5]), .uniform, true)
            }
            return reload
        }
        func walk(_ value: WPESceneJSONValue, _ path: [String]) {
            switch value {
            case let .object(entries):
                if entries["value"] != nil, let (key, condition) = envelope(entries["user"]) {
                    let (bound, kind, live) = target(path, scripted: entries["script"] != nil)
                    result[key, default: []].append(WPEScenePropertyBinding(
                        propertyKey: key, target: bound, kind: kind, action: live ? .incremental : .reload,
                        condition: condition
                    ))
                }
                for (key, entry) in entries.sorted(by: { $0.key < $1.key }) {
                    walk(entry, path + [key])
                }
            case let .array(entries):
                for (index, entry) in entries.enumerated() {
                    walk(entry, path + [String(index)])
                }
            default:
                break
            }
        }
        walk(document.sourceJSON, [])
        return result
    }

    /// `{"user": K}` or `{"user": {"name": K, "condition": C}}`.
    private static func envelope(_ user: WPESceneJSONValue?) -> (key: String, condition: String?)? {
        if let key = WPEParityProgramScene.string(user), !key.isEmpty {
            return (key, nil)
        }
        guard let name = WPEParityProgramScene.string(user?["name"]), !name.isEmpty else { return nil }
        let condition = WPEParityProgramScene.string(user?["condition"])
            ?? WPEParityProgramScene.number(user?["condition"]).map { String($0) }
        return (name, condition)
    }
}

/// The state writes that take a running parity scene from one parse of its JSON to a parse with changed user values:
/// every object field, effect visible bit and material constant whose parsed value differs, and the camera parallax
/// terms and bloom constants read per frame.
public struct WPEParityUserPropertyUpdate: Sendable {
    public struct ObjectWrite: Sendable, Equatable {
        public let id: String
        public let property: WPEParitySceneState.Property
        public let value: SIMD4<Float>
    }

    public struct ConstantWrite: Sendable, Equatable {
        public let pass: WPEParityMaterialPassKey
        public let name: String
        public let constant: WPEParitySceneState.Constant
    }

    public struct EffectWrite: Sendable, Equatable {
        public let effect: WPEParitySceneState.EffectKey
        public let visible: Bool
    }

    public private(set) var objects: [ObjectWrite] = []
    public private(set) var effects: [EffectWrite] = []
    public private(set) var constants: [ConstantWrite] = []
    /// Text layers whose parsed fields differ, with their new fields.
    public private(set) var texts: [WPEParityTextObject] = []
    public let cameraParallax: WPESceneCameraParallaxSettings
    /// The new parse's bloom values, which the post-process draws read on the next frame.
    public let bloom: WPEParityBloomSettings

    /// Nil when the two parses do not hold the same objects and effects.
    public init?(from old: WPESceneDocument, to new: WPESceneDocument) {
        cameraParallax = new.general.cameraParallax
        bloom = WPEParityProgramScene.bloomSettings(new.resolvedGeneralJSON)
        let before = WPEParitySceneState(document: old, hdr: false)
        let after = WPEParitySceneState(document: new, hdr: false)
        guard before.ids == after.ids, before.effects == after.effects else { return nil }
        for id in after.ids {
            for property in WPEParitySceneState.Property.allCases {
                guard let value = after.value(property, of: id), value != before.value(property, of: id) else {
                    continue
                }
                objects.append(ObjectWrite(id: id, property: property, value: value))
            }
        }
        for (index, effect) in after.effects.enumerated()
            where after.effectVisibility[index] != before.effectVisibility[index] {
            effects.append(EffectWrite(effect: effect, visible: after.effectVisibility[index]))
        }
        let earlierTexts = Dictionary(WPEParityTextObject.textObjects(in: old).map { ($0.id, $0) }) { first, _ in first }
        for text in WPEParityTextObject.textObjects(in: new) where earlierTexts[text.id] != text {
            guard earlierTexts[text.id] != nil else { return nil }
            texts.append(text)
        }
        let previous = Dictionary(old.imageObjects.map { ($0.id, $0) }) { first, _ in first }
        for image in new.imageObjects {
            guard let earlier = previous[image.id], earlier.effects.map(\.id) == image.effects.map(\.id) else {
                return nil
            }
            diff(earlier.materialInstance?.constants ?? [:], image.materialInstance?.constants ?? [:],
                 pass: WPEParityMaterialPassKey(objectID: image.id))
            for (effect, earlierEffect) in zip(image.effects, earlier.effects) {
                for (pass, override) in effect.passOverrides.enumerated()
                    where pass < earlierEffect.passOverrides.count {
                    diff(earlierEffect.passOverrides[pass].constants, override.constants,
                         pass: WPEParityMaterialPassKey(objectID: image.id, effectID: effect.id, pass: pass))
                }
            }
        }
    }

    public func apply(to state: inout WPEParitySceneState) {
        for write in objects {
            state.set(write.property, of: write.id, to: write.value)
        }
        for write in effects {
            state.setEffect(write.effect.effectID, of: write.effect.objectID, visible: write.visible)
        }
        for write in constants {
            state.setConstant(write.name, of: write.pass, to: write.constant)
        }
    }

    private mutating func diff(_ old: [String: WPESceneShaderConstantValue],
                               _ new: [String: WPESceneShaderConstantValue], pass: WPEParityMaterialPassKey) {
        for (name, value) in new.sorted(by: { $0.key < $1.key }) where old[name] != value {
            guard let constant = WPEParityProgramConstants.components(value)
                .flatMap(WPEParitySceneState.Constant.init(components:)) else { continue }
            constants.append(ConstantWrite(pass: pass, name: name, constant: constant))
        }
    }
}
