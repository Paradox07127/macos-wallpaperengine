import Foundation
import LiveWallpaperCore

/// A `uniform` line whose trailing JSON names a material key (FUN_1401636a0).
struct WPEParityMaterialUniform: Equatable, Sendable {
    let name: String
    let material: String
    /// 4, 3 or 2 for `vec4`, `vec3`, `vec2`, else 1.
    let components: Int
    let defaultValue: [Double]?
    /// Native descriptor flag4; scene and shader defaults remain in stored units.
    let angle: Bool

    init(name: String, material: String, components: Int, defaultValue: [Double]?, angle: Bool = false) {
        self.name = name
        self.material = material
        self.components = components
        self.defaultValue = defaultValue
        self.angle = angle
    }
}

/// Material constants (engine codes 0x8c–0x8f): a key missing from the merged `constantshadervalues` takes the
/// annotation `default` (140154480.c:555-642). rad2deg preserves stored values and marks SceneScript descriptor
/// flag4; property conversion and setMaterialProperty have their own native angle branches. startdelta is unused.
enum WPEParityProgramConstants {
    /// One stage's annotations; each stage maps its HLSL names on its own (1400d5070.c:536,556,575).
    static func uniforms(_ source: String) -> [String: WPEParityMaterialUniform] {
        let pattern = try? NSRegularExpression(pattern: #"^uniform\s+(float|vec2|vec3|vec4)\s+(\w+)\s*;"#)
        var uniforms: [String: WPEParityMaterialUniform] = [:]
        // Lines end only at CR/LF (140162100.c:113); `.newlines` would also cut at U+0085/U+2028.
        for line in source.split(omittingEmptySubsequences: false,
                                 whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let text = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            guard text.hasPrefix("uniform"), let pattern,
                  let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let typeRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text),
                  let comment = text.range(of: "//"),
                  let json = WPEShaderAnnotationCombos.json(String(text[comment.upperBound...])),
                  let material = json["material"] as? String else { continue }
            let type = text[typeRange]
            let name = String(text[nameRange])
            uniforms[name] = WPEParityMaterialUniform(
                name: name, material: material,
                components: type.hasPrefix("vec") ? Int(String(type.dropFirst(3))) ?? 1 : 1,
                defaultValue: json["default"].flatMap(defaultComponents),
                angle: json["conversion"] as? String == "rad2deg"
            )
        }
        return uniforms
    }

    static func resolve(_ uniforms: [String: WPEParityMaterialUniform],
                        values: [String: [Double]]) -> [String: WPECBufferValue] {
        var constants: [String: WPECBufferValue] = [:]
        for (name, uniform) in uniforms {
            guard let value = values[uniform.material] ?? uniform.defaultValue else { continue }
            constants[name] = cbufferValue(value, components: uniform.components)
        }
        return constants
    }

    /// WPE keeps every value as text and reads as many numbers as the uniform has components; missing ones are 0.
    static func cbufferValue(_ value: [Double], components: Int) -> WPECBufferValue {
        let floats = (0 ..< components).map { $0 < value.count ? Float(value[$0]) : 0 }
        return components == 1 ? .float(floats[0]) : .vector(floats)
    }

    static func components(_ value: WPESceneShaderConstantValue) -> [Double]? {
        switch value {
        case let .number(number): [number]
        case let .bool(flag): [flag ? 1 : 0]
        case let .vector(vector): vector
        case let .string(text): numbers(text)
        case .animated: value.vectorValue ?? value.numberValue.map { [$0] }
        }
    }

    static func components(_ value: WPESceneJSONValue) -> [Double]? {
        switch value {
        case let .number(number): [number]
        case let .bool(flag): [flag ? 1 : 0]
        case let .string(text): numbers(text)
        case let .array(values):
            values.compactMap { value -> Double? in
                if case let .number(number) = value {
                    number
                } else {
                    nil
                }
            }
        case .object: value["value"].flatMap(components)
        case .null: nil
        }
    }

    /// A `{"user": K, "value": V}` envelope takes `userValues[K]` when present; condition-form `user` objects keep V.
    static func components(_ value: WPESceneJSONValue,
                           userValues: [String: WallpaperEngineProjectPropertyValue]) -> [Double]? {
        guard case let .string(key)? = value["user"], let user = userValues[key] else {
            return components(value)
        }
        switch user {
        case let .number(number): return [number]
        // WPE's float and vector readers skip a JSON Bool, so the authored value stays.
        case .bool: return components(value)
        case let .string(text): return numbers(text)
        }
    }

    private static func defaultComponents(_ value: Any) -> [Double]? {
        if let number = value as? NSNumber {
            return [number.doubleValue]
        }
        return (value as? String).flatMap(numbers)
    }

    /// Space- or comma-separated, as in `"1 0.2"` and `"0.05, 0.00"`.
    private static func numbers(_ text: String) -> [Double]? {
        let values = text.split { $0.isWhitespace || $0 == "," }.compactMap { Double($0) }
        return values.isEmpty ? nil : values
    }
}
