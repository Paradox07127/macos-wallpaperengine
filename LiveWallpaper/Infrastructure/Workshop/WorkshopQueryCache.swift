#if !LITE_BUILD
import CryptoKit
import Foundation

/// On-disk cache for `WorkshopQueryService` paged results: JSON pages in a
/// `WorkshopDiskCacheStore`, expired 5 minutes after they were written, under a
/// 100 MB hard cap.
actor WorkshopQueryCache {

    private static let ttl: TimeInterval = 300
    private static let hardCapBytes: Int64 = 100 * 1024 * 1024

    private let disk: WorkshopDiskCacheStore

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        disk = WorkshopDiskCacheStore(
            directoryURL: directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager),
            fileExtension: "json",
            capBytes: Self.hardCapBytes,
            timeToLive: Self.ttl,
            // Creation date, not mtime: `read` bumps mtime for LRU, so an mtime
            // TTL never expires a page the user keeps paging back to.
            expiryClock: .creationDate,
            queueLabel: "com.livewallpaper.workshop-query-cache.disk",
            now: now
        )
        disk.sweepOnce()
    }

    func read(forKey key: String) async -> WorkshopQueryPage? {
        guard let data = await disk.read(named: Self.safeFileName(forKey: key)) else { return nil }
        return (try? JSONDecoder().decode(CachedPagePayload.self, from: data))?.page
    }

    func write(_ page: WorkshopQueryPage, forKey key: String) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(CachedPagePayload(page: page)) else { return }
        await disk.write(data, named: Self.safeFileName(forKey: key))
    }

    func sizeBytes() async -> Int64 {
        await disk.sizeBytes()
    }

    func clear() async {
        await disk.clear()
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        let applicationSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("Loomscreen", isDirectory: true)
            .appendingPathComponent("WorkshopQueryCache", isDirectory: true)
    }

    private static func safeFileName(forKey key: String) -> String {
        let lower = key.lowercased()
        if lower.range(of: #"^[a-f0-9]{64}$"#, options: [.regularExpression, .anchored]) != nil {
            return "\(lower).json"
        }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(digest).json"
    }
}

private struct CachedPagePayload: Codable {
    /// 2: `sourceItemCount` + `totalPages` (keyless pages moved to the SSR
    /// payload). 3: `rating` replaces `voteScore`, plus `timeCreated`,
    /// `commentCount`, `requiredItemIDs`. 4: `title` is the wire title (nil
    /// when untitled), not the localized fallback. Older pages miss so a
    /// stale page cannot outlive the upgrade for its TTL.
    static let currentSchemaVersion = 4

    let schemaVersion: Int?
    let items: [CachedItemPayload]
    let nextCursor: String?
    let totalAvailable: Int?
    let sourceItemCount: Int
    let totalPages: Int?

    init(page: WorkshopQueryPage) {
        schemaVersion = Self.currentSchemaVersion
        items = page.items.map(CachedItemPayload.init(item:))
        nextCursor = page.nextCursor
        totalAvailable = page.totalAvailable
        sourceItemCount = page.sourceItemCount
        totalPages = page.totalPages
    }

    var page: WorkshopQueryPage? {
        guard schemaVersion == Self.currentSchemaVersion else { return nil }
        let decoded = items.compactMap(\.item)
        guard decoded.count == items.count else { return nil }
        return WorkshopQueryPage(
            items: decoded,
            nextCursor: nextCursor,
            totalAvailable: totalAvailable,
            sourceItemCount: sourceItemCount,
            totalPages: totalPages
        )
    }
}

private struct CachedItemPayload: Codable {
    let id: UInt64
    /// The wire title, `nil` when untitled — never the localized fallback.
    let title: String?
    let shortDescription: String
    let creatorID: String?
    let creatorPersonaName: String?
    let previewImageURL: String?
    let fileSizeBytes: UInt64?
    let timeUpdated: Date?
    let subscriptionCount: Int?
    let viewCount: Int?
    let favoriteCount: Int?
    let rating: WorkshopRating?
    let timeCreated: Date?
    let commentCount: Int?
    let requiredItemIDs: [UInt64]
    let tags: [String]
    let visibility: String
    let isBanned: Bool
    let steamCommunityURL: String

    init(item: WorkshopQueryItem) {
        self.id = item.id
        title = item.rawTitle
        self.shortDescription = item.shortDescription
        self.creatorID = item.creatorID
        self.creatorPersonaName = item.creatorPersonaName
        self.previewImageURL = item.previewImageURL?.absoluteString
        self.fileSizeBytes = item.fileSizeBytes
        self.timeUpdated = item.timeUpdated
        self.subscriptionCount = item.subscriptionCount
        self.viewCount = item.viewCount
        self.favoriteCount = item.favoriteCount
        rating = item.rating
        timeCreated = item.timeCreated
        commentCount = item.commentCount
        requiredItemIDs = item.requiredItemIDs
        self.tags = item.tags
        self.visibility = item.visibility.rawValue
        self.isBanned = item.isBanned
        self.steamCommunityURL = item.steamCommunityURL.absoluteString
    }

    var item: WorkshopQueryItem? {
        guard let communityURL = URL(string: steamCommunityURL) else { return nil }
        let previewURL = previewImageURL.flatMap { URL(string: $0) }
        return WorkshopQueryItem(
            id: id,
            rawTitle: title,
            shortDescription: shortDescription,
            creatorID: creatorID,
            creatorPersonaName: creatorPersonaName,
            previewImageURL: previewURL,
            fileSizeBytes: fileSizeBytes,
            timeUpdated: timeUpdated,
            subscriptionCount: subscriptionCount,
            viewCount: viewCount,
            favoriteCount: favoriteCount,
            rating: rating,
            timeCreated: timeCreated,
            commentCount: commentCount,
            requiredItemIDs: requiredItemIDs,
            tags: tags,
            visibility: SteamWorkshopMetadata.Visibility(rawValue: visibility) ?? .unknown,
            isBanned: isBanned,
            steamCommunityURL: communityURL
        )
    }
}
#endif
