import simd

/// One resolved `objects` entry's common fields as the parity runtime reads them.
public struct WPESceneObjectHeader: Equatable, Sendable {
    /// `id` as a non-empty string or exact Int, else `name`; nil names no object.
    public let id: String?
    /// `camera` is a string.
    public let isCamera: Bool
    /// Absent counts as solid: the editor writes `solid` on every layer.
    public let solid: Bool
    public let disablePropagation: Bool
    /// Authored `fov` / `zoom` with one `value` envelope unwrapped; nil when not numeric.
    public let fov: Float?
    public let zoom: Float?
    /// Raw `effects`; createLayer compares a config's effects to its clone template's with it.
    public let effects: WPESceneJSONValue?

    init(_ object: WPESceneJSONValue) {
        id = WPEParitySceneAnimations.id(object)
        effects = object["effects"]
        if case .string? = object["camera"] {
            isCamera = true
        } else {
            isCamera = false
        }
        solid = Self.flag(object["solid"]) ?? true
        disablePropagation = Self.flag(object["disablepropagation"]) ?? false
        func number(_ name: String) -> Float? {
            let raw = object[name]
            return WPEParityProgramScene.number(raw?["value"] ?? raw).map(Float.init)
        }
        fov = number("fov")
        zoom = number("zoom")
    }

    private static func flag(_ value: WPESceneJSONValue?) -> Bool? {
        switch value {
        case let .bool(flag)?: flag
        case let .number(number)?: number != 0
        case let .object(entries)?: flag(entries["value"])
        default: nil
        }
    }
}

/// Scene fields the parity runtime seeds from the user-resolved JSON. Strict fromJSON rules and WPE's native
/// constructor defaults apply, which differ from the parser's lenient typed fields and parser defaults.
public struct WPESceneParitySeeds: Equatable, Sendable {
    /// Every resolved object, in authored order.
    public let objects: [WPESceneObjectHeader]
    /// Every value stored under a `script` key at any depth of general and the objects, keys visited sorted.
    public let scripts: [WPESceneJSONValue]
    public let bloomStrength: SIMD4<Float>
    public let bloomThreshold: SIMD4<Float>
    public let ambientColor: SIMD4<Float>
    public let skylightColor: SIMD4<Float>
    public let bloom: Bool
    public let cameraParallax: WPESceneCameraParallaxSettings
    /// Constructor fields only; a camera object or SceneScript may replace the FOV later.
    public let perspective: WPEParityScenePerspective
    public let perspectiveOverrideFOV: Float
    public let cameraShakeEnabled: Bool
    /// `orthographic` is left at its default; the camera sets it from the projection.
    public let cameraShake: WPEParityCameraShake

    init(general: WPESceneJSONValue, objects: [WPESceneJSONValue]) {
        self.objects = objects.map(WPESceneObjectHeader.init)
        var scripts: [WPESceneJSONValue] = []
        for value in [general] + objects {
            Self.collectScripts(value, into: &scripts)
        }
        self.scripts = scripts
        bloomStrength = Self.vector(general["bloomstrength"], native: SIMD4(2, 0, 0, 0))
        bloomThreshold = Self.vector(general["bloomthreshold"], native: SIMD4(0.65, 0, 0, 0))
        ambientColor = Self.vector(general["ambientcolor"], native: .zero)
        skylightColor = Self.vector(general["skylightcolor"], native: .zero)
        bloom = WPEParityScriptProperty.sceneBoolValue(fromJSON: general["bloom"]) ?? true
        cameraParallax = WPEParityCamera.parallaxSettings(general: general)
        perspective = WPEParityScenePerspective(general: general)
        perspectiveOverrideFOV = WPEParityCamera.perspectiveOverrideFOV(general: general)
        cameraShakeEnabled = WPEParityScriptProperty.sceneBoolValue(fromJSON: general["camerashake"]) == true
        cameraShake = WPEParityCameraShake(general: general)
    }

    private static func collectScripts(_ value: WPESceneJSONValue, into scripts: inout [WPESceneJSONValue]) {
        switch value {
        case let .object(members):
            for (key, member) in members.sorted(by: { $0.key < $1.key }) {
                if key == "script" {
                    scripts.append(member)
                }
                collectScripts(member, into: &scripts)
            }
        case let .array(elements):
            for element in elements {
                collectScripts(element, into: &scripts)
            }
        default:
            break
        }
    }

    /// The first four components; a parse failure or no components keeps `native`, and unset lanes are 0.
    private static func vector(_ value: WPESceneJSONValue?, native: SIMD4<Float>) -> SIMD4<Float> {
        guard let parsed = components(value), !parsed.isEmpty else { return native }
        var result = SIMD4<Float>.zero
        for (lane, number) in parsed.prefix(4).enumerated() {
            result[lane] = number
        }
        return result
    }

    /// A `value` envelope, a number, whitespace- or comma-separated numbers, or an array of numbers.
    private static func components(_ value: WPESceneJSONValue?) -> [Float]? {
        switch value {
        case let .object(entries)?: return components(entries["value"])
        case let .number(number)?: return [Float(number)]
        case let .string(text)?:
            let tokens = text.split { $0.isWhitespace || $0 == "," }
            let parsed = tokens.compactMap { Float($0) }
            return parsed.count == tokens.count ? parsed : nil
        case let .array(values)?:
            var result: [Float] = []
            for value in values {
                guard case let .number(number) = value else { return nil }
                result.append(Float(number))
            }
            return result
        default: return nil
        }
    }
}
