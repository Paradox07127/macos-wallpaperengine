#if DEBUG
import CryptoKit
import Foundation
import LiveWallpaperCore

/// Identity and revisions only cross the bridge; grants stay in the app.
@MainActor
enum QALibraryCatalog {
    struct Entry {
        let item: LibraryItem
        let id: String
        let revision: String
        let bookmarked: Bool

        var sourceKind: String {
            switch item.source {
            case .bookmark: "saved"
            case .aerial: "aerial"
            #if !LITE_BUILD
            case .workshop: item.isSteam ? "steam" : "local"
            #endif
            }
        }

        var contentType: WallpaperType {
            switch item.kind {
            case .video, .aerial: .video
            case .web: .html
            case .scene: .scene
            }
        }

        var wallpaperType: String {
            switch item.kind {
            case .video, .aerial: "video"
            case .web: "html"
            case .scene: "scene"
            }
        }

        var json: [String: Any] {
            ["itemID": id, "revision": revision, "title": item.title,
             "sourceKind": sourceKind, "wallpaperType": wallpaperType,
             "isBookmarked": bookmarked, "isVariant": item.isVariant,
             "parentID": item.parentID.map { QALibraryCatalog.identifier($0) } ?? NSNull(),
             "supported": item.isSupported, "availability": "unknown",
             "onDisplays": item.onDisplays]
        }
    }

    static func entries(inputs: SavedLibraryModel.Inputs) throws -> [Entry] {
        let snapshot = SavedLibraryModel.catalogSnapshot(inputs: inputs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try snapshot.items.map { item in
            var bytes = Data(item.id.utf8)
            switch item.source {
            case let .bookmark(bookmark):
                try bytes.append(encoder.encode(bookmark.content))
                try bytes.append(encoder.encode(bookmark.wpeOrigin))
            case let .aerial(asset):
                bytes.append(asset.bookmarkData)
            #if !LITE_BUILD
            case let .workshop(entry):
                try bytes.append(encoder.encode(entry.origin))
                try bytes.append(encoder.encode(entry.importedAt))
            #endif
            }
            return Entry(item: item, id: identifier(item.id), revision: digest(bytes),
                         bookmarked: snapshot.bookmarkedIDs.contains(item.id))
        }.sorted { $0.id < $1.id }
    }

    nonisolated static func identifier(_ internalID: String) -> String {
        "item:" + digest(Data(internalID.utf8))
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func list(_ entries: [Entry], arguments: [String: Any]) throws -> [String: Any] {
        try validateKeys(arguments, allowed: ["source", "type", "bookmarked", "query", "limit", "cursor"])
        let source = try choice(arguments["source"], key: "source", choices: ["all", "saved", "steam", "local", "aerial"], fallback: "all")
        let type = try choice(arguments["type"], key: "type", choices: ["all", "video", "html", "scene"], fallback: "all")
        let query = try optionalString(arguments["query"], key: "query") ?? ""
        let marked = try arguments["bookmarked"].map { try boolean($0, key: "bookmarked") }
        let limit = try integer(arguments["limit"] ?? 50, key: "limit", range: 1 ... 200)
        let filters = "\(source)|\(type)|\(String(describing: marked))|\(query)"
        let revision = digest(Data((filters + entries.map { "\($0.id):\($0.revision):\($0.bookmarked):\($0.item.title)" }.joined(separator: "|")).utf8))
        var offset = 0
        if let cursor = try optionalString(arguments["cursor"], key: "cursor") {
            let parts = cursor.split(separator: ":")
            guard parts.count == 2, parts[0] == revision, let parsed = Int(parts[1]), parsed >= 0 else {
                throw QAControlPlane.QAError.message("Stale or invalid cursor; restart library.list")
            }
            offset = parsed
        }
        let filtered = entries.filter {
            (source == "all" || $0.sourceKind == source)
                && (type == "all" || $0.wallpaperType == type)
                && (marked == nil || $0.bookmarked == marked)
                && (query.isEmpty || $0.item.title.localizedCaseInsensitiveContains(query))
        }
        guard offset <= filtered.count else { throw QAControlPlane.QAError.message("Invalid cursor offset") }
        let end = min(offset + limit, filtered.count)
        return ["items": filtered[offset ..< end].map(\.json), "count": end - offset,
                "total": filtered.count, "catalogRevision": revision,
                "nextCursor": end < filtered.count ? "\(revision):\(end)" : NSNull()]
    }

    static func resolve(_ entries: [Entry], arguments: [String: Any]) throws -> Entry {
        guard let id = try optionalString(arguments["itemID"], key: "itemID"),
              let entry = entries.first(where: { $0.id == id }) else {
            throw QAControlPlane.QAError.message("Unknown library item; call library.list")
        }
        if let revision = try optionalString(arguments["expectedItemRevision"], key: "expectedItemRevision"), revision != entry.revision {
            throw QAControlPlane.QAError.message("Library item changed; read its revision again")
        }
        return entry
    }

    static func validateKeys(_ arguments: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(arguments.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw QAControlPlane.QAError.message("Unknown arguments: \(unknown.sorted().joined(separator: ", "))") }
    }

    static func optionalString(_ value: Any?, key: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String, string.count <= 1024 else { throw QAControlPlane.QAError.message("Rejected \(key): expected a string of at most 1024 characters") }
        return string
    }

    static func boolean(_ value: Any, key: String) throws -> Bool {
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let result = value as? Bool else {
            throw QAControlPlane.QAError.message("Rejected \(key): expected a boolean")
        }
        return result
    }

    static func integer(_ value: Any, key: String, range: ClosedRange<Int>) throws -> Int {
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(), let number = value as? NSNumber,
              let result = Int(exactly: number.doubleValue), range.contains(result) else {
            throw QAControlPlane.QAError.message("Rejected \(key): expected an integer from \(range.lowerBound) through \(range.upperBound)")
        }
        return result
    }

    private static func choice(_ value: Any?, key: String, choices: [String], fallback: String) throws -> String {
        let result = try optionalString(value, key: key) ?? fallback
        guard choices.contains(result) else { throw QAControlPlane.QAError.message("Rejected \(key): use \(choices.joined(separator: ", "))") }
        return result
    }
}
#endif
