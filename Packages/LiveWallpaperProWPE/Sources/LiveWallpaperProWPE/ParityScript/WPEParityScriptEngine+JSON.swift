import Foundation

extension WPEParityScriptEngine {
    // MARK: JSON

    static func fallback(_ descriptor: WPEParityScriptProperty, objectID: String,
                         document: WPESceneDocument?) -> WPEParitySceneState.ScriptValue? {
        if descriptor.owner == .object, descriptor.name == "parallaxDepth", let document {
            let object = document.resolvedObjectsJSON.first { WPEParitySceneAnimations.id($0) == objectID }
            let raw = object?["parallaxDepth"] ?? object?["parallaxdepth"]
            let depth = WPEParityNumericConversion.nativeVector2(raw?["value"] ?? raw) ?? SIMD2(1, 1)
            return .vector(SIMD4(Float(depth.x), Float(depth.y), 0, 0))
        }
        if descriptor.owner == .text, let text = document?.textObjects.first(where: { $0.id == objectID }) {
            switch descriptor.name {
            case "text": return .string(text.text)
            case "font": return .string(text.fontRelativePath ?? "systemfont_arial")
            case "pointsize": return .vector(SIMD4(Float(text.pointSize), 0, 0, 0))
            case "horizontalalign": return .string(text.horizontalAlignment)
            case "verticalalign": return .string(text.verticalAlignment)
            case "padding": return .vector(SIMD4(32, 32, 0, 0))
            case "spacing": return .vector(SIMD4(Float(text.spacing.x), Float(text.spacing.y), 0, 0))
            case "limituseellipsis": return .vector(SIMD4(text.limitUseEllipsis ? 1 : 0, 0, 0, 0))
            case "maxwidth": return .vector(SIMD4(500, 0, 0, 0))
            case "maxrows": return .integer(1)
            default: break
            }
        }
        if descriptor.owner == .sound, let sound = document?.soundObjects.first(where: { $0.id == objectID }) {
            switch descriptor.name {
            case "volume": return .vector(SIMD4(Float(sound.volume), 0, 0, 0))
            case "mintime": return .vector(SIMD4(Float(sound.minTime), 0, 0, 0))
            case "maxtime": return .vector(SIMD4(Float(sound.maxTime), 0, 0, 0))
            default: break
            }
        }
        switch (descriptor.owner, descriptor.name) {
        case (.object, "solid"): return .vector(SIMD4(1, 0, 0, 0))
        case (.object, "sortorder"): return .integer(0)
        case (.particleInstance, "colorn"):
            let authoredColor = document?.particleObjects.first { $0.id == objectID }?.instanceOverride?.color
            let color = authoredColor.map { SIMD3<Float>($0 / 255) } ?? .one
            return .vector(SIMD4(color, 0))
        case let (.particleInstance, name) where name.hasPrefix("controlpoint"):
            return .vector(SIMD4(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude,
                                 Float.greatestFiniteMagnitude, 0))
        case (.particleInstance, _): return .vector(SIMD4(1, 0, 0, 0))
        // Camera constructor in 14018ff60.c: fov=0x42480000, zoom=0x3f800000.
        case (.camera, "fov"): return .vector(SIMD4(50, 0, 0, 0))
        case (.camera, "zoom"): return .vector(SIMD4(1, 0, 0, 0))
        case (.camera, "queuemode"): return .string("random")
        // Inline light constructor, 14018ff60.c:203-218, before authored descriptor values are loaded.
        case (.light, "intensity"): return .vector(.zero)
        case (.light, "radius"): return .vector(SIMD4(1, 0, 0, 0))
        case (.light, "exponent"): return .vector(SIMD4(2, 0, 0, 0))
        case (.light, "innercone"): return .vector(SIMD4(20, 0, 0, 0))
        case (.light, "outercone"): return .vector(SIMD4(30, 0, 0, 0))
        case (.light, "controlpoint"): return .vector(SIMD4(2, 0, 0, 0))
        case (.text, "pointsize"): return .vector(SIMD4(32, 0, 0, 0))
        case (.text, "font"): return .string("systemfont_arial")
        case (.text, "padding"): return .vector(SIMD4(32, 32, 0, 0))
        case (.text, "spacing"): return .vector(.zero)
        case (.text, "maxwidth"): return .vector(SIMD4(500, 0, 0, 0))
        case (.text, "maxrows"): return .integer(1)
        // 140256ae0: background scale=1; block-align bit0x20 is absent from initial flags=1.
        case (.text, "backgroundbrightness"): return .vector(SIMD4(1, 0, 0, 0))
        case (.text, "blockalign"): return .vector(.zero)
        case (.text, "horizontalalign"): return .string("center")
        case (.text, "verticalalign"): return .string("middle")
        case (.text, "limitwidth"), (.text, "limitrows"), (.text, "limituseellipsis"): return .vector(.zero)
        default: return descriptor.type == .string ? .string("") : nil
        }
    }

