/// Every keyframe animation of a scene's object properties and `constantshadervalues`, each bound to the state field
/// it writes. A property under a user binding is skipped: the parser replaces it, animation included, with
/// the user value.
public struct WPEParitySceneAnimations {
    private enum Target {
        case object(Int, WPEParitySceneState.Property)
        case constant(pass: Int, key: WPEParityMaterialPassKey, name: String, components: Int)
        case field(name: String, invalidation: WPEParitySceneState.Invalidation)
    }

    private struct Binding {
        let animation: WPEParityPropertyAnimation
        let target: Target
        let objectID: String
    }

    /// The JSON object an animated property was read from; a child's parent.key resolves only within it.
    private enum Owner: Hashable {
        case object(String)
        case instanceOverride(String)
        case pass(WPEParityMaterialPassKey)
    }

    private struct Authored {
        let property: WPESceneJSONValue
        let valueType: WPEParityPropertyAnimation.ValueType
        let target: Target
        let objectID: String
        let owner: Owner
        /// The JSON key the property was read from.
        let key: String
    }

    /// One event a keyframe animation crossed, for the SceneScript event 6 dispatch.
    public struct FiredEvent: Sendable, Equatable {
        public let objectID: String
        public let name: String
        public let payloadJSON: String
        /// The authored frame of the event.
        public let frame: Float
    }

    private let bindings: [Binding]
    private var frameStamp: UInt64 = 0
    /// The events the last `advance` fired, binding by binding in scene order. WPE dispatches them inside the
    /// animation step, after the object update and camera and before the script update (140171440.c:857-896).
    public private(set) var firedEvents: [FiredEvent] = []

    public var isEmpty: Bool {
        bindings.isEmpty
    }

    /// `constantComponents` gives, per material pass, the component count of each constant a shader declares; WPE binds
    /// no animation to a constant without a uniform.
    public init(document: WPESceneDocument, state: WPEParitySceneState,
                constantComponents: [WPEParityMaterialPassKey: [String: Int]]) {
        var authored: [Authored] = []
        func fields(_ descriptors: [WPEParityScriptProperty], config: WPESceneJSONValue?, objectID: String) {
            for descriptor in descriptors {
                guard case .field = descriptor.target, !descriptor.flags.contains(.notFromJSON) else { continue }
                switch descriptor.type {
                case .float, .vec2, .vec3, .vec4: break
                default: continue
                }
                let name = objectID.isEmpty ? descriptor.name.lowercased() : descriptor.name
                let instance = descriptor.owner == .particleInstance
                let raw = instance ? config?["instanceoverride"]?[name] : config?[name]
                guard let raw,
                      let type = WPEParityPropertyAnimation.ValueType(rawValue: descriptor.type.componentCount)
                else { continue }
                authored.append(Authored(property: raw, valueType: type,
                                         target: .field(name: descriptor.fieldName, invalidation: descriptor.invalidation),
                                         objectID: objectID,
                                         owner: instance ? .instanceOverride(objectID) : .object(objectID), key: name))
            }
        }
        // 140186c90 -> 1401730d0: scene fields use the same numeric animation reader as object descriptors.
        fields(WPEParityScriptProperty.scene, config: document.sourceJSON["general"], objectID: "")
        for object in WPEParityProgramScene.array(document.sourceJSON["objects"]) {
            guard let id = Self.id(object), let index = state.index(of: id) else { continue }
            for property in WPEParitySceneState.Property.allCases where property != .visible {
                guard let raw = object[property.rawValue],
                      let valueType = WPEParityPropertyAnimation.ValueType(rawValue: property.componentCount)
                else { continue }
                authored.append(Authored(property: raw, valueType: valueType, target: .object(index, property),
                                         objectID: id, owner: .object(id), key: property.rawValue))
            }
            let kind = WPEParityScriptLayerKind.classify(id: id, object: object, document: document)
            switch kind {
            // These original readers reach 1730d0 through the common object loader (1de470), except the
            // particle instance override, which registers separately in 22af30. Camera queue tracks are separate.
            case .image, .particle, .sound, .camera, .group:
                fields(WPEParityScriptProperty.layer(kind), config: object, objectID: id)
            case .text, .light:
                // Registration exists, but their derived fromJSON path still needs qualification.
                break
            }
            func constants(_ values: WPESceneJSONValue?, _ key: WPEParityMaterialPassKey) {
                guard case let .object(entries)? = values, let pass = state.passIndex(of: key) else { return }
                for (name, raw) in entries.sorted(by: { $0.key < $1.key }) {
                    guard let components = constantComponents[key]?[name],
                          let valueType = WPEParityPropertyAnimation.ValueType(rawValue: components) else { continue }
                    authored.append(Authored(property: raw, valueType: valueType,
                                             target: .constant(pass: pass, key: key, name: name,
                                                               components: components),
                                             objectID: id, owner: .pass(key), key: name))
                }
            }
            constants(object["instance"]?["constantshadervalues"], WPEParityMaterialPassKey(objectID: id))
            for effect in WPEParityProgramScene.array(object["effects"]) {
                guard let effectID = Self.id(effect) else { continue }
                for (pass, entry) in WPEParityProgramScene.array(effect["passes"]).enumerated() {
                    constants(entry["constantshadervalues"],
                              WPEParityMaterialPassKey(objectID: id, effectID: effectID, pass: pass))
                }
            }
        }
        // A child runs on the root of its owner whose property key equals parent.key (140175880.c:697-718, 939-958),
        // so roots are parsed first; without one it keeps its own clock.
        var bindings: [Binding] = []
        var roots: [Owner: [String: WPEParityPropertyAnimation]] = [:]
        for children in [false, true] {
            for entry in authored {
                let parentKey = WPEParityProgramScene.string(entry.property["animation"]?["options"]?["parent"]?["key"])
                    .flatMap { $0.isEmpty ? nil : $0 }
                guard (parentKey != nil) == children,
                      entry.property["animation"] != nil, entry.property["user"] == nil else { continue }
                let parent = parentKey.flatMap { roots[entry.owner]?[$0] }
                guard let animation = WPEParityPropertyAnimation(property: entry.property, valueType: entry.valueType,
                                                                 parent: parent) else { continue }
                if !children, roots[entry.owner]?[entry.key] == nil {
                    roots[entry.owner, default: [:]][entry.key] = animation
                }
                bindings.append(Binding(animation: animation, target: entry.target, objectID: entry.objectID))
            }
        }
        self.bindings = bindings
    }

