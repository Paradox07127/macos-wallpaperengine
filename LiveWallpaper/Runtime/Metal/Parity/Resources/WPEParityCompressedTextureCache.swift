#if !LITE_BUILD
import CryptoKit
import Foundation
import LiveWallpaperProWPE
import os

/// One file per encoded image under Caches/wpe-parity-textures/v1, evicted least recently used first.
final class WPEParityCompressedTextureCache: Sendable {
    enum Entry: Sendable {
        /// One block buffer per authored mip level.
        case blocks([Data])
        /// The chain was encoded once and failed the PSNR gate.
        case rejected
    }

    private struct Index {
        /// File name → last access and bytes on disk; nil until the first write scans the root.
        /// Files another process adds after that scan stay uncounted until the next launch.
        var files: [String: (accessedAt: Date, bytes: Int)]?
        var bytes = 0
    }

    private static let schema = 1
    private static let magic = Data("LWTC".utf8)
    private let rootURL: URL
    private let sizeBudget: Int
    private let index = OSAllocatedUnfairLock(initialState: Index())

    init(cachesURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
         sizeBudget: Int = 512 * 1024 * 1024) {
        rootURL = cachesURL.appendingPathComponent("wpe-parity-textures/v1", isDirectory: true)
        self.sizeBudget = max(0, sizeBudget)
    }

    /// `source` digests the TEX file bytes; `selection` is the chosen conditional variant flags, which change the
    /// decoded texels without changing the file.
    static func key(source: SHA256.Digest, selection: [UInt32: UInt32]?, imageID: Int,
                    levels: [WPETexTextureMipmap], alpha: WPEParityTextureCompressor.AlphaMode) -> String {
        let variants = (selection ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let fields = [
            "schema=\(schema)",
            "source=\(source.map { String(format: "%02x", $0) }.joined())",
            "selection=\(variants.joined(separator: ","))",
            "image=\(imageID)",
            "mips=\(levels.map { "\($0.index):\($0.width)x\($0.height)" }.joined(separator: ","))",
            "format=astc_4x4_ldr",
            "psnr=\(WPEParityTextureCompressor.minimumPSNR)",
            "threshold=\(WPEParityTextureCompressor.errorThreshold)",
            "alpha=\(alpha.rawValue)",
            "size=\(levels.first.map { "\($0.width)x\($0.height)" } ?? "")",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
        ]
        return SHA256.hash(data: Data(fields.joined(separator: ";").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// nil on a miss or when the file does not hold exactly `levelByteCounts`; a mismatched file is removed.
    func read(_ key: String, levelByteCounts: [Int]) -> Entry? {
        let url = rootURL.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let entry = Self.decode(data, levelByteCounts: levelByteCounts) else {
            remove(key)
            return nil
        }
        // File mtime records last access.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        index.withLock { $0.files?[key]?.accessedAt = Date() }
        return entry
    }

    func write(_ entry: Entry, for key: String) {
        guard sizeBudget > 0 else { return }
        loadIndexIfNeeded()
        let fileManager = FileManager.default
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        let data = Self.encode(entry)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try data.write(to: temporary)
            try fileManager.moveItem(at: temporary, to: rootURL.appendingPathComponent(key))
        } catch {
            // Persistence is optional; the caller already has the texture. A failed move means another loader won.
            return
        }
        let victims = index.withLock { state -> [String] in
            let replaced = state.files?.updateValue((Date(), data.count), forKey: key)
            state.bytes += data.count - (replaced?.bytes ?? 0)
            guard let files = state.files, state.bytes > sizeBudget else { return [] }
            var victims: [String] = []
            for (name, file) in files.sorted(by: { $0.value.accessedAt < $1.value.accessedAt })
                where state.bytes > sizeBudget {
                // Dropped even when removal fails (usually already deleted elsewhere); a kept phantom would be counted forever.
                state.files?[name] = nil
                state.bytes -= file.bytes
                victims.append(name)
            }
            return victims
        }
        for name in victims {
            try? fileManager.removeItem(at: rootURL.appendingPathComponent(name))
        }
    }

    func remove(_ key: String) {
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent(key))
        index.withLock { state in
            if let removed = state.files?.removeValue(forKey: key) {
                state.bytes -= removed.bytes
            }
        }
    }

    private func loadIndexIfNeeded() {
        guard index.withLock({ $0.files == nil }) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: Array(keys),
                                                                 options: [.skipsHiddenFiles])) ?? []
        var files: [String: (accessedAt: Date, bytes: Int)] = [:]
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            files[url.lastPathComponent] = (values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }
        let scanned = files
        index.withLock { state in
            guard state.files == nil else { return }
            state.files = scanned
            state.bytes = scanned.values.reduce(0) { $0 + $1.bytes }
        }
    }

    /// magic, level count (0 = rejected), each level's byte count, then the levels' blocks back to back.
    private static func encode(_ entry: Entry) -> Data {
        let levels: [Data] = switch entry {
        case let .blocks(levels): levels
        case .rejected: []
        }
        var data = magic
        var words = [UInt64(levels.count)] + levels.map { UInt64($0.count) }
        for index in words.indices {
            words[index] = words[index].littleEndian
        }
        words.withUnsafeBytes { data.append(contentsOf: $0) }
        for level in levels {
            data.append(level)
        }
        return data
    }

    private static func decode(_ data: Data, levelByteCounts: [Int]) -> Entry? {
        let word = MemoryLayout<UInt64>.size
        guard data.count >= magic.count + word, data.prefix(magic.count) == magic else { return nil }
        func value(at offset: Int) -> Int {
            Int(UInt64(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }))
        }
        let count = value(at: magic.count)
        if count == 0 {
            return data.count == magic.count + word ? .rejected : nil
        }
        let header = magic.count + word * (1 + count)
        guard count == levelByteCounts.count, data.count == header + levelByteCounts.reduce(0, +),
              (0 ..< count).allSatisfy({ value(at: magic.count + word * (1 + $0)) == levelByteCounts[$0] }) else {
            return nil
        }
        var levels: [Data] = []
        var offset = data.startIndex + header
        for bytes in levelByteCounts {
            levels.append(data[offset ..< offset + bytes])
            offset += bytes
        }
        return .blocks(levels)
    }
}
#endif
