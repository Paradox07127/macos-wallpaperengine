import AVFoundation
import Foundation
import os

/// Owner must retain the loader — resourceLoader's delegate is weak.
final class InMemoryVideoAssetLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    static let scheme = "lwmem"

    private let data: Data
    private let mimeType: String
    /// Exposed byte window (full file, or package entry slice).
    private let windowStart: Int
    private let windowLength: Int

    /// `.mappedIfSafe` is advisory: on network/removable volumes Foundation heap-reads the whole file instead of mapping.
    static func isVolumeMappable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.volumeIsLocalKey, .volumeIsRemovableKey]
        ) else {
            // Unknown volume: keep the mapping path rather than silently
            // changing behaviour for ordinary local libraries.
            return true
        }
        return (values.volumeIsLocal ?? true) && !(values.volumeIsRemovable ?? false)
    }

    static func load(from url: URL) throws -> (loader: InMemoryVideoAssetLoader, customURL: URL) {
        guard isVolumeMappable(url) else {
            throw NSError(domain: "InMemoryVideoAssetLoader", code: 415, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent) is on a volume Foundation will not memory-map"
            ])
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let mime = mimeType(forPathExtension: url.pathExtension)
        let loader = InMemoryVideoAssetLoader(
            data: data,
            mimeType: mime,
            windowStart: 0,
            windowLength: data.count
        )
        return (loader, customURL(forLastComponent: url.lastPathComponent))
    }

    static func loadPackageEntry(
        packageURL: URL,
        entryName: String
    ) throws -> (loader: InMemoryVideoAssetLoader, customURL: URL) {
        let package: WallpaperEnginePackage
        do {
            let handle = try WallpaperEnginePackage.openForReading(from: packageURL)
            defer { try? handle.close() }
            package = try WallpaperEnginePackage.parseIndex(streamingFrom: handle)
        }
        guard let lookup = WallpaperEnginePackage.canonicalLookupName(entryName),
              let entry = package.entry(named: lookup) else {
            throw NSError(domain: "InMemoryVideoAssetLoader", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "Video entry \(entryName) not found in package"
            ])
        }
        // 可移动/网络卷上 .mappedIfSafe 会整包堆读,故按 entry 字节范围读
        let data: Data
        let start: Int
        let windowLength: Int
        if isVolumeMappable(packageURL) {
            data = try Data(contentsOf: packageURL, options: .mappedIfSafe)
            let absoluteStart = package.dataStart + entry.dataOffset
            guard let mappedStart = Int(exactly: absoluteStart),
                  let length = Int(exactly: entry.dataSize),
                  mappedStart >= 0, length >= 0, mappedStart &+ length <= data.count else {
                throw NSError(domain: "InMemoryVideoAssetLoader", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "Video entry \(entryName) is out of package bounds"
                ])
            }
            start = mappedStart
            windowLength = length
        } else {
            let handle = try WallpaperEnginePackage.openForReading(from: packageURL)
            defer { try? handle.close() }
            let fileSize = try handle.seekToEnd()
            guard let offset = UInt64(exactly: package.dataStart + entry.dataOffset),
                  let length = UInt64(exactly: entry.dataSize),
                  offset <= fileSize, length <= fileSize - offset,
                  let count = Int(exactly: length) else {
                throw NSError(domain: "InMemoryVideoAssetLoader", code: 422, userInfo: [
                    NSLocalizedDescriptionKey: "Video entry \(entryName) is out of package bounds"
                ])
            }
            try handle.seek(toOffset: offset)
            // Short reads are legal on network volumes — loop until the range
            // is complete; only a genuine EOF is a truncated package.
            var collected = Data(capacity: count)
            while collected.count < count {
                guard let chunk = try handle.read(upToCount: min(8 << 20, count - collected.count)),
                      !chunk.isEmpty else {
                    throw NSError(domain: "InMemoryVideoAssetLoader", code: 422, userInfo: [
                        NSLocalizedDescriptionKey: "Video entry \(entryName) could not be read in full"
                    ])
                }
                collected.append(chunk)
            }
            data = collected
            start = 0
            windowLength = count
        }
        let loader = InMemoryVideoAssetLoader(
            data: data,
            mimeType: mimeType(forPathExtension: (entryName as NSString).pathExtension),
            windowStart: start,
            windowLength: windowLength
        )
        return (loader, customURL(forLastComponent: (entryName as NSString).lastPathComponent))
    }

    private static func customURL(forLastComponent lastComponent: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "wallpaper"
        components.path = "/" + (lastComponent.isEmpty ? "video" : lastComponent)
        return components.url ?? URL(string: "\(scheme)://wallpaper/video")!
    }

    private static func mimeType(forPathExtension rawExtension: String) -> String {
        switch rawExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mov":        return "video/quicktime"
        case "m4a":        return "audio/mp4"
        default:           return "video/mp4"
        }
    }

    init(data: Data, mimeType: String, windowStart: Int, windowLength: Int) {
        self.data = data
        self.mimeType = mimeType
        self.windowStart = windowStart
        self.windowLength = windowLength
    }

    /// With requestsAllDataToEndOfResource (or requestedLength == Int.max while contentLength is unreported), feed through EOF — a short respond + finishLoading() would make the media system assume the resource ends there.
    static func logicalRange(
        currentOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool,
        windowLength: Int
    ) -> Range<Int> {
        let start = min(max(Int(clamping: currentOffset), 0), windowLength)
        guard !requestsAllDataToEndOfResource, requestedLength != Int.max else {
            return start..<windowLength
        }
        let (end, overflowed) = start.addingReportingOverflow(requestedLength)
        return start..<(overflowed ? windowLength : min(max(end, start), windowLength))
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !isClosed else {
            loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
            return true
        }
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = mimeType
            info.contentLength = Int64(windowLength)
            info.isByteRangeAccessSupported = true
            // Without isEntireLengthAvailableOnDemand AVFoundation treats us as a streaming source it may not re-reach and hoards/re-pulls every loop. True here — the bytes are an mmap.
            info.isEntireLengthAvailableOnDemand = true
        }

        if let dataRequest = loadingRequest.dataRequest {
            // Offsets are relative to the logical resource (0..<windowLength);
            // map them into the underlying blob via `windowStart`.
            let range = Self.logicalRange(
                currentOffset: dataRequest.currentOffset,
                requestedLength: dataRequest.requestedLength,
                requestsAllDataToEndOfResource: dataRequest.requestsAllDataToEndOfResource,
                windowLength: windowLength
            )
            switch serve(range: range, isCancelled: { loadingRequest.isCancelled }, respond: {
                dataRequest.respond(with: $0)
            }) {
            case .finished: break
            case .cancelled: return true
            case .closed:
                loadingRequest.finishLoading(with: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
                return true
            }
        }

        loadingRequest.finishLoading()
        return true
    }

    /// `serve` polls `isCancelled` before every chunk and never finishes a cancelled request, so there is nothing to undo.
    func resourceLoader(_: AVAssetResourceLoader, didCancel _: AVAssetResourceLoadingRequest) {}

    enum ServeOutcome { case finished, cancelled, closed }

    /// `.cancelled` must leave the request unfinished; `.closed` must still be finished with an error.
    func serve(range: Range<Int>, isCancelled: () -> Bool, respond: (Data) -> Void) -> ServeOutcome {
        // Respond in bounded chunks so a large range cannot trigger one multi-hundred-MB Data copy; AVFoundation accepts repeated respond(with:) before finishLoading().
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard !isCancelled() else { return .cancelled }
            let next = min(offset &+ Self.chunkSize, range.upperBound)
            guard let chunk = makeChunk(physical: (windowStart &+ offset) ..< (windowStart &+ next)) else {
                return .closed
            }
            respond(chunk)
            offset = next
        }
        return .finished
    }

    /// Copies into memory we own so its deallocator tells us when AVFoundation has let go of it; nil once closed.
    private func makeChunk(physical: Range<Int>) -> Data? {
        // Checking isClosed and counting the chunk under one lock keeps retire() from seeing zero in flight while this chunk is still headed to AVFoundation.
        let admitted = drainState.withLock { state in
            guard !state.isClosed else { return false }
            state.inFlightChunks += 1
            return true
        }
        guard admitted else { return nil }
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: physical.count, alignment: 16)
        data.copyBytes(to: bytes.bindMemory(to: UInt8.self, capacity: physical.count), from: physical)
        return Data(bytesNoCopy: bytes, count: physical.count, deallocator: .custom { [self] pointer, _ in
            pointer.deallocate()
            chunkReleased()
        })
    }

    private func chunkReleased() {
        let waiters = drainState.withLock { state -> [@Sendable () -> Void] in
            state.inFlightChunks -= 1
            guard state.inFlightChunks == 0 else { return [] }
            defer { state.drainWaiters.removeAll() }
            return Array(state.drainWaiters.values)
        }
        // Never run waiters inside the deallocator: it fires on CoreMedia's buffering thread mid-free.
        for waiter in waiters {
            DispatchQueue.main.async(execute: waiter)
        }
    }

    private var isClosed: Bool {
        drainState.withLock { $0.isClosed }
    }

    /// After this, in-progress requests stop at the next chunk and new ones fail with a cancellation error.
    func close() {
        drainState.withLock { $0.isClosed = true }
    }

    var isDrained: Bool {
        drainState.withLock { $0.inFlightChunks == 0 }
    }

    /// Runs `handler` on the main queue once no served chunk is alive, or after `timeout` seconds.
    func notifyWhenDrained(timeout: TimeInterval, _ handler: @escaping @Sendable () -> Void) {
        let waiterID: UInt64? = drainState.withLock { state in
            guard state.inFlightChunks > 0 else { return nil }
            let id = state.nextWaiterID
            state.nextWaiterID &+= 1
            state.drainWaiters[id] = handler
            return id
        }
        guard let waiterID else {
            DispatchQueue.main.async(execute: handler)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [self] in
            drainState.withLock { $0.drainWaiters.removeValue(forKey: waiterID) }?()
        }
    }

    /// Closes the loader and keeps `objects` alive until AVFoundation releases every served chunk, or `timeout` seconds pass.
    func retire(_ objects: [(any AnyObject & Sendable)?], timeout: TimeInterval = 2) {
        close()
        let retained = objects.compactMap(\.self)
        notifyWhenDrained(timeout: timeout) { withExtendedLifetime(retained) {} }
    }

    private struct DrainState {
        var isClosed = false
        var inFlightChunks = 0
        var nextWaiterID: UInt64 = 0
        var drainWaiters: [UInt64: @Sendable () -> Void] = [:]
    }

    private let drainState = OSAllocatedUnfairLock(initialState: DrainState())

    /// 2 MB chunks match typical AVFoundation range requests.
    private static let chunkSize: Int = 2 * 1024 * 1024
}
