import AVFoundation
import CryptoKit
import Foundation
import LiveWallpaperCore

/// Cached Ogg→AAC for WebKit (raw `.ogg` often silent/stalls). Coalesces concurrent
/// range requests; bounded wait then poison→raw ogg so a hung decode cannot stall
/// the wallpaper. Caller must hold security scope on `oggURL`.
final class OggAudioTranscoder: @unchecked Sendable {
    static let shared = OggAudioTranscoder()

    private let cacheDirectory: URL
    // Concurrent: one hung decode must not HOL-block or poison other keys.
    private let queue = DispatchQueue(label: "com.livewallpaper.ogg-transcode", qos: .utility, attributes: .concurrent)
    private let lock = NSLock()
    private enum Outcome { case ready(URL); case unavailable }
    /// `.unavailable` poisons failed/hung keys (no retry).
    private var memo: [String: Outcome] = [:]
    private var pending: [String: DispatchGroup] = [:]
    /// Bound wait (~real cost ≪1s); hang mid-read cannot be cancelled.
    private let deadline: TimeInterval = 6

    /// Flat mtime-LRU cap (no per-workshop orphan GC for these sources).
    private static let maxCacheBytes: UInt64 = 256 * 1024 * 1024  // 256 MiB

    private init() {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        cacheDirectory = caches.appendingPathComponent("OggTranscode", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        queue.async { [self] in enforceSizeLimit() }
    }

    static func isOggFamily(_ url: URL) -> Bool {
        ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased())
    }

    /// Cached AAC or nil (caller serves raw ogg). Concurrent callers coalesce.
    func transcodedM4A(forOgg oggURL: URL) -> URL? {
        guard Self.isOggFamily(oggURL), let key = cacheKey(for: oggURL) else { return nil }
        let destination = cacheDirectory.appendingPathComponent(key).appendingPathExtension("m4a")

        lock.lock()
        switch memo[key] {
        case .ready(let url): lock.unlock(); return url
        case .unavailable:    lock.unlock(); return nil   // poisoned this session — never serve, even if a late .m4a lands
        case nil:             break
        }
        // Disk cache from a prior session wins — but only after the poison check
        // above, so a stale/late file can't bypass an in-session poison.
        if FileManager.default.fileExists(atPath: destination.path) {
            memo[key] = .ready(destination)
            lock.unlock()
            return destination
        }
        if let group = pending[key] {
            // Coalesce: wait (bounded) for the in-flight transcode so concurrent
            // range requests for the same URL all serve the same representation.
            lock.unlock()
            if group.wait(timeout: .now() + deadline) == .success {
                return readyURL(forKey: key)
            }
            return arbitrateAfterTimeout(forKey: key)
        }
        let group = DispatchGroup()
        group.enter()
        pending[key] = group
        lock.unlock()

        queue.async { [self] in
            // Timeout arbitration poisons the key; the decode loop polls that as
            // a cancel signal so it cannot outlive the caller's security scope
            // on the source URL.
            let produced = transcode(oggURL, to: destination, isCancelled: {
                lock.lock()
                defer { lock.unlock() }
                if case .unavailable = memo[key] {
                    return true
                }
                return false
            })
            lock.lock()
            if case .unavailable = memo[key] {
                // A caller already timed out and poisoned this key — honor it and
                // drop the late artifact so it can't resurface as a cache hit.
                if let produced { try? FileManager.default.removeItem(at: produced) }
            } else {
                memo[key] = produced.map(Outcome.ready) ?? .unavailable
            }
            pending[key] = nil
            group.leave()
            lock.unlock()
            if produced != nil { enforceSizeLimit() }
        }

        guard group.wait(timeout: .now() + deadline) == .success else {
            return arbitrateAfterTimeout(forKey: key)
        }
        return readyURL(forKey: key)
    }

    /// Timeout: honor committed result, else poison (no mixed AAC/ogg for one key).
    private func arbitrateAfterTimeout(forKey key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        switch memo[key] {
        case .ready(let url): return url
        case .unavailable:    return nil
        case nil:             memo[key] = .unavailable; return nil
        }
    }

