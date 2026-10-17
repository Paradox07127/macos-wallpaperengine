import Foundation
import LiveWallpaperCore

/// User-property bindings of a parity scene and the field writes a change makes before the script engine applies the
/// bound scriptproperties and event 4 (1401731d0.c:159-841); a target the parity renderer does not update live reloads.
public enum WPEParityUserProperties {
    /// Live camera/bloom fields use canonical State consumers; changing `hdr` still reloads.
    private static let liveGeneralFields: Set = [
        "cameraparallax", "cameraparallaxamount", "cameraparallaxdelay", "cameraparallaxmouseinfluence",
        "camerashake", "camerashakespeed", "camerashakeamplitude", "camerashakeroughness",
        "fov", "nearz", "farz", "perspectiveoverridefov", "zoom",
        "bloom", "bloomstrength", "bloomthreshold", "bloomtint",
        "bloomhdrstrength", "bloomhdrthreshold", "bloomhdrfeather", "bloomhdrscatter", "bloomhdriterations",
    ]

    /// Text layer fields that only move glyphs, which a live re-layout redraws (the enum fields never bind).
    private static let liveTextFields: Set = [
        "text", "font", "pointsize", "padding", "spacing", "maxwidth", "maxrows", "limitwidth", "limitrows",
        "limituseellipsis", "blockalign",
    ]

    /// Particle instance overrides a user value rewrites through the instance hook (14022af30.c:390-392).
    private static let liveParticleInstanceFields: Set = [
        "count", "rate", "lifetime", "size", "speed", "alpha", "brightness", "colorn",
    ]

