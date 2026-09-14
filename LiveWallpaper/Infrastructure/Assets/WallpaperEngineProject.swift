#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

struct WallpaperEngineProject: Sendable, Equatable {
    let workshopID: String
    let title: String
    let entryFile: String
    let type: WPEType
    let previewFileName: String?
    let propertyCount: Int
    /// Workshop IDs declared as dependencies in `project.json`.
    let dependencyWorkshopIDs: [String]
    /// `bin/` directory contains a Windows `.dll` plugin. macOS cannot run these.
    let requiresWindowsPlugin: Bool
    /// Singular `dependency` is the preset's base wallpaper; do not merge with the plural `dependencies` array of asset packs.
    let presetBaseWorkshopID: String?
    /// `nil` when the manifest has no `preset` key; an empty map is a preset that overrides nothing.
    let presetValues: [String: WallpaperEngineProjectPropertyValue]?

    init(
        workshopID: String,
        title: String,
        entryFile: String,
        type: WPEType,
        previewFileName: String?,
        propertyCount: Int,
        dependencyWorkshopIDs: [String],
        requiresWindowsPlugin: Bool,
        presetBaseWorkshopID: String? = nil,
        presetValues: [String: WallpaperEngineProjectPropertyValue]? = nil
    ) {
        self.workshopID = workshopID
        self.title = title
        self.entryFile = entryFile
        self.type = type
        self.previewFileName = previewFileName
        self.propertyCount = propertyCount
        self.dependencyWorkshopIDs = dependencyWorkshopIDs
        self.requiresWindowsPlugin = requiresWindowsPlugin
        self.presetBaseWorkshopID = presetBaseWorkshopID
        self.presetValues = presetValues
    }

    /// Returns nil for an ordinary wallpaper so callers can branch on the manifest instead of importing a preset as a wallpaper with no renderable entry.
    func scenePreset() -> ScenePreset? {
        guard let presetBaseWorkshopID, let presetValues else { return nil }
        return .workshop(
            workshopID: workshopID,
            name: title,
            baseWorkshopID: presetBaseWorkshopID,
            values: presetValues
        )
    }

    static func read(from folder: URL) throws -> Self {
        let manifestURL = folder.appendingPathComponent("project.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw WPEProjectError.manifestNotFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw WPEProjectError.manifestUnreadable
        }

        let decoded: DecodedManifest
        do {
            decoded = try JSONDecoder().decode(DecodedManifest.self, from: data)
        } catch {
            throw WPEProjectError.manifestMalformed(error.localizedDescription)
        }

        let workshopID = Self.trimmed(decoded.workshopid) ?? folder.lastPathComponent
        guard WPEPathSafety.isSafeProjectID(workshopID) else {
            throw WPEProjectError.manifestMalformed("Invalid workshop id")
        }

        let presetBase = Self.trimmed(decoded.dependency).flatMap {
            Self.looksLikeWorkshopID($0) ? $0 : nil
        }
        let declaresPreset = presetBase != nil && decoded.preset != nil

        // Only an ABSENT `file` is excused. A present-but-unsafe one ("../..", an absolute path) stays malformed for presets too: treating it as "no entry" would launder a path-traversal attempt into a valid object.
        let entryFile: String
        if let file = Self.trimmed(decoded.file) {
            guard WPEPathSafety.isSafeRelativePath(file) else {
                throw WPEProjectError.manifestMalformed("Invalid project entry file")
            }
            entryFile = file
        } else if declaresPreset, !decoded.fileKeyPresent {
            entryFile = ""
        } else {
            throw WPEProjectError.manifestMalformed("Invalid project entry file")
        }

        return Self(
            workshopID: workshopID,
            title: Self.trimmed(decoded.title) ?? workshopID,
            entryFile: entryFile,
            type: WPEType(rawWPEValue: decoded.type),
            previewFileName: Self.resolvePreviewFileName(decoded.preview, in: folder),
            propertyCount: decoded.general?.properties?.count ?? 0,
            dependencyWorkshopIDs: Self.collectDependencyWorkshopIDs(from: decoded),
            requiresWindowsPlugin: Self.detectsWindowsPlugin(in: folder),
            presetBaseWorkshopID: declaresPreset ? presetBase : nil,
            presetValues: declaresPreset ? (decoded.preset ?? [:]) : nil
        )
    }

