import AppKit
import Foundation
import ImageIO
import LiveWallpaperCore

@MainActor
final class WallpaperCoverStore {
    static let shared = WallpaperCoverStore()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 128
        c.totalCostLimit = 48 * 1024 * 1024
        return c
    }()

    private let reads: PreviewRequestPool<CGImage>
    private var readGenerations: [String: UUID] = [:]

    private let root: URL
    private let fileManager: FileManager

    init(
        directory: ConfigurationDirectory = ConfigurationDirectory(),
        fileManager: FileManager = .default,
        readGate: PreviewWorkGate = .shared
    ) {
        root = directory.root.appendingPathComponent("Covers", isDirectory: true)
        self.fileManager = fileManager
        reads = PreviewRequestPool(gate: readGate)
    }

    // MARK: - Read

    func cover(named fileName: String) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.object(forKey: fileName as NSString) {
            return cached
        }
        let generation = readGenerations[fileName] ?? UUID()
        readGenerations[fileName] = generation
        let url = root.appendingPathComponent(fileName, isDirectory: false)
        let decoded = await reads.value(for: fileName) {
            let worker = Task.detached(priority: .utility) { () -> CGImage? in
                guard !Task.isCancelled,
                      let data = try? Data(contentsOf: url),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      !Task.isCancelled else { return nil }
                return CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
            }
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
        }
        guard !Task.isCancelled else { return nil }
        guard readGenerations[fileName] == generation else {
            return cache.object(forKey: fileName as NSString)
        }
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
        cache.setObject(image, forKey: fileName as NSString, cost: decoded.bytesPerRow * decoded.height)
        return image
    }

    private func invalidateRead(_ fileName: String) {
        readGenerations.removeValue(forKey: fileName)
        reads.invalidate(fileName)
    }

    // MARK: - Write

    /// Returns the stored file name, or nil when encode/write failed — callers keep their existing cover rather than recording a name that resolves to nothing.
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
        invalidateRead(fileName)
        cache.setObject(image, forKey: fileName as NSString, cost: Self.cost(of: image))
        return fileName
    }

    func remove(named fileName: String) {
        invalidateRead(fileName)
        cache.removeObject(forKey: fileName as NSString)
        try? fileManager.removeItem(at: root.appendingPathComponent(fileName, isDirectory: false))
    }

    func removeOrphans(keeping liveFileNames: Set<String>) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where !liveFileNames.contains(name) {
            remove(named: name)
        }
    }

    func removeAll() {
        readGenerations.removeAll()
        reads.invalidateAll()
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
