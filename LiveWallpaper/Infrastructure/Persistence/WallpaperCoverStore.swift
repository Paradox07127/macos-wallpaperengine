import AppKit
import Foundation
import LiveWallpaperCore

/// On-disk covers for saved bookmarks and schemes: one PNG per entry, named by
/// the entry's UUID, beside the JSON archives that reference them.
///
/// A cover is a still of what the display was actually showing when the entry
/// was saved, so unlike the computed thumbnails it cannot be regenerated — it
/// has to outlive the process.
@MainActor
final class WallpaperCoverStore {
    static let shared = WallpaperCoverStore()

    /// Decoded covers, so a grid scrolling through 50 tiles does not re-read and
    /// re-decode PNGs off disk on every appearance.
    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 128
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    private let root: URL
    private let fileManager: FileManager

    init(
        directory: ConfigurationDirectory = ConfigurationDirectory(),
        fileManager: FileManager = .default
    ) {
        root = directory.root.appendingPathComponent("Covers", isDirectory: true)
        self.fileManager = fileManager
    }

    // MARK: - Read

    func cover(named fileName: String) -> NSImage? {
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }
        let url = root.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        cache.setObject(image, forKey: fileName as NSString, cost: Self.cost(of: image))
        return image
    }

    // MARK: - Write

    /// Returns the stored file name, or nil when the image could not be encoded
    /// or written — callers keep their existing cover in that case rather than
    /// recording a name that resolves to nothing.
    @discardableResult
    func store(_ image: NSImage, for id: UUID) -> String? {
        guard let data = Self.pngData(from: image) else { return nil }
        let fileName = Self.fileName(for: id)
        let url = root.appendingPathComponent(fileName, isDirectory: false)
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.warning("Cover write failed: \(error.localizedDescription)", category: .ui)
            return nil
        }
        cache.setObject(image, forKey: fileName as NSString, cost: Self.cost(of: image))
        return fileName
    }

    func remove(named fileName: String) {
        cache.removeObject(forKey: fileName as NSString)
        try? fileManager.removeItem(at: root.appendingPathComponent(fileName, isDirectory: false))
    }

    /// Deletes covers no surviving entry names. Entries and their covers are
    /// written by different code paths (a rename never touches the PNG, a failed
    /// write leaves the name unset), so the archive is the authority and this
    /// sweeps whatever the archive no longer points at.
    func removeOrphans(keeping liveFileNames: Set<String>) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where !liveFileNames.contains(name) {
            remove(named: name)
        }
    }

    func removeAll() {
        cache.removeAllObjects()
        try? fileManager.removeItem(at: root)
    }

    // MARK: - Naming and encoding

    /// One cover per entry id. A replaced cover overwrites its predecessor, so
    /// there is never a second file to garbage-collect for the same entry.
    static func fileName(for id: UUID) -> String {
        "\(id.uuidString).png"
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        // `size` follows the CGImage's pixels so the written PNG is not scaled
        // by whatever backing scale the source NSImage happened to carry.
        rep.size = NSSize(width: cgImage.width, height: cgImage.height)
        return rep.representation(using: .png, properties: [:])
    }

    private static func cost(of image: NSImage) -> Int {
        let pixels = image.representations
            .compactMap { $0 as? NSBitmapImageRep }
            .map { $0.pixelsWide * $0.pixelsHigh }
            .max()
            ?? Int(image.size.width * image.size.height)
        return pixels * 4
    }
}