    private func readyURL(forKey key: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if case .ready(let url) = memo[key] { return url }
        return nil
    }

    /// Internal (not private) so tests can drive the cancellation path directly.
    /// A cancelled run deletes the half-written `.partial` and returns nil.
    func transcode(_ source: URL, to destination: URL, isCancelled: () -> Bool) -> URL? {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        do {
            let input = try AVAudioFile(forReading: source)
            let format = input.processingFormat
            let total = input.length
            guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                return nil
            }
            var written: AVAudioFramePosition = 0
            // Inner scope so the writer is finalized (flushed + closed) before the move.
            do {
                let output = try AVAudioFile(
                    forWriting: partial,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount
                    ]
                )
                let started = ProcessInfo.processInfo.systemUptime
                var reachedEnd = false
                // `AVAudioFile.read` THROWS at end-of-stream (Ogg `length` is only an estimate, so an exact
                // frame count can't be read) — treat that as completion once audio has been decoded; a throw
                // before any frames is a genuine decode failure (caught below, no cache). A `write` failure
                // still propagates as a real error.
                while !reachedEnd {
                    if ProcessInfo.processInfo.systemUptime - started > deadline { throw TranscodeError.timedOut }
                    if isCancelled() { throw TranscodeError.cancelled }
                    try autoreleasepool {
                        do {
                            try input.read(into: buffer, frameCount: buffer.frameCapacity)
                        } catch {
                            reachedEnd = true
                            return
                        }
                        if buffer.frameLength == 0 {
                            reachedEnd = true
                            return
                        }
                        try output.write(from: buffer)
                        written += AVAudioFramePosition(buffer.frameLength)
                    }
                }
                // A clean decode reads ~100% of the (slightly over-estimated)
                // length; far fewer frames means `read` threw mid-stream rather
                // than at EOF, so reject it instead of caching a truncated file.
                guard Double(written) >= Double(total) * 0.9 else { throw TranscodeError.truncated }
            }
            try FileManager.default.moveItem(at: partial, to: destination)
            Logger.info(
                "Ogg→AAC transcoded \(source.lastPathComponent) (\(written)/\(total) frames)",
                category: .screenManager
            )
            return destination
        } catch {
            try? FileManager.default.removeItem(at: partial)
            Logger.notice(
                "Ogg→AAC transcode skipped for \(source.lastPathComponent): \(error.localizedDescription)",
                category: .screenManager
            )
            return nil
        }
    }

    private func cacheKey(for url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let seed = "\(url.path)|\(size)|\(stamp)"
        let digest = SHA256.hash(data: Data(seed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// mtime-LRU eviction under maxCacheBytes (off playback path).
    private func enforceSizeLimit() {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var files: [(url: URL, size: UInt64, modified: Date)] = []
        var total: UInt64 = 0
        for url in children {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let modified = values.contentModificationDate ?? .distantPast
            if url.pathExtension == "partial" {
                // Fresh `.partial` belongs to a possibly-running transcode; a
                // stale one is an orphan from a killed process. Either way it
                // never counts against the budget.
                if modified < Date(timeIntervalSinceNow: -3600) {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            guard url.pathExtension == "m4a" else { continue }
            total += size
            files.append((url, size, modified))
        }
        guard total > Self.maxCacheBytes else { return }

        for file in files.sorted(by: { $0.modified < $1.modified }) {
            if total <= Self.maxCacheBytes { break }
            let key = file.url.deletingPathExtension().lastPathComponent
            // Check-and-delete atomically with the caller's disk-hit promotion (also under `lock`):
            // clear the memo and unlink while holding it so a concurrent request can't re-promote the
            // path between check and delete. Evicting a `.ready` entry is fine — the next request
            // simply re-transcodes.
            lock.lock()
            if pending[key] != nil {
                lock.unlock()
                continue
            }
            let previous = memo[key]
            memo[key] = nil
            let removed = (try? fm.removeItem(at: file.url)) != nil
            if !removed { memo[key] = previous }
            lock.unlock()
            if removed { total -= file.size }
        }
    }

    private enum TranscodeError: Error { case timedOut, truncated, cancelled }
}
