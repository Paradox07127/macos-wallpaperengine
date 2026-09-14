#if !LITE_BUILD
import CryptoKit
import Foundation

/// Encoded image bytes only — a URLCache on the ephemeral session would persist response headers. File name is SHA-256 of the key so a directory listing does not disclose which previews were browsed.
final class WorkshopPreviewDiskCache: Sendable {

    static let shared = WorkshopPreviewDiskCache()

    /// LRU hard cap. A Workshop page is 50 items and a Steam preview is ~100–400 KB, so this holds on the order of a thousand previews.
    static let defaultCapBytes: Int64 = 256 * 1024 * 1024

    /// Steam serves a replaced preview under the same `preview_url`, so an
    /// entry the cap never reaches would show the old picture forever.
    static let defaultTimeToLive: TimeInterval = 30 * 24 * 60 * 60

    private static let fileExtension = "bin"

    private let disk: WorkshopDiskCacheStore

    init(
        directoryURL: URL? = nil,
        capBytes: Int64 = defaultCapBytes,
        timeToLive: TimeInterval = defaultTimeToLive,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        disk = WorkshopDiskCacheStore(
            directoryURL: directoryURL ?? Self.defaultDirectoryURL(),
            fileExtension: Self.fileExtension,
            capBytes: capBytes,
            timeToLive: timeToLive,
            // Expiry runs against creationDate, not modificationDate: modificationDate is the LRU stamp and is bumped on every read, so a frequently viewed preview would never expire.
            expiryClock: .creationDate,
            maxEntryBytes: Int64(WorkshopAnimatedGIF.maxBytes),
            queueLabel: "com.loomscreen.workshop-preview-disk-cache",
            now: now
        )
    }

    // MARK: - API

    /// The bytes previously stored for this URL *at this size*, or `nil`.
    func data(for url: URL, size: WorkshopPreviewSize) async -> Data? {
        await disk.read(named: Self.fileName(for: url, size: size))
    }

    func store(_ data: Data, for url: URL, size: WorkshopPreviewSize) async {
        guard !data.isEmpty, data.count <= WorkshopAnimatedGIF.maxBytes else { return }
        await disk.write(data, named: Self.fileName(for: url, size: size))
    }

    func sizeBytes() async -> Int64 {
        await disk.sizeBytes()
    }

    /// Size is part of the key, not just of the decode: Steam serves one preview_url for tile and hero, decoded to different pixel caps.
    static func fileName(for url: URL, size: WorkshopPreviewSize) -> String {
        let key = "v1|\(size.rawValue)|\(url.absoluteString)"
        let digest = SHA256.hash(data: Data(key.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(digest).\(fileExtension)"
    }

    /// .cachesDirectory rather than Application Support: previews are re-downloadable, and the system reclaims Caches under disk pressure.
    private static func defaultDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let caches = (try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? "com.loomscreen.pro", isDirectory: true
            )
            .appendingPathComponent("WorkshopPreviews", isDirectory: true)
    }
}
#endif
