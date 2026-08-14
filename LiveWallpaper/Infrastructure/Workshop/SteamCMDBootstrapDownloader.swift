#if !LITE_BUILD
import CryptoKit
import Foundation

/// Fetches Valve's SteamCMD bootstrap archive into the app container.
///
/// Deliberately stops at the archive. Unpacking happens in the connector,
/// because everything a sandboxed process writes is stamped
/// `com.apple.quarantine`, and a quarantined bare CLI Mach-O cannot be spawned
/// at all — `Process.run()` fails EPERM, and Valve's Developer ID signature does
/// not exempt it. Doing the fetch here keeps the untrusted network response
/// inside the sandbox; doing the extraction there keeps the executable clean.
struct SteamCMDBootstrapDownloader: Sendable {
    enum DownloadError: Error, Equatable, CustomStringConvertible {
        case transport(String)
        case httpStatus(Int)
        case sizeMismatch(expected: Int, actual: Int)
        case digestMismatch
        case couldNotStore(String)

        var description: String {
            switch self {
            case .transport(let reason):
                return "Could not reach Valve's download server: \(reason)"
            case .httpStatus(let code):
                return "Valve's download server returned HTTP \(code)"
            case .sizeMismatch(let expected, let actual):
                return "Downloaded \(actual) bytes, expected \(expected)"
            case .digestMismatch:
                return "The downloaded archive does not match its published checksum"
            case .couldNotStore(let reason):
                return "Could not save the downloaded archive: \(reason)"
            }
        }
    }

    /// What the consent sheet has to be able to state before the user agrees.
    /// The archive is a bootstrapper, so quoting its 2.4 MB as the cost of the
    /// feature would be misleading — the first run pulls the rest.
    struct DownloadTerms: Equatable, Sendable {
        let sourceHost: String
        let archiveBytes: Int
        /// Rough on-disk size once SteamCMD has finished updating itself.
        let installedBytesApproximate: Int

        static let current = DownloadTerms(
            sourceHost: SteamCMDBootstrapPackage.downloadURL.host() ?? "steamcdn-a.akamaihd.net",
            archiveBytes: SteamCMDBootstrapPackage.byteCount,
            installedBytesApproximate: 90 * 1024 * 1024
        )
    }

    /// Injected so the digest gate can be tested without reaching the network.
    ///
    /// Streams to disk instead of `data(from:)`, which buffers the whole body
    /// before returning — the size check further down could only ever run on
    /// bytes already resident, so a CDN fault or a captive portal answering
    /// this URL was a memory-exhaustion vector. The on-disk size is checked
    /// before anything is read into memory.
    var fetch: @Sendable (URL) async throws -> (Data, URLResponse) = { url in
        let (downloaded, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: downloaded.path(percentEncoded: false)
        )
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= SteamCMDBootstrapPackage.byteCount else {
            throw DownloadError.sizeMismatch(
                expected: SteamCMDBootstrapPackage.byteCount, actual: size
            )
        }
        return (try Data(contentsOf: downloaded), response)
    }

    /// Rejects on any mismatch instead of adopting the new bytes. The signature
    /// check in the connector is the authority on what may *execute*, but a
    /// transfer that did not produce the expected bytes has no claim on being
    /// unpacked in the first place.
    static func verify(_ data: Data) -> DownloadError? {
        guard data.count == SteamCMDBootstrapPackage.byteCount else {
            return .sizeMismatch(
                expected: SteamCMDBootstrapPackage.byteCount, actual: data.count
            )
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest == SteamCMDBootstrapPackage.sha256 ? nil : .digestMismatch
    }

    /// Downloads, verifies, and stores the archive; returns where it landed.
    func download(to destination: URL) async throws -> URL {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await fetch(SteamCMDBootstrapPackage.downloadURL)
        } catch {
            throw DownloadError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }
        if let failure = Self.verify(data) {
            throw failure
        }

        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        } catch {
            throw DownloadError.couldNotStore(error.localizedDescription)
        }
        return destination
    }
}
#endif