    /// Every user property the scene JSON binds, with each target it reaches. A scripted object field keeps its user watch
    /// (1401a4db0.c:39-142); scriptproperties, sound volume, particle instance overrides, camera-object zoom/fov,
    /// parallaxDepth and the fields the renderer reads per frame or re-lays are `.incremental`, anything else (other
    /// scripted fields included) is `.reload`.
    public static func bindings(document: WPESceneDocument) -> [String: [WPEScenePropertyBinding]] {
        let layers = Set(WPEParityLayerTransform.layers(document: document).map(\.id))
        let images = Set(document.imageObjects.map(\.id))
        let particles = Set(document.particleObjects.map(\.id))
        let texts = Set(WPEParityTextObject.textObjects(in: document).map(\.id))
        let sounds = Set(document.soundObjects.map(\.id))
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
            let joined = field.joined(separator: ".")
            let reload = (WPEScenePropertyBindingTarget.objectResource(objectID: id, field: joined),
                          WPEScenePropertyBindingKind.resource, false)
            if field.contains("scriptproperties") {
                return (.objectResource(objectID: id, field: joined), .scriptProperty, true)
            }
            if sounds.contains(id), field == ["volume"] {
                return (.soundObject(id: id), .volume, true)
            }
            if field.count == 1, let property = WPEParitySceneState.Property(rawValue: field[0]),
               layers.contains(id) || texts.contains(id) {
                let owner: WPEScenePropertyBindingTarget = images.contains(id) ? .imageObject(id: id)
                    : particles.contains(id) ? .particleObject(id: id)
                    : texts.contains(id) ? .textObject(id: id) : .groupObject(id: id)
                return switch property {
                case .visible: (owner, .visible, true)
                case .alpha: (owner, .alpha, true)
                case .color: (owner, .color, true)
                case .brightness: (owner, .brightness, true)
                case .origin, .scale, .angles: (.objectResource(objectID: id, field: field[0]), .resource, true)
                }
            }
            guard !scripted else { return reload }
            if field == ["parallaxDepth"]
                || (field == ["zoom"] || field == ["fov"]) && WPEParityProgramScene.string(objects[index]["camera"]) != nil {
                return (.objectResource(objectID: id, field: field[0]), .resource, true)
            }
            if texts.contains(id), field.count == 1, liveTextFields.contains(field[0]) {
                return (.textObject(id: id), .resource, true)
            }
            if particles.contains(id), field.count == 2, field[0] == "instanceoverride",
               liveParticleInstanceFields.contains(field[1]) {
                return (.particleObject(id: id), .resource, true)
            }
            guard images.contains(id) || texts.contains(id) else { return reload }
            if images.contains(id), field.count == 3, field[0] == "instance", field[1] == "constantshadervalues" {
                return (.shaderUniform(objectID: id, effectID: nil, passID: nil, name: field[2]), .uniform, true)
            }
            guard field.count > 2, field[0] == "effects", let effect = Int(field[1]) else { return reload }
            let effectID = objects[index]["effects"]?[effect].flatMap(WPEParitySceneAnimations.id) ?? field[1]
            if field.count == 3, field[2] == "visible" {
                return (.imageEffect(objectID: id, effectID: effectID), .visible, true)
            }
            guard images.contains(id) else { return reload }
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

    /// The user watches of material-file constants no scene override replaced (140175880.c:386-429). A pass several
    /// materials share (a multi-material model) holds one constant set, so its watches reload.
    public static func bindings(scene: WPEParityProgramScene) -> [String: [WPEScenePropertyBinding]] {
        var result: [String: [WPEScenePropertyBinding]] = [:]
        for entry in materialFileConstants(of: scene) {
            let target = WPEScenePropertyBindingTarget.shaderUniform(
                objectID: entry.pass.objectID, effectID: entry.pass.effectID,
                passID: entry.pass.effectID == nil ? nil : entry.pass.pass, name: entry.name
            )
            result[entry.property, default: []].append(WPEScenePropertyBinding(
                propertyKey: entry.property, target: target, kind: .uniform, action: entry.shared ? .reload : .incremental
            ))
        }
        return result
    }

    fileprivate typealias MaterialFileConstant = (pass: WPEParityMaterialPassKey, name: String,
                                                  envelope: WPESceneJSONValue, property: String, shared: Bool)

    /// `shared`: another material of the scene maps to the same state pass.
    fileprivate static func materialFileConstants(of scene: WPEParityProgramScene) -> [MaterialFileConstant] {
        var materialsByPass: [WPEParityMaterialPassKey: Int] = [:]
        let passes = scene.materials.map { key, material in
            let pass = WPEParityMaterialPassKey(objectID: key.objectID, effectID: key.effectID,
                                                pass: scene.overridePasses[key] ?? 0)
            materialsByPass[pass, default: 0] += 1
            return (pass, material)
        }
        var result: [MaterialFileConstant] = []
        for (pass, material) in passes {
            for (name, envelope) in material.userConstants {
                guard let property = WPEParityProgramScene.string(envelope["user"]) else { continue }
                result.append((pass, name, envelope, property, materialsByPass[pass, default: 0] > 1))
            }
        }
        return result.sorted {
            ($0.pass.objectID, $0.pass.effectID ?? "", $0.pass.pass, $0.name)
                < ($1.pass.objectID, $1.pass.effectID ?? "", $1.pass.pass, $1.name)
        }
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
/// every object field, effect visible bit, material constant, sound volume, particle instance field, camera-object
/// zoom/fov and parallaxDepth whose parsed value differs, and the camera parallax terms, accepted bloom Bool delta and
/// bloom constants read per frame.
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

    public struct SceneFloatWrite: Sendable, Equatable {
        public let name: String
        public let value: Float
        public let invalidation: WPEParitySceneState.Invalidation
    }

    public struct SoundWrite: Sendable, Equatable {
        public let id: String
        public let volume: Float
    }

    public struct ScriptFieldWrite: Sendable, Equatable {
        public let id: String
        public let name: String
        public let value: SIMD4<Float>
        public let invalidation: WPEParitySceneState.Invalidation
    }

    public private(set) var objects: [ObjectWrite] = []
    public private(set) var effects: [EffectWrite] = []
    public private(set) var constants: [ConstantWrite] = []
    /// Text layers whose parsed fields differ, with their new fields.
    public private(set) var texts: [WPEParityTextObject] = []
    /// Sound layers whose parsed volume differs, with the new volume.
    public private(set) var sounds: [SoundWrite] = []
    /// `instance.*` fields of particle layers whose parsed instance override differs.
    public private(set) var particles: [ScriptFieldWrite] = []
    /// Camera-object fov/zoom and every object's parallaxDepth whose accepted JSON value differs.
    public private(set) var objectFields: [ScriptFieldWrite] = []
    public let cameraParallax: WPESceneCameraParallaxSettings
    /// The new parse's bloom values, which the post-process draws read on the next frame.
    public let bloom: WPEParityBloomSettings
    /// A valid changed JSON Bool seed, or nil to preserve the running script's current value.
    public let sceneBloom: Bool?
    /// Accepted document deltas of the bloom, camera parallax/shake and projection Float fields.
    public private(set) var sceneFloats: [SceneFloatWrite] = []
    /// Accepted typed deltas; nil preserves the running script's value instead of restoring the authored seed.
    public let sceneBloomIterations: Int32?
    public let sceneBloomTint: SIMD3<Float>?
    public let sceneParallaxEnabled: Bool?
    public let sceneShakeEnabled: Bool?

    /// Nil when the two parses do not hold the same objects and effects.
    public init?(from old: WPESceneDocument, to new: WPESceneDocument) {
        cameraParallax = new.general.cameraParallax
        bloom = WPEParityProgramScene.bloomSettings(new.resolvedGeneralJSON)
        let oldBloom = WPEParityScriptProperty.sceneBoolValue(fromJSON: old.resolvedGeneralJSON["bloom"])
        let newBloom = WPEParityScriptProperty.sceneBoolValue(fromJSON: new.resolvedGeneralJSON["bloom"])
        sceneBloom = oldBloom != newBloom ? newBloom : nil
        let oldIterations = WPEParityScriptProperty.bloomIterationsValue(fromJSON: old.resolvedGeneralJSON["bloomhdriterations"])
        let newIterations = WPEParityScriptProperty.bloomIterationsValue(fromJSON: new.resolvedGeneralJSON["bloomhdriterations"])
        sceneBloomIterations = oldIterations != newIterations ? newIterations : nil
        let oldTint = WPEParityScriptProperty.bloomTintValue(fromJSON: old.resolvedGeneralJSON["bloomtint"])
        let newTint = WPEParityScriptProperty.bloomTintValue(fromJSON: new.resolvedGeneralJSON["bloomtint"])
        sceneBloomTint = oldTint != newTint ? newTint : nil
        let oldParallax = WPEParityScriptProperty.sceneBoolValue(fromJSON: old.resolvedGeneralJSON["cameraparallax"])
        let newParallax = WPEParityScriptProperty.sceneBoolValue(fromJSON: new.resolvedGeneralJSON["cameraparallax"])
        sceneParallaxEnabled = oldParallax != newParallax ? newParallax : nil
        let oldShake = WPEParityScriptProperty.sceneBoolValue(fromJSON: old.resolvedGeneralJSON["camerashake"])
        let newShake = WPEParityScriptProperty.sceneBoolValue(fromJSON: new.resolvedGeneralJSON["camerashake"])
        sceneShakeEnabled = oldShake != newShake ? newShake : nil
        for descriptor in WPEParityScriptProperty.scene where descriptor.type == .float
            && (descriptor.isSceneBloomFloat || descriptor.isSceneCameraParallax || descriptor.isSceneCameraShake
                || descriptor.isSceneProjection) {
            let previous = WPEParityScriptProperty.sceneFloatValue(fromJSON: old.resolvedGeneralJSON[descriptor.name])
            guard let value = WPEParityScriptProperty.sceneFloatValue(fromJSON: new.resolvedGeneralJSON[descriptor.name]),
                  value != previous else { continue }
            sceneFloats.append(SceneFloatWrite(name: descriptor.fieldName, value: value,
                                               invalidation: descriptor.invalidation))
        }
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
        for text in WPEParityTextObject.textObjects(in: new) {
            guard var earlier = earlierTexts[text.id] else { return nil }
            // Read at draw from the state objects above; only the other fields re-lay (140258050.c:184-191).
            (earlier.color, earlier.alpha, earlier.brightness, earlier.visible) = (text.color, text.alpha,
                                                                                   text.brightness, text.visible)
            if earlier != text {
                texts.append(text)
            }
        }
        let earlierSounds = Dictionary(old.soundObjects.map { ($0.id, $0.volume) }) { first, _ in first }
        for sound in new.soundObjects where earlierSounds[sound.id].map({ $0 != sound.volume }) ?? false {
            sounds.append(SoundWrite(id: sound.id, volume: Float(sound.volume)))
        }
        let earlierOverrides = Dictionary(old.particleObjects.map { ($0.id, $0.instanceOverride) }) { first, _ in first }
        for particle in new.particleObjects {
            guard let override = particle.instanceOverride else { continue }
            let earlier = earlierOverrides[particle.id] ?? nil
            for descriptor in WPEParityScriptProperty.particleInstance {
                guard let value = Self.instanceValue(descriptor.name, of: override),
                      value != earlier.flatMap({ Self.instanceValue(descriptor.name, of: $0) }) else { continue }
                particles.append(ScriptFieldWrite(id: particle.id, name: descriptor.fieldName, value: value,
                                                  invalidation: descriptor.invalidation))
            }
        }
        let earlierObjects = Dictionary(old.resolvedObjectsJSON.compactMap { object in
            WPEParitySceneAnimations.id(object).map { ($0, object) }
        }) { first, _ in first }
        for object in new.resolvedObjectsJSON {
            guard let id = WPEParitySceneAnimations.id(object), let earlier = earlierObjects[id] else { continue }
            if WPEParityProgramScene.string(object["camera"]) != nil {
                for descriptor in WPEParityScriptProperty.camera where descriptor.type == .float {
                    guard let value = WPEParityScriptProperty.sceneFloatValue(fromJSON: object[descriptor.name]),
                          value != WPEParityScriptProperty.sceneFloatValue(fromJSON: earlier[descriptor.name]) else {
                        continue
                    }
                    objectFields.append(ScriptFieldWrite(id: id, name: descriptor.fieldName, value: SIMD4(value, 0, 0, 0),
                                                         invalidation: descriptor.invalidation))
                }
            }
            if let depth = Self.nativeVec2(object["parallaxDepth"]), depth != Self.nativeVec2(earlier["parallaxDepth"]) {
                objectFields.append(ScriptFieldWrite(id: id, name: "parallaxDepth", value: SIMD4(lowHalf: depth, highHalf: .zero),
                                                     invalidation: .none))
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
        if let sceneBloom {
            state.setScriptField("bloom", of: "", to: .vector(SIMD4(sceneBloom ? 1 : 0, 0, 0, 0)), invalidating: .none)
        }
        for write in sceneFloats {
            state.setScriptField(write.name, of: "", to: .vector(SIMD4(write.value, 0, 0, 0)), invalidating: write.invalidation)
        }
        if let sceneBloomIterations {
            state.setScriptField("bloomhdriterations", of: "", to: .integer(sceneBloomIterations), invalidating: .bloom)
        }
        if let sceneBloomTint {
            state.setScriptField("bloomtint", of: "", to: .vector(SIMD4(sceneBloomTint, 0)), invalidating: .bloom)
        }
        if let sceneParallaxEnabled {
            state.setScriptField("cameraparallax", of: "", to: .vector(SIMD4(sceneParallaxEnabled ? 1 : 0, 0, 0, 0)), invalidating: .none)
        }
        if let sceneShakeEnabled {
            state.setScriptField("camerashake", of: "", to: .vector(SIMD4(sceneShakeEnabled ? 1 : 0, 0, 0, 0)), invalidating: .none)
        }
        for write in objects {
            state.set(write.property, of: write.id, to: write.value)
        }
        for write in effects {
            state.setEffect(write.effect.effectID, of: write.effect.objectID, visible: write.visible)
        }
        for write in constants {
            state.setConstant(write.name, of: write.pass, to: write.constant)
        }
        for write in sounds {
            state.setScriptField("volume", of: write.id, to: .vector(SIMD4(write.volume, 0, 0, 0)),
                                 invalidating: .soundGain)
        }
        for write in particles + objectFields {
            state.setScriptField(write.name, of: write.id, to: .vector(write.value), invalidating: write.invalidation)
        }
    }

    /// The vec2 fromJSON (1401a3fc0.c:18-48): a number broadcasts; a string reads x, then y after the first space run
    /// or 0; other shapes leave the field alone.
    private static func nativeVec2(_ value: WPESceneJSONValue?) -> SIMD2<Float>? {
        switch value {
        case let .number(number)?:
            SIMD2(repeating: Float(number))
        case let .string(text)?:
            text.withCString { start in
                guard start.pointee != 0 else { return .zero }
                var cursor = start
                let x = Float(strtod(cursor, nil))
                while cursor.pointee != 0, cursor.pointee != 0x20 {
                    cursor += 1
                }
                guard cursor.pointee == 0x20 else { return SIMD2(x, 0) }
                while cursor.pointee == 0x20 {
                    cursor += 1
                }
                return SIMD2(x, Float(strtod(cursor, nil)))
            }
        default:
            nil
        }
    }

    /// The script value of instance field `name`; nil when the override does not hold it. The parser keeps `colorn`
    /// scaled to 0...255.
    private static func instanceValue(_ name: String, of override: WPESceneParticleInstanceOverride) -> SIMD4<Float>? {
        if name == "colorn" {
            return override.color.map { SIMD4(SIMD3<Float>($0 / 255), 0) }
        }
        let scalar: Double? = switch name {
        case "count": override.count
        case "rate": override.rate
        case "lifetime": override.lifetime
        case "size": override.size
        case "speed": override.speed
        case "alpha": override.alpha
        case "brightness": override.brightness
        default: nil
        }
        return scalar.map { SIMD4(Float($0), 0, 0, 0) }
    }

    /// Rewrites each live-bound material-file constant whose property is in `keys` with its value in `values`, or the
    /// envelope's own value when `values` lacks it (1401731d0.c:143-215).
    public mutating func resolveMaterialFiles(of scene: WPEParityProgramScene,
                                              values: [String: WallpaperEngineProjectPropertyValue],
                                              changed keys: Set<String>) {
        for entry in WPEParityUserProperties.materialFileConstants(of: scene)
            where !entry.shared && keys.contains(entry.property) {
            guard let constant = WPEParityProgramConstants.components(entry.envelope, userValues: values)
                .flatMap(WPEParitySceneState.Constant.init(components:)) else { continue }
            constants.append(ConstantWrite(pass: entry.pass, name: entry.name, constant: constant))
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
