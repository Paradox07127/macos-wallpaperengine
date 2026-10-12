/// User-property bindings of a parity scene and the live writes a change makes (R24 Q5 step 1). SceneScript
/// properties and event 4 are not run; a target the parity renderer does not update live asks for a reload.
public enum WPEParityUserProperties {
    private static let liveGeneralFields: Set = ["cameraparallaxdelay", "cameraparallaxmouseinfluence"]

    /// Every user property the scene JSON binds, with each target it reaches. Object fields of image layers, groups
    /// and particles, material constants of image layers and the per-frame parallax terms are `.incremental`;
    /// anything else is `.reload`.
    public static func bindings(document: WPESceneDocument) -> [String: [WPEScenePropertyBinding]] {
        let layers = Set(WPEParityLayerTransform.layers(document: document).map(\.id))
        let images = Set(document.imageObjects.map(\.id))
        let particles = Set(document.particleObjects.map(\.id))
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
            guard images.contains(id) else { return reload }
            if field.count == 3, field[0] == "instance", field[1] == "constantshadervalues" {
                return (.shaderUniform(objectID: id, effectID: nil, passID: nil, name: field[2]), .uniform, true)
            }
            if field.count == 6, field[0] == "effects", field[2] == "passes", field[4] == "constantshadervalues",
               let effect = Int(field[1]), let pass = Int(field[3]) {
                let effectID = objects[index]["effects"]?[effect].flatMap(WPEParitySceneAnimations.id) ?? field[1]
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
/// every object field and material constant whose parsed value differs, and the camera parallax terms read per frame.
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

    public private(set) var objects: [ObjectWrite] = []
    public private(set) var constants: [ConstantWrite] = []
    public let cameraParallax: WPESceneCameraParallaxSettings

    /// Nil when the two parses do not hold the same objects and effects.
    public init?(from old: WPESceneDocument, to new: WPESceneDocument) {
        cameraParallax = new.general.cameraParallax
        let before = WPEParitySceneState(document: old, hdr: false)
        let after = WPEParitySceneState(document: new, hdr: false)
        guard before.ids == after.ids else { return nil }
        for id in after.ids {
            for property in WPEParitySceneState.Property.allCases {
                guard let value = after.value(property, of: id), value != before.value(property, of: id) else {
                    continue
                }
                objects.append(ObjectWrite(id: id, property: property, value: value))
            }
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
