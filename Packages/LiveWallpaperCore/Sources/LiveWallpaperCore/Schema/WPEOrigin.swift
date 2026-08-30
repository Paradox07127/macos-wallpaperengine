import Foundation

/// WPE Workshop provenance in Core so Lite↔Pro round-trips losslessly.
public struct WPEOrigin: Codable, Equatable, Sendable {
    public let workshopID: String
    public let title: String
    /// WPE category even when runtime maps to video/html.
    public let originalType: WPEType
    /// Security-scoped grant for the source Live Wallpapers project folder.
    public let sourceFolderBookmark: Data
    /// Under WPE cache root; nil for source-folder web / unsupported.
    public var cacheRelativePath: String?
    public let previewFileName: String?
    public let entryFile: String?
    /// Explicit backing — do not overload `cacheRelativePath == nil`.
    public let resourceLocation: WPEResourceLocation
    public var dependencyWorkshopIDs: [String]
    public var missingDependencyIDs: [String]
    /// Windows `bin/*.dll` plugin — never runs on macOS ("won't run" badge).
    public var requiresWindowsPlugin: Bool

    /// Gates nonpersistent web storage for Workshop content.
    public var originKind: HTMLOriginKind

    public init(
        workshopID: String,
        title: String,
        originalType: WPEType,
        sourceFolderBookmark: Data,
        cacheRelativePath: String?,
        previewFileName: String?,
        entryFile: String? = nil,
        resourceLocation: WPEResourceLocation? = nil,
        dependencyWorkshopIDs: [String] = [],
        missingDependencyIDs: [String] = [],
        requiresWindowsPlugin: Bool = false,
        originKind: HTMLOriginKind = .userLocal
    ) {
        self.workshopID = workshopID
        self.title = title
        self.originalType = originalType
        self.sourceFolderBookmark = sourceFolderBookmark
        self.cacheRelativePath = cacheRelativePath
        self.previewFileName = previewFileName
        self.entryFile = entryFile
        self.resourceLocation = resourceLocation ?? Self.defaultResourceLocation(
            originalType: originalType,
            cacheRelativePath: cacheRelativePath
        )
        self.dependencyWorkshopIDs = dependencyWorkshopIDs
        self.missingDependencyIDs = missingDependencyIDs
        self.requiresWindowsPlugin = requiresWindowsPlugin
        self.originKind = originKind
    }

    private enum CodingKeys: String, CodingKey {
        case workshopID
        case title
        case originalType
        case sourceFolderBookmark
        case cacheRelativePath
        case previewFileName
        case entryFile
        case resourceLocation
        case dependencyWorkshopIDs
        case missingDependencyIDs
        case requiresWindowsPlugin
        case originKind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workshopID = try container.decode(String.self, forKey: .workshopID)
        title = try container.decode(String.self, forKey: .title)
        originalType = try container.decode(WPEType.self, forKey: .originalType)
        sourceFolderBookmark = try container.decode(Data.self, forKey: .sourceFolderBookmark)
        cacheRelativePath = try container.decodeIfPresent(String.self, forKey: .cacheRelativePath)
        previewFileName = try container.decodeIfPresent(String.self, forKey: .previewFileName)
        entryFile = try container.decodeIfPresent(String.self, forKey: .entryFile)
        resourceLocation = try container.decodeIfPresent(WPEResourceLocation.self, forKey: .resourceLocation)
            ?? Self.defaultResourceLocation(originalType: originalType, cacheRelativePath: cacheRelativePath)
        dependencyWorkshopIDs = (try? container.decodeIfPresent([String].self, forKey: .dependencyWorkshopIDs)) ?? []
        missingDependencyIDs = (try? container.decodeIfPresent([String].self, forKey: .missingDependencyIDs)) ?? []
        requiresWindowsPlugin = (try? container.decodeIfPresent(Bool.self, forKey: .requiresWindowsPlugin)) ?? false
        originKind = (try? container.decodeIfPresent(HTMLOriginKind.self, forKey: .originKind)) ?? .userLocal
    }

    public var localizedDisplayTypeName: String {
        originalType.localizedDisplayName
    }

    /// CAS source-folder grant; `nil` protects a newer re-grant from a late refresh.
    public func replacingSourceFolderBookmark(
        matching original: Data,
        with refreshed: Data
    ) -> WPEOrigin? {
        guard sourceFolderBookmark == original else { return nil }
        return WPEOrigin(
            workshopID: workshopID,
            title: title,
            originalType: originalType,
            sourceFolderBookmark: refreshed,
            cacheRelativePath: cacheRelativePath,
            previewFileName: previewFileName,
            entryFile: entryFile,
            resourceLocation: resourceLocation,
            dependencyWorkshopIDs: dependencyWorkshopIDs,
            missingDependencyIDs: missingDependencyIDs,
            requiresWindowsPlugin: requiresWindowsPlugin,
            originKind: originKind
        )
    }

    public static func defaultResourceLocation(
        originalType: WPEType,
        cacheRelativePath: String?
    ) -> WPEResourceLocation {
        if let cacheRelativePath, !cacheRelativePath.isEmpty {
            return .cache
        }
        if originalType == .web {
            return .sourceFolder
        }
        return .unsupported
    }
}

public enum WPEResourceLocation: String, Codable, Equatable, Sendable {
    case cache
    case sourceFolder
    case unsupported
}

/// `project.json` `type` field.
public enum WPEType: String, Codable, Equatable, Sendable {
    case video
    case web
    case scene
    case application
    case unknown

    public init(rawWPEValue raw: String?) {
        switch raw?.lowercased() {
        case "video":       self = .video
        case "web":         self = .web
        case "scene":       self = .scene
        case "application": self = .application
        default:            self = .unknown
        }
    }

    public var localizedDisplayName: String {
        switch self {
        case .video:
            return String(localized: "Video", defaultValue: "Video", bundle: .appLanguage, comment: "Wallpaper Engine project type.")
        case .web:
            return String(localized: "Web", defaultValue: "Web", bundle: .appLanguage, comment: "Wallpaper Engine project type.")
        case .scene:
            return String(localized: "Scene", defaultValue: "Scene", bundle: .appLanguage, comment: "Wallpaper Engine project type.")
        case .application:
            return String(localized: "App", defaultValue: "App", bundle: .appLanguage, comment: "Wallpaper Engine project type.")
        case .unknown:
            return String(localized: "Unknown", defaultValue: "Unknown", bundle: .appLanguage, comment: "Wallpaper Engine project type.")
        }
    }
}
