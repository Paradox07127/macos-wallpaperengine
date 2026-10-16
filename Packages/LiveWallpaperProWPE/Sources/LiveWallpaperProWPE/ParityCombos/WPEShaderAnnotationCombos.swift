import Foundation

public struct WPEShaderSamplerCombos: Sendable, Equatable {
    public var combo: String
    public var formatCombo: Bool
    public var defaultTexture: String
    public var componentCombos: [String]

    public init(combo: String = "", formatCombo: Bool = false, defaultTexture: String = "", componentCombos: [String] = []) {
        self.combo = combo
        self.formatCombo = formatCombo
        self.defaultTexture = defaultTexture
        self.componentCombos = componentCombos
    }
}

/// Sources have includes expanded before annotation parsing (FUN_140162100).
public struct WPEShaderAnnotationCombos: Sendable {
    public let defaults: WPEMSVCUnorderedMap<String, Int32>
    public let samplers: WPEMSVCUnorderedMap<Int32, WPEShaderSamplerCombos>

    public init(vertexSource: String, fragmentSource: String) {
        var defaults = WPEMSVCUnorderedMap<String, Int32>()
        var samplers = WPEMSVCUnorderedMap<Int32, WPEShaderSamplerCombos>()
        for source in [vertexSource, fragmentSource] {
            for line in source.components(separatedBy: .newlines) {
                let text = line.drop(while: { $0 == " " || $0 == "\t" })
                if text.hasPrefix("uniform") {
                    guard let slot = Self.samplerSlot(String(text)),
                          let comment = line.range(of: "//"),
                          let json = Self.json(String(line[comment.upperBound...])) else { continue }
                    let components = (json["components"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
                    samplers.set(slot, value: WPEShaderSamplerCombos(
                        combo: json["combo"] as? String ?? "",
                        formatCombo: Self.truthy(json["formatcombo"]),
                        defaultTexture: json["default"] as? String ?? "",
                        componentCombos: components.map { $0["combo"] as? String ?? "" }
                    ))
                } else if text.hasPrefix("// [COMBO]") {
                    guard let json = Self.json(String(text.dropFirst("// [COMBO]".count))),
                          let name = json["combo"] as? String else { continue }
                    defaults.set(name, value: Self.integer(json["default"]))
                }
            }
        }
        self.defaults = defaults.copyAssigned()
        self.samplers = samplers.copyAssigned().copyAssigned()
    }

    private static func samplerSlot(_ line: String) -> Int32? {
        let pattern = #"^uniform\s+sampler\w*\s+g_Texture([0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Int32(line[range])
    }

    private static func json(_ text: String) -> [String: Any]? {
        func decode(_ value: String) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
        }
        if let result = decode(text) {
            return result
        }
        guard let end = text.lastIndex(of: "}") else { return nil }
        return decode(String(text[...end]))
    }

    private static func integer(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber {
            return number.int32Value
        }
        if let string = value as? String {
            return Int32(string.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        return 0
    }

    private static func truthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let number = value as? NSNumber {
            return number.doubleValue != 0
        }
        if let string = value as? String {
            return !string.isEmpty
        }
        if let array = value as? [Any] {
            return !array.isEmpty
        }
        if let dictionary = value as? [String: Any] {
            return !dictionary.isEmpty
        }
        return false
    }
}
