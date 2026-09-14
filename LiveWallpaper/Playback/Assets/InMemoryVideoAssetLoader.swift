import AVFoundation
import Foundation

/// Owner must retain the loader — resourceLoader's delegate is weak.
final class InMemoryVideoAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
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
            let handle = try FileHandle(forReadingFrom: packageURL)
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
            let handle = try FileHandle(forReadingFrom: packageURL)
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

    private init(data: Data, mimeType: String, windowStart: Int, windowLength: Int) {
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
            // Respond in bounded chunks so a large range cannot trigger one multi-hundred-MB Data copy; AVFoundation accepts repeated respond(with:) before finishLoading().
            var offset = range.lowerBound
            while offset < range.upperBound {
                let next = min(offset &+ Self.chunkSize, range.upperBound)
                let physicalLow = windowStart &+ offset
                let physicalHigh = windowStart &+ next
                dataRequest.respond(with: Data(data[physicalLow..<physicalHigh]))
                offset = next
            }
        }

        loadingRequest.finishLoading()
        return true
    }

    /// 2 MB chunks match typical AVFoundation range requests.
    private static let chunkSize: Int = 2 * 1024 * 1024
}