    static func generalDefault(_ descriptor: WPEParityScriptProperty) -> WPEParitySceneState.ScriptValue? {
        switch descriptor.name {
        case "ambientcolor", "skylightcolor": .vector(.zero)
        case "bloomstrength": .vector(SIMD4(2, 0, 0, 0))
        case "bloomthreshold": .vector(SIMD4(0.65, 0, 0, 0))
        case "bloom", "camerafade": .vector(SIMD4(1, 0, 0, 0))
        // 1401870c2..1870ee: four DWORD defaults in SceneObject O, not context/Main offsets.
        case "bloomhdrstrength": .vector(SIMD4(Float(bitPattern: 0x4000_0000), 0, 0, 0))
        case "bloomhdrthreshold": .vector(SIMD4(Float(bitPattern: 0x3F80_0000), 0, 0, 0))
        case "bloomhdrfeather": .vector(SIMD4(Float(bitPattern: 0x3DCC_CCCD), 0, 0, 0))
        case "bloomhdrscatter": .vector(SIMD4(Float(bitPattern: 0x3FCF_3B64), 0, 0, 0))
        case "bloomhdriterations": .integer(8)
        case "bloomtint": .vector(SIMD4(1, 1, 1, 0))
        case "cameraparallax", "camerashake": .vector(.zero)
        case "cameraparallaxamount", "cameraparallaxmouseinfluence": .vector(SIMD4(0.5, 0, 0, 0))
        case "cameraparallaxdelay": .vector(SIMD4(Float(bitPattern: 0x3DCC_CCCD), 0, 0, 0))
        // 140186f84..186fa5: three DWORD defaults in the same SceneObject receiver.
        case "camerashakespeed": .vector(SIMD4(Float(bitPattern: 0x4040_0000), 0, 0, 0))
        case "camerashakeamplitude": .vector(SIMD4(Float(bitPattern: 0x3F00_0000), 0, 0, 0))
        case "camerashakeroughness": .vector(SIMD4(Float(bitPattern: 0x3F80_0000), 0, 0, 0))
        // 140186d5c/186d7d/186d88: authored raw fields; projection clamps only the separate effective FOV.
        case "fov": .vector(SIMD4(Float(bitPattern: 0x4248_0000), 0, 0, 0))
        case "nearz": .vector(SIMD4(Float(bitPattern: 0x3DCC_CCCD), 0, 0, 0))
        case "farz": .vector(SIMD4(Float(bitPattern: 0x461C_4000), 0, 0, 0))
        // 140186d67: O144 raw override95; no public clamp or angle conversion.
        case "perspectiveoverridefov": .vector(SIMD4(Float(bitPattern: 0x42BE_0000), 0, 0, 0))
        case "zoom": .vector(SIMD4(Float(bitPattern: 0x3F80_0000), 0, 0, 0))
        default: nil
        }
    }

    static func parse(_ raw: WPESceneJSONValue?,
                      _ descriptor: WPEParityScriptProperty) -> WPEParitySceneState.ScriptValue? {
        let sceneCameraField = descriptor.isSceneCameraParallax || descriptor.isSceneCameraShake || descriptor.isSceneProjection
        if descriptor.isSceneBloom || descriptor.isSceneCameraFade || (sceneCameraField && descriptor.type == .flagBool) {
            return WPEParityScriptProperty.sceneBoolValue(fromJSON: raw).map { .vector(SIMD4($0 ? 1 : 0, 0, 0, 0)) }
        }
        if descriptor.isSceneBloomFloat || (sceneCameraField && descriptor.type == .float) {
            return WPEParityScriptProperty.sceneFloatValue(fromJSON: raw).map { .vector(SIMD4($0, 0, 0, 0)) }
        }
        if descriptor.isSceneBloomIterations {
            return WPEParityScriptProperty.bloomIterationsValue(fromJSON: raw).map { .integer($0) }
        }
        if descriptor.isSceneBloomTint {
            return WPEParityScriptProperty.bloomTintValue(fromJSON: raw).map { .vector(SIMD4($0, 0)) }
        }
        guard var value = raw else { return nil }
        if case .object = value {
            guard let inner = value["value"] else { return nil }
            value = inner
        }
        if descriptor.type == .string {
            return WPEParityProgramScene.string(value).map { .string(descriptor.canonicalString($0, fromJSON: true)) }
        }
        if descriptor.type == .int {
            let number: Double? = switch value {
            case let .number(raw): raw
            case let .string(raw): Double(raw)
            default: nil
            }
            guard let number, number.isFinite, number >= Double(Int32.min), number <= Double(Int32.max) else { return nil }
            return .integer(Int32(number.rounded(.towardZero)))
        }
        if descriptor.type == .vec2 {
            return WPEParityNumericConversion.nativeVector2(value).map { .vector(SIMD4(Float($0.x), Float($0.y), 0, 0)) }
        }
        let components = Self.components(value)
        guard !components.isEmpty else { return nil }
        if components.count == 1, descriptor.type.componentCount > 1 {
            var result = SIMD4<Float>.zero
            for lane in 0 ..< descriptor.type.componentCount {
                result[lane] = components[0]
            }
            return .vector(result)
        }
        return .vector(vector(components))
    }

    static func components(_ value: WPESceneJSONValue) -> [Float] {
        switch value {
        case let .number(number): [Float(number)]
        case let .bool(flag): [flag ? 1 : 0]
        case let .string(text): text.split(separator: " ").compactMap { Float($0) }
        case let .object(entries): entries["value"].map(components) ?? []
        default: []
        }
    }

    static func vector(_ components: [Float]) -> SIMD4<Float> {
        var vector = SIMD4<Float>.zero
        for (lane, component) in components.prefix(4).enumerated() {
            vector[lane] = component
        }
        return vector
    }

    static func jsonText(_ value: WPESceneJSONValue) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: foundation(value), options: [.fragmentsAllowed])
        else { return "null" }
        return String(bytes: data, encoding: .utf8) ?? "null"
    }

    private static func foundation(_ value: WPESceneJSONValue) -> Any {
        switch value {
        case let .object(entries): entries.mapValues(foundation)
        case let .array(values): values.map(foundation)
        case let .string(text): text
        case let .number(number): number
        case let .bool(flag): flag
        case .null: NSNull()
        }
    }
}
