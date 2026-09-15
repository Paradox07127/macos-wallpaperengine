import AVFoundation
import CryptoKit
import Foundation
import LiveWallpaperCore

/// Coalesces requests without blocking the Swift pool; abandoned workers keep their slot until they return.
actor OggAudioTranscoder {
    typealias Decode = @Sendable (URL, URL, @escaping @Sendable () -> Bool) -> URL?
    static let shared = OggAudioTranscoder()

    private let cacheDirectory: URL
    private let queue = DispatchQueue(
        label: "com.livewallpaper.ogg-transcode", qos: .utility,
        attributes: .concurrent, autoreleaseFrequency: .workItem
    )
    private let maximumConcurrent: Int
    private let maximumPending: Int
    private let decodeOverride: Decode?
    private nonisolated let deadline: TimeInterval
    private enum Outcome { case ready(URL); case unavailable }
    private var memo: [String: Outcome] = [:]
    private var didSweepCache = false
    private var pending: [String: Job] = [:]
    private var waiting: [String] = []
    private var running: [UUID: Job] = [:]
    private static let maxCacheBytes: UInt64 = 256 * 1024 * 1024

    /// Shared with the blocking worker; every mutable access is protected by this lock.
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }; return cancelled
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }
    }

    /// Waiters and timeout are actor-confined. The GCD worker reads only immutable
    /// inputs and the lock-protected cancellation flag.
    private final class Job: @unchecked Sendable {
        let id = UUID()
        let key: String
        let source: URL
        let destination: URL
        let access: OggSourceAccess?
        let cancellation = Cancellation()
        var waiters: [UUID: CheckedContinuation<URL?, Never>] = [:]
        var timeout: Task<Void, Never>?

        init(key: String, source: URL, destination: URL, access: OggSourceAccess?) {
            self.key = key
            self.source = source
            self.destination = destination
            self.access = access
        }
    }

    init(
        cacheDirectory: URL? = nil,
        maximumConcurrent: Int = 2,
        maximumPending: Int = 32,
        deadline: TimeInterval = 6,
        decode: Decode? = nil
    ) {
        let caches = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        self.cacheDirectory = cacheDirectory ?? caches.appendingPathComponent("OggTranscode", isDirectory: true)
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumPending = max(1, maximumPending)
        self.deadline = max(0.001, deadline)
        decodeOverride = decode
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    nonisolated static func isOggFamily(_ url: URL) -> Bool {
        ["ogg", "oga", "opus"].contains(url.pathExtension.lowercased())
    }

    /// The access lease is acquired before detaching from the folder owner and retained by the actual worker.
    func transcodedM4A(forOgg source: URL, access: OggSourceAccess? = nil) async -> URL? {
        guard !Task.isCancelled, Self.isOggFamily(source), let key = cacheKey(for: source) else { return nil }
        if !didSweepCache {
            didSweepCache = true
            enforceSizeLimit()
        }
        let destination = cacheDirectory.appendingPathComponent(key).appendingPathExtension("m4a")
        switch memo[key] {
        case let .ready(url):
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            memo[key] = nil
        case .unavailable: return nil
        case nil: break
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            memo[key] = .ready(destination)
            return destination
        }
        let requestID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if let job = pending[key] {
                    job.waiters[requestID] = continuation
                    return
                }
                guard pending.count < maximumPending else {
                    memo[key] = .unavailable
                    continuation.resume(returning: nil)
                    return
                }
                let job = Job(key: key, source: source, destination: destination, access: access)
                job.waiters[requestID] = continuation
                pending[key] = job
                waiting.append(key)
                let jobID = job.id
                let delay = deadline
                job.timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    await self?.expire(key: key, id: jobID)
                }
                startAvailableWork()
            }
        } onCancel: {
            Task { await self.cancelRequest(key: key, requestID: requestID) }
        }
    }

    private func startAvailableWork() {
        while running.count < maximumConcurrent, !waiting.isEmpty {
            let key = waiting.removeFirst()
            guard let job = pending[key] else { continue }
            running[job.id] = job
            // A cancelled generation can finish after a replacement starts. It never writes the shared cache path.
            let staged = cacheDirectory.appendingPathComponent(".\(key).\(job.id.uuidString).m4a")
            let decoder = decodeOverride
            queue.async { [self, job] in
                let produced: URL? = autoreleasepool {
                    guard !job.cancellation.isCancelled else { return nil }
                    if let decoder {
                        return decoder(job.source, staged) { job.cancellation.isCancelled }
                    }
                    return transcode(job.source, to: staged, isCancelled: { job.cancellation.isCancelled })
                }
                Task { await self.complete(job, produced: produced, staged: staged) }
            }
        }
    }

    private func cancelRequest(key: String, requestID: UUID) {
        guard let job = pending[key], let waiter = job.waiters.removeValue(forKey: requestID) else { return }
        waiter.resume(returning: nil)
        guard job.waiters.isEmpty else { return }
        // Cancellation has not served raw bytes, so a later request may try again.
        pending[key] = nil
        waiting.removeAll { $0 == key }
        job.timeout?.cancel()
        job.timeout = nil
        job.cancellation.cancel()
    }

    private func expire(key: String, id: UUID) {
        guard let job = pending[key], job.id == id else { return }
        memo[key] = .unavailable
        pending[key] = nil
        waiting.removeAll { $0 == key }
        job.cancellation.cancel()
        finishWaiters(job, result: nil)
        // A timed-out decode may still be inside AVAudioFile.read. running retains its lease and slot.
    }

    private func complete(_ job: Job, produced: URL?, staged: URL) {
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: staged.appendingPathExtension("partial"))
            running[job.id] = nil
            startAvailableWork()
        }
        guard pending[job.key]?.id == job.id else { return }
        var result: URL?
        if produced != nil, !job.cancellation.isCancelled {
            do {
                try FileManager.default.moveItem(at: staged, to: job.destination)
                result = job.destination
            } catch { result = nil }
        }
        memo[job.key] = result.map(Outcome.ready) ?? .unavailable
        finishWaiters(job, result: result)
        pending[job.key] = nil
        if result != nil {
            enforceSizeLimit()
        }
    }

    private func finishWaiters(_ job: Job, result: URL?) {
        job.timeout?.cancel()
        job.timeout = nil
        let waiters = job.waiters.values
        job.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    #if DEBUG
    func sweepCacheForTesting() {
        enforceSizeLimit()
    }

    var workSnapshot: (running: Int, pending: Int, waiters: Int) {
        (running.count, pending.count, pending.values.reduce(0) { $0 + $1.waiters.count })
    }
    #endif

    nonisolated func transcode(_ source: URL, to destination: URL, isCancelled: () -> Bool) -> URL? {
        let partial = destination.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            guard !isCancelled() else { return nil }
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
                // `AVAudioFile.read` THROWS at end-of-stream (Ogg `length` is only an estimate) — treat that as completion once audio has been decoded; a throw before any frames is a genuine decode failure.
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
                // Far fewer frames than ~90% of `length` means `read` threw mid-stream rather than at EOF, so reject it instead of caching a truncated file.
                guard Double(written) >= Double(total) * 0.9 else { throw TranscodeError.truncated }
            }
            guard !isCancelled() else { return nil }
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

    private func enforceSizeLimit() {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else { return }

        var files: [(url: URL, size: UInt64, modified: Date)] = []
        var total: UInt64 = 0
        for url in children {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            let modified = values.contentModificationDate ?? .distantPast
            if url.lastPathComponent.hasPrefix(".") {
                if let jobID = Self.stagingJobID(for: url), running[jobID] == nil,
                   modified < Date(timeIntervalSinceNow: -3600) {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            if url.pathExtension == "partial" {
                // Fresh `.partial` belongs to a possibly-running transcode; a stale one is an orphan. Either way it never counts against the budget.
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
            if pending[key] != nil {
                continue
            }
            let previous = memo[key]
            memo[key] = nil
            let removed = (try? fm.removeItem(at: file.url)) != nil
            if !removed { memo[key] = previous }
            if removed { total -= file.size }
        }
    }

    private static func stagingJobID(for url: URL) -> UUID? {
        let parts = url.lastPathComponent.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 || (parts.count == 5 && parts[4] == "partial"),
              parts[0].isEmpty, parts[1].count == 64,
              parts[1].allSatisfy(\.isHexDigit), parts[3] == "m4a" else { return nil }
        return UUID(uuidString: String(parts[2]))
    }

    private enum TranscodeError: Error { case timedOut, truncated, cancelled }
}
