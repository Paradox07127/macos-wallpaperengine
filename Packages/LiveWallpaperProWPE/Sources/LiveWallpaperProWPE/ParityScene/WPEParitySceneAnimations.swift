/// Every keyframe animation of a scene's object properties and `constantshadervalues`, each bound to the state field
/// it writes (R24 Q1). A property under a user binding is skipped: the parser replaces it, animation included, with
/// the user value.
public struct WPEParitySceneAnimations {
    private enum Target {
        case object(Int, WPEParitySceneState.Property)
        case constant(pass: Int, name: String, components: Int)
        case field(name: String, invalidation: WPEParitySceneState.Invalidation)
    }

    private struct Binding {
        let animation: WPEParityPropertyAnimation
        let target: Target
        let objectID: String
    }

    private struct Authored {
        let property: WPESceneJSONValue
        let valueType: WPEParityPropertyAnimation.ValueType
        let target: Target
        let objectID: String
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
                let raw = descriptor.owner == .particleInstance ? config?["instanceoverride"]?[name] : config?[name]
                guard let raw,
                      let type = WPEParityPropertyAnimation.ValueType(rawValue: descriptor.type.componentCount)
                else { continue }
                authored.append(Authored(property: raw, valueType: type,
                                         target: .field(name: descriptor.fieldName, invalidation: descriptor.invalidation),
                                         objectID: objectID))
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
                                         objectID: id))
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
                                             target: .constant(pass: pass, name: name, components: components),
                                             objectID: id))
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
        // A child animation runs on its root's clock, so roots are parsed first.
        var bindings: [Binding] = []
        var byName: [String: WPEParityPropertyAnimation] = [:]
        for children in [false, true] {
            for entry in authored where (entry.property["animation"]?["options"]?["parent"]?["key"] != nil) == children {
                guard entry.property["animation"] != nil, entry.property["user"] == nil else { continue }
                let parent = WPEParityProgramScene.string(entry.property["animation"]?["options"]?["parent"]?["key"])
                    .flatMap { byName[$0] }
                guard let animation = WPEParityPropertyAnimation(property: entry.property, valueType: entry.valueType,
                                                                 parent: parent) else { continue }
                if let name = animation.name, byName[name] == nil {
                    byName[name] = animation
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
            case let .constant(pass, name, components):
                state.setConstant(name, pass: pass, to: WPEParitySceneState.Constant(value: value, count: components))
            case let .field(name, invalidation):
                // Animation curves are already in native stored units; the JavaScript angle conversion does not apply.
                state.setScriptField(name, of: binding.objectID, to: .vector(value), invalidating: invalidation)
            }
        }
    }

    static func id(_ object: WPESceneJSONValue) -> String? {
        if let id = WPEParityProgramScene.string(object["id"]), !id.isEmpty {
            return id
        }
        if case let .number(number)? = object["id"] {
            return String(Int(number))
        }
        return WPEParityProgramScene.string(object["name"])
    }
}