    private static func collectDependencyWorkshopIDs(from manifest: DecodedManifest) -> [String] {
        var ids = Set<String>()
        for raw in manifest.dependencies ?? [] {
            if let id = Self.trimmed(raw), Self.looksLikeWorkshopID(id) {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    private static func looksLikeWorkshopID(_ value: String) -> Bool {
        let digits = value.count
        guard (9...20).contains(digits) else { return false }
        return value.allSatisfy(\.isNumber)
    }

    private static func detectsWindowsPlugin(in folder: URL) -> Bool {
        let bin = folder.appendingPathComponent("bin", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bin.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        // `enumerator(at:)` yields nothing when the root itself is a symlink.
        guard let enumerator = FileManager.default.enumerator(
            at: bin.standardizedFileURL.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "dll" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func resolvePreviewFileName(_ manifestValue: String?, in folder: URL) -> String? {
        if let preview = trimmed(manifestValue), WPEPathSafety.isSafeRelativePath(preview) {
            return preview
        }

        for candidate in ["preview.gif", "preview.jpg", "preview.png"] {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return nil
    }

}

enum WPEProjectError: LocalizedError, Equatable, Sendable {
    case manifestNotFound
    case manifestUnreadable
    case manifestMalformed(String)

    var errorDescription: String? {
        switch self {
        case .manifestNotFound:
            String(
                localized: "the folder has no project.json",
                bundle: .appLanguage, comment: "Scene import refusal reason, interpolated into a sentence: the project manifest is absent."
            )
        case .manifestUnreadable:
            String(
                localized: "its project.json could not be read",
                bundle: .appLanguage, comment: "Scene import refusal reason, interpolated into a sentence: the project manifest could not be read."
            )
        case let .manifestMalformed(detail):
            String(
                localized: "its project.json is malformed (\(detail))",
                bundle: .appLanguage, comment: "Scene import refusal reason, interpolated into a sentence; the placeholder is the parser's detail."
            )
        }
    }
}

private struct DecodedManifest: Decodable, Sendable {
    let workshopid: String?
    let title: String?
    let file: String?
    let type: String?
    let preview: String?
    let general: DecodedGeneral?
    let dependencies: [String]?
    let dependency: String?
    let preset: [String: WallpaperEngineProjectPropertyValue]?
    /// `null`, `""` and whitespace all decode to a nil `file`, but only a preset with the key genuinely absent may skip the entry requirement.
    let fileKeyPresent: Bool

    private enum CodingKeys: String, CodingKey {
        case workshopid
        case title
        case file
        case type
        case preview
        case general
        case dependencies
        case dependency
        case preset
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workshopid = try container.decodeFlexibleString(forKey: .workshopid)
        title = try container.decodeFlexibleString(forKey: .title)
        file = try container.decodeFlexibleString(forKey: .file)
        type = try container.decodeFlexibleString(forKey: .type)
        preview = try container.decodeFlexibleString(forKey: .preview)
        general = try? container.decode(DecodedGeneral.self, forKey: .general)
        dependencies = try container.decodeFlexibleStringArray(forKey: .dependencies)
        dependency = try container.decodeFlexibleString(forKey: .dependency)
        preset = container.decodeLossyStringDictionary(forKey: .preset)
        fileKeyPresent = container.contains(.file)
    }
}

private struct DecodedGeneral: Decodable, Sendable {
    let properties: [String: IgnoredJSON]?
}

private struct IgnoredJSON: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        if let value = try? decode(String.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decode(Int64.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func decodeFlexibleStringArray(forKey key: Key) throws -> [String]? {
        guard contains(key) else { return nil }
        if let strings = try? decode([String].self, forKey: key) {
            return strings
        }
        if let ints = try? decode([Int64].self, forKey: key) {
            return ints.map(String.init)
        }
        guard var nested = try? nestedUnkeyedContainer(forKey: key) else {
            return nil
        }
        var values: [String] = []
        while !nested.isAtEnd {
            if let s = try? nested.decode(String.self) {
                values.append(s)
            } else if let i = try? nested.decode(Int64.self) {
                values.append(String(i))
            } else {
                _ = try? nested.decode(Empty.self)
            }
        }
        return values
    }

    private struct Empty: Decodable { init(from decoder: Decoder) throws {} }

}
#endif
