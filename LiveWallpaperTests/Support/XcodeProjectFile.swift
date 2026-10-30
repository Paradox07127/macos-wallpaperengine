import Foundation
import Testing

/// `project.xcproj`, Xcode's JSON project format. It writes trailing commas, so it is read as JSON5.
struct XcodeProjectFile {
    static let relativePath = "\(RepositoryRoot.projectFileName)/project.xcproj"

    let root: [String: Any]

    init() throws {
        let parsed = try JSONSerialization.jsonObject(with: RepositoryRoot.data(Self.relativePath), options: .json5Allowed)
        root = try #require(parsed as? [String: Any], "\(Self.relativePath) is not a JSON object")
    }

    var configurations: [String] {
        root["configurations"] as? [String] ?? []
    }

    var targets: [[String: Any]] {
        root["targets"] as? [[String: Any]] ?? []
    }

    func target(_ name: String) throws -> [String: Any] {
        try #require(targets.first { $0["name"] as? String == name }, "no target \(name) in \(Self.relativePath)")
    }

    /// Resolved like Xcode: the target's own value, its xcconfig, then the project's; nil = set in none.
    /// List values come back space-joined.
    func setting(_ key: String, target name: String, configuration: String) throws -> String? {
        let target = try target(name)
        if let value = Self.value(key, configuration: configuration, in: target["build-settings"]) {
            return value
        }
        let specialized = target["specialized-configurations"] as? [[String: String]] ?? []
        if let file = specialized.first(where: { $0["name"] == configuration })?["file"],
           let value = try Self.xcconfigValue(key, in: RepositoryRoot.source(file)) {
            return value
        }
        return Self.value(key, configuration: configuration, in: root["build-settings"])
    }

    private static func value(_ key: String, configuration: String, in settings: Any?) -> String? {
        guard let settings = settings as? [String: Any] else { return nil }
        switch settings["\(key)[config=\(configuration)]"] ?? settings[key] {
        case let value as String: return value
        case let values as [String]: return values.joined(separator: " ")
        default: return nil
        }
    }

    private static func xcconfigValue(_ key: String, in xcconfig: String) -> String? {
        for line in xcconfig.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key) = ") {
                return String(trimmed.dropFirst(key.count + 3))
            }
        }
        return nil
    }
}
