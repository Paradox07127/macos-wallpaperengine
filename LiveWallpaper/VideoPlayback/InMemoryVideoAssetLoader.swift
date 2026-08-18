import AVFoundation
import Foundation

/// Serves mmap'd video bytes over `lwmem://` so looped playback cannot re-hit disk
/// (AVFoundation ignores preferredForwardBufferDuration on 4K HEVC; verified via
/// fs_usage). Also windows a scene.pkg entry without extraction. Owner must retain
/// the loader — resourceLoader's delegate is weak.
final class InMemoryVideoAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "lwmem"

    private let data: Data
    private let mimeType: String
    /// Exposed byte window (full file, or package entry slice).
    private let windowStart: Int
    private let windowLength: Int

    static func load(from url: URL) throws -> (loader: InMemoryVideoAssetLoader, customURL: URL) {
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

    /// Map package lazily; expose one entry's byte range (no extraction).
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
        let data = try Data(contentsOf: packageURL, options: .mappedIfSafe)
        let absoluteStart = package.dataStart + entry.dataOffset
        guard let start = Int(exactly: absoluteStart),
              let length = Int(exactly: entry.dataSize),
              start >= 0, length >= 0, start &+ length <= data.count else {
            throw NSError(domain: "InMemoryVideoAssetLoader", code: 422, userInfo: [
                NSLocalizedDescriptionKey: "Video entry \(entryName) is out of package bounds"
            ])
        }
        let loader = InMemoryVideoAssetLoader(
            data: data,
            mimeType: mimeType(forPathExtension: (entryName as NSString).pathExtension),
            windowStart: start,
            windowLength: length
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

    /// Logical (0..<windowLength) byte range one data request must be served.
    ///
    /// AVAssetResourceLoader.h: with `requestsAllDataToEndOfResource` set,
    /// requestedLength must be disregarded and data fed through EOF — responding
    /// short and then calling `finishLoading()` makes the media system assume the
    /// resource ends there. requestedLength is NSIntegerMax only while
    /// contentLength is unreported, and this delegate reports it on the first
    /// request, so testing `== Int.max` alone truncated the asset mid-playback
    /// (issue #131).
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
            // Without this, AVFoundation treats us as a streaming source it may
            // not be able to re-reach, so it hoards what we hand over and
            // re-pulls the whole resource every loop: measured 673 MB delivered
            // across three loops of a 56 MB clip, with footprint swinging 26 MB.
            // Declaring on-demand availability (true here — the bytes are an
            // mmap) drops that to 134 MB and a 5 MB swing, at the cost of many
            // more, much smaller requests. AVAssetResourceLoader.h names this
            // exact case: "the custom URL scheme ultimately refers to files on
            // local storage".
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
            // Respond in bounded chunks so a large requested range can't
            // trigger a single multi-hundred-MB `Data` copy. AVFoundation
            // accepts repeated `respond(with:)` calls before
            // `finishLoading()` and stitches them into one fulfilled range.
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