    /// Advances every animation by the frame's `dt` and writes the values; a channel count other than the property's
    /// component count writes nothing.
    public mutating func advance(dt: Float, state: inout WPEParitySceneState) {
        frameStamp &+= 1
        firedEvents.removeAll(keepingCapacity: true)
        for binding in bindings {
            binding.animation.advance(dt: dt, frameStamp: frameStamp)
            for event in binding.animation.firedEvents {
                firedEvents.append(FiredEvent(objectID: binding.objectID, name: event.name,
                                              payloadJSON: event.payloadJSON, frame: event.frame))
            }
            guard let value = binding.animation.value else { continue }
            switch binding.target {
            case let .object(index, property):
                state.set(property, at: index, to: value)
            case let .constant(pass, _, name, components):
                state.setConstant(name, pass: pass, to: WPEParitySceneState.Constant(value: value, count: components))
            case let .field(name, invalidation):
                // Animation curves are already in native stored units; the JavaScript angle conversion does not apply.
                state.setScriptField(name, of: binding.objectID, to: .vector(value), invalidating: invalidation)
            }
        }
    }

    /// 14018db00: the first binding of the owner whose options.name (absent = "") equals `name`. `pass` selects that
    /// material pass's constant animations; nil selects the layer's object-property and field animations.
    /// A nil `objectID` searches the whole scene in binding order and ignores `pass` and the target kind.
    public func animation(objectID: String?, pass: WPEParityMaterialPassKey?,
                          name: String) -> WPEParityPropertyAnimation? {
        bindings.first { binding in
            guard (binding.animation.name ?? "") == name else { return false }
            guard let objectID else { return true }
            guard binding.objectID == objectID else { return false }
            if case let .constant(_, key, _, _) = binding.target {
                return key == pass
            }
            return pass == nil
        }?.animation
    }

    static func id(_ object: WPESceneJSONValue) -> String? {
        if let id = WPEParityProgramScene.string(object["id"]), !id.isEmpty {
            return id
        }
        // A numeric id that is not an exact Int names no object; it must not fall through to `name`.
        if case let .number(number)? = object["id"] {
            return WPEAuthoredInteger.exact(number, as: Int.self).map(String.init)
        }
        return WPEParityProgramScene.string(object["name"])
    }
}
