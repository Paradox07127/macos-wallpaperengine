import Foundation

public struct ScenePreset: Identifiable, Codable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// Its own workshop id, distinct from `baseWorkshopID`.
        case workshop(workshopID: String)
        case local
    }

    /// Workshop presets key on their workshop id; local presets get a UUID.
    public let id: String
    public var name: String
    /// Workshop id of the wallpaper these values belong to; applying a preset to a
    /// different scene would push unrelated keys at the renderer.
    public let baseWorkshopID: String
    public var values: [String: WallpaperEngineProjectPropertyValue]
    public let source: Source
    public let createdAt: Date
    /// Set once the user renames this preset, and only then.
    public private(set) var hasUserAssignedName: Bool

    private init(
        id: String,
        name: String,
        baseWorkshopID: String,
        values: [String: WallpaperEngineProjectPropertyValue],
        source: Source,
        createdAt: Date = Date(),
        hasUserAssignedName: Bool = false
    ) {
        self.id = id
        self.name = name
        self.baseWorkshopID = baseWorkshopID
        self.values = values
        self.source = source
        self.createdAt = createdAt
        self.hasUserAssignedName = hasUserAssignedName
    }

    public func renamed(to newName: String) -> ScenePreset {
        var copy = self
        copy.name = newName
        copy.hasUserAssignedName = true
        return copy
    }

    public static func workshop(
        workshopID: String,
        name: String,
        baseWorkshopID: String,
        values: [String: WallpaperEngineProjectPropertyValue],
        createdAt: Date = Date()
    ) -> ScenePreset {
        ScenePreset(
            id: workshopID,
            name: name,
            baseWorkshopID: baseWorkshopID,
            values: values,
            source: .workshop(workshopID: workshopID),
            createdAt: createdAt
        )
    }

    public static func local(
        name: String,
        baseWorkshopID: String,
        values: [String: WallpaperEngineProjectPropertyValue],
        id: String = UUID().uuidString,
        createdAt: Date = Date()
    ) -> ScenePreset {
        ScenePreset(
            id: id,
            name: name,
            baseWorkshopID: baseWorkshopID,
            values: values,
            source: .local,
            createdAt: createdAt
        )
    }



    private enum CodingKeys: String, CodingKey {
        case id, name, baseWorkshopID, values, source, createdAt, hasUserAssignedName
    }

    /// Do not fall back to the synthesized decoder: it throws on a missing key, and the
    /// entry-by-entry library decode would silently drop every stored preset.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        baseWorkshopID = try container.decode(String.self, forKey: .baseWorkshopID)
        values = try container.decode(
            [String: WallpaperEngineProjectPropertyValue].self, forKey: .values
        )
        source = try container.decode(Source.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        hasUserAssignedName =
            try container.decodeIfPresent(Bool.self, forKey: .hasUserAssignedName) ?? false
    }

    public static func incrementDivergingFromPreset(
        preset: ScenePreset?,
        increment: [String: WallpaperEngineProjectPropertyValue]
    ) -> [String: WallpaperEngineProjectPropertyValue] {
        guard let preset else { return increment }
        return increment.filter { key, value in
            preset.values[key] != value
        }
    }
}

extension ScenePreset.Source: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case workshopID
    }

    private enum Kind: String, Codable {
        case workshop
        case local
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .workshop:
            self = .workshop(workshopID: try container.decode(String.self, forKey: .workshopID))
        case .local:
            self = .local
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workshop(let workshopID):
            try container.encode(Kind.workshop, forKey: .kind)
            try container.encode(workshopID, forKey: .workshopID)
        case .local:
            try container.encode(Kind.local, forKey: .kind)
        }
    }
}
