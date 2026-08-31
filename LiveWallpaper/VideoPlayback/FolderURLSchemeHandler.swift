import Foundation
import LiveWallpaperCore
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Serves a security-scoped folder under `livewallpaper://` so WKWebView sees
/// same-origin content (file:// breaks ES modules via CORS). Top-level loads
/// require `?n=<nonce>` so a previous folder's URL cannot be replayed;
/// subresources inherit the document. `@unchecked Sendable`: WebKit calls on
/// main thread; mutable state is only touched from MainActor by the host.
final class FolderURLSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    nonisolated static let scheme = "livewallpaper"
    nonisolated static let host = "wallpaper"
    nonisolated static let responseChunkSize = 64 * 1024

    /// Enforced CSP when enabled. Locks frame/object/form/base; keeps
    /// unsafe-inline/eval + https connect for the WPE web corpus. No Swift
    /// bridge — residual exfiltration risk is threat-model only.
    nonisolated static let contentSecurityPolicy: String = [
        "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
        "connect-src 'self' https: livewallpaper: data: blob:;",
        "img-src 'self' https: data: blob: livewallpaper:;",
        "media-src 'self' https: data: blob: livewallpaper:;",
        "font-src 'self' https: data: livewallpaper:;",
        "frame-src 'none';",
        "object-src 'none';",
        "base-uri 'none';",
        "form-action 'none';"
    ].joined(separator: " ")

    /// `contentSecurityPolicy` minus every remote origin. Imported Workshop code
    /// may render — it is a JS medium, and the shipped corpus loads all of its
    /// assets relatively — but it may not reach the network. Local file reads are
    /// already refused by path containment, so this closes the egress path that
    /// made a downloaded page usable as a resident tracking client.
    nonisolated static let networkIsolatedContentSecurityPolicy: String = [
        "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: livewallpaper:;",
        "connect-src 'self' livewallpaper: data: blob:;",
        "img-src 'self' data: blob: livewallpaper:;",
        "media-src 'self' data: blob: livewallpaper:;",
        "font-src 'self' data: livewallpaper:;",
        "frame-src 'none';",
        "object-src 'none';",
        "base-uri 'none';",
        "form-action 'none';",
    ].joined(separator: " ")

    /// Test override (often Report-Only); nil defers to `cspEnforcementEnabled`.
    var cspOverride: ContentSecurityPolicyOverride?

    /// Opt-in CSP header on scheme responses; host reloads on flip.
    var cspEnforcementEnabled = false

    /// Provenance-driven, not user-driven: set for Workshop imports and it
    /// outranks `cspEnforcementEnabled`, which only ever relaxes the policy.
    var networkIsolationEnabled = false

    struct ContentSecurityPolicyOverride: Sendable, Equatable {
        enum Disposition: Sendable, Equatable {
            case enforced
            case reportOnly
        }
        let directives: String
        let disposition: Disposition

        var headerName: String {
            switch disposition {
            case .enforced:   return "Content-Security-Policy"
            case .reportOnly: return "Content-Security-Policy-Report-Only"
            }
        }
    }

    private var activeFolderURL: URL?
    private var sessionNonce: String?
    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]

    /// scene.pkg backend when loose file missing; cleared on every folderURL set.
    private var activePackageBacking: PackageBacking?

    struct PackageBacking: Sendable {
        let url: URL
        let package: WallpaperEnginePackage
    }
    /// Dedupe missing-resource logs (WPE loops often 404 placeholders every tick).
    private var reportedMissingResources: Set<String> = []
    /// Dedupe Ogg→mp3/m4a substitution logs once per filename per session.
    private var reportedOggSubstitutions: Set<String> = []

    /// Folder swap cancels in-flight tasks so workers cannot read past scope end.
    var folderURL: URL? {
        get { activeFolderURL }
        set {
            if activeFolderURL != newValue {
                cancelAllActiveTasks()
                reportedMissingResources.removeAll()
                reportedOggSubstitutions.removeAll()
            }
            activeFolderURL = newValue
            // Caller re-supplies package backing after folderURL (which clears it).
            activePackageBacking = nil
            sessionNonce = newValue == nil ? nil : UUID().uuidString
        }
    }

    /// Call after `folderURL`; does not regenerate the session nonce.
    func setPackageBacking(_ backing: PackageBacking?) {
        activePackageBacking = backing
    }

    /// Embedded as `?n=<nonce>` on the top-level folder navigation URL.
    var currentSessionNonce: String? {
        sessionNonce
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(Self.makeError(.badURL))
            return
        }

        do {
            try validateRequest(urlSchemeTask.request, url: url)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        guard let folderURL = activeFolderURL else {
            urlSchemeTask.didFailWithError(Self.makeError(.notConnectedToInternet, "No active folder"))
            return
        }

        // Loose file wins (path-traversal checked); else package entry.
        let primaryURL: URL
        do {
            primaryURL = try Self.resolvedFileURL(for: url, inside: folderURL)
        } catch {
            urlSchemeTask.didFailWithError(error)
            return
        }

        let source: ByteSource
        let mime: String
        if Self.isRegularFile(primaryURL) {
            source = .file(primaryURL)
            mime = Self.mimeType(for: primaryURL)
        } else if let fallback = Self.oggFallbackURL(for: primaryURL) {
            if !reportedOggSubstitutions.contains(primaryURL.lastPathComponent) {
                reportedOggSubstitutions.insert(primaryURL.lastPathComponent)
                Logger.info(
                    "FolderScheme: serving \(fallback.lastPathComponent) for \(primaryURL.lastPathComponent) (macOS WebKit Ogg/Opus decoder workaround)",
                    category: .screenManager
                )
            }
            source = .file(fallback)
            mime = Self.mimeType(for: fallback)
        } else if let resolved = packageByteSource(for: url) {
            source = resolved.source
            mime = resolved.mime
        } else {
            // Fall through to worker 404 + missing-resource log on the loose path.
            source = .file(primaryURL)
            mime = Self.mimeType(for: primaryURL)
        }

        let rangeHeader = urlSchemeTask.request.value(forHTTPHeaderField: "Range")
        let delivery = SchemeTaskDelivery(urlSchemeTask)
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        // Snapshot CSP on main; detached worker must not read mutable CSP flags.
        let cspHeader: (name: String, value: String)? = {
            if let override = cspOverride {
                return (override.headerName, override.directives)
            }
            if networkIsolationEnabled {
                return ("Content-Security-Policy", Self.networkIsolatedContentSecurityPolicy)
            }
            guard cspEnforcementEnabled else { return nil }
            return ("Content-Security-Policy", Self.contentSecurityPolicy)
        }()

        activeTasks[taskID]?.cancel()

        let worker = Task.detached(priority: .userInitiated) { [weak self, source, mime, rangeHeader, url, delivery, taskID, cspHeader] in
            var source = source
            var mime = mime
            // Prefer cached AAC for Ogg (WebKit decoder is unreliable).
            if case .file(let oggURL) = source,
               OggAudioTranscoder.isOggFamily(oggURL),
               let aac = OggAudioTranscoder.shared.transcodedM4A(forOgg: oggURL) {
                source = .file(aac)
                mime = Self.mimeType(for: aac)
            }
            do {
                let totalLength = try Self.totalLength(of: source)
                let range = Self.byteRange(from: rangeHeader, totalLength: totalLength)
                let statusCode = range == nil ? 200 : 206
                let contentLength = range?.length ?? totalLength

                var headers = [
                    "Content-Type": mime,
                    "Content-Length": "\(contentLength)",
                    "Accept-Ranges": "bytes"
                ]
                if let cspHeader {
                    headers[cspHeader.name] = cspHeader.value
                }
                // ACAO only on media — unconditional * leaked text/JSON cross-origin.
                if Self.requiresMediaCORSExposure(for: mime) {
                    headers["Access-Control-Allow-Origin"] = "*"
                }
                if let range {
                    headers["Content-Range"] = "bytes \(range.start)-\(range.end)/\(totalLength)"
                }

                let response = HTTPURLResponse(
                    url: url,
                    statusCode: statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) ?? URLResponse(
                    url: url,
                    mimeType: mime,
                    expectedContentLength: contentLength,
                    textEncodingName: nil
                )

                await delivery.deliver(response: response)
                try await Self.stream(
                    source,
                    to: delivery,
                    offset: range?.start ?? 0,
                    length: contentLength
                )
                await delivery.finish()
            } catch is CancellationError {
                await delivery.fail(with: Self.makeError(.cancelled, "Request cancelled"))
            } catch {
                let isMissingFile = (error as NSError).domain == NSCocoaErrorDomain
                    && ((error as NSError).code == NSFileReadNoSuchFileError
                        || (error as NSError).code == NSFileNoSuchFileError)
                if isMissingFile, case .file(let fileURL) = source {
                    await self?.logMissingResource(fileURL: fileURL, requestURL: url)
                } else {
                    Logger.warning("FolderScheme: \(source.lastComponent) — \(error.localizedDescription)", category: .screenManager)
                }
                await delivery.fail(with: error)
            }

            _ = await MainActor.run {
                self?.activeTasks.removeValue(forKey: taskID)
            }
        }

        activeTasks[taskID] = ActiveTask(worker: worker, delivery: delivery)
        if delivery.hasTerminated {
            activeTasks.removeValue(forKey: taskID)
        }
    }

    /// Package entry lookup; nil → loose-folder fallback. Path safety via canonicalLookupName.
    private func packageByteSource(for url: URL) -> (source: ByteSource, mime: String)? {
        guard let backing = activePackageBacking else { return nil }
        // Normalize Windows `\` paths; canonicalLookupName still rejects `..`.
        let requestPath = (url.path.removingPercentEncoding ?? url.path)
            .replacingOccurrences(of: "\\", with: "/")
        let relativePath = requestPath.hasPrefix("/") ? String(requestPath.dropFirst()) : requestPath
        guard let lookup = WallpaperEnginePackage.canonicalLookupName(relativePath) else { return nil }

        if let entry = backing.package.entry(named: lookup) {
            return (Self.packageSource(for: entry, in: backing), Self.mimeType(forEntryName: entry.name))
        }
        // Same Ogg sibling substitution as the loose-folder path.
        if let fallback = Self.packageOggFallbackEntry(for: lookup, in: backing.package) {
            let requested = (lookup as NSString).lastPathComponent
            if !reportedOggSubstitutions.contains(requested) {
                reportedOggSubstitutions.insert(requested)
                Logger.info(
                    "FolderScheme: serving \(fallback.name) for \(requested) from package (macOS WebKit Ogg/Opus decoder workaround)",
                    category: .screenManager
                )
            }
            return (Self.packageSource(for: fallback, in: backing), Self.mimeType(forEntryName: fallback.name))
        }
        return nil
    }

    nonisolated private static func packageSource(
        for entry: WallpaperEnginePackage.Entry,
        in backing: PackageBacking
    ) -> ByteSource {
        .packageEntry(
            packageURL: backing.url,
            absoluteStart: backing.package.dataStart + entry.dataOffset,
            size: entry.dataSize
        )
    }

    nonisolated private static func packageOggFallbackEntry(
        for lookup: String,
        in package: WallpaperEnginePackage
    ) -> WallpaperEnginePackage.Entry? {
        let ext = (lookup as NSString).pathExtension.lowercased()
        guard ext == "ogg" || ext == "oga" || ext == "opus" else { return nil }
        let base = (lookup as NSString).deletingPathExtension
        for candidateExt in oggFallbackExtensions {
            if let entry = package.entry(named: "\(base).\(candidateExt)") {
                return entry
            }
        }
        return nil
    }

    /// One log per filename: request path, resolved path, siblings, codec hints.
    @MainActor
    private func logMissingResource(fileURL: URL, requestURL: URL) {
        guard reportedMissingResources.insert(fileURL.lastPathComponent).inserted else { return }

        let fm = FileManager.default
        let exists = fm.fileExists(atPath: fileURL.path)
        let parent = fileURL.deletingLastPathComponent()
        var siblingPreview = ""
        if let entries = try? fm.contentsOfDirectory(atPath: parent.path) {
            let sorted = entries.sorted()
            let head = sorted.prefix(10)
            let extra = sorted.count > 10 ? " (+\(sorted.count - 10) more)" : ""
            siblingPreview = head.isEmpty
                ? " | parentEmpty"
                : " | parent=[\(head.joined(separator: ", "))]\(extra)"
        } else {
            siblingPreview = " | parentUnreadable"
        }

        let codecHint: String
        switch fileURL.pathExtension.lowercased() {
        case "ogg", "oga", "opus":
            codecHint = " | hint=Ogg/Opus has historically poor WebKit support on macOS — convert to .mp3 / .aac if 404 persists"
        case "webm":
            codecHint = " | hint=WebM audio/video has limited WebKit support on macOS"
        default:
            codecHint = ""
        }

        Logger.info(
            """
            FolderScheme 404: \(fileURL.lastPathComponent) \
            requested=\(requestURL.path) \
            resolved=\(fileURL.path) \
            onDisk=\(exists)\(siblingPreview)\(codecHint)
            """,
            category: .screenManager
        )
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        guard let entry = activeTasks.removeValue(forKey: taskID) else { return }
        entry.cancel()
    }

    private func cancelAllActiveTasks() {
        let entries = activeTasks
        activeTasks.removeAll()
        for entry in entries.values {
            entry.cancel()
        }
    }

    // MARK: - Validation

    private func validateRequest(_ request: URLRequest, url: URL) throws {
        guard url.host?.lowercased() == Self.host else {
            throw Self.makeError(.badURL, "Host mismatch")
        }
        guard activeFolderURL != nil else {
            throw Self.makeError(.notConnectedToInternet, "No active folder")
        }

        let isTopLevel = request.mainDocumentURL == nil || request.mainDocumentURL == url
        if isTopLevel, !topLevelNonceIsValid(for: url) {
            throw Self.makeError(.badURL, "Invalid folder session nonce")
        }
    }

    private func topLevelNonceIsValid(for url: URL) -> Bool {
        guard let sessionNonce,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.count == 1,
              items[0].name == "n",
              items[0].value == sessionNonce else {
            return false
        }
        return true
    }

    // MARK: - Helpers

    /// Prefer non-Ogg siblings: WebKit Ogg/Opus is flaky; WPE often hardcodes .ogg.
    nonisolated private static let oggFallbackExtensions: [String] = ["mp3", "m4a", "aac", "wav", "flac"]

    nonisolated static func oggFallbackURL(for primary: URL) -> URL? {
        let ext = primary.pathExtension.lowercased()
        guard ext == "ogg" || ext == "oga" || ext == "opus" else { return nil }
        let parent = primary.deletingLastPathComponent()
        let baseName = primary.deletingPathExtension().lastPathComponent
        let fm = FileManager.default
        for candidateExt in oggFallbackExtensions {
            let candidate = parent.appendingPathComponent("\(baseName).\(candidateExt)")
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func resolvedFileURL(for requestURL: URL, inside folderURL: URL) throws -> URL {
        let rootURL = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        // Windows `\` → `/`; containment check still rejects `..`.
        let requestPath = (requestURL.path.removingPercentEncoding ?? requestURL.path)
            .replacingOccurrences(of: "\\", with: "/")
        let relativePath = requestPath.hasPrefix("/") ? String(requestPath.dropFirst()) : requestPath
        let candidate = rootURL
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let rootPath = normalizedPath(rootURL.path(percentEncoded: false))
        let candidatePath = normalizedPath(candidate.path(percentEncoded: false))

        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw Self.makeError(.noPermissionsToReadFile, "Path escapes folder")
        }

        return candidate
    }

    nonisolated private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    nonisolated private static func fileSize(for url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw Self.makeError(.cannotOpenFile, "Requested resource is not a regular file")
        }
        guard let fileSize = values.fileSize else {
            throw Self.makeError(.cannotOpenFile, "Missing file size")
        }
        return fileSize
    }

    nonisolated private static func streamFile(
        _ url: URL,
        to delivery: SchemeTaskDelivery,
        offset: Int,
        length: Int
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if offset > 0 {
            try handle.seek(toOffset: UInt64(offset))
        }

        var bytesRemaining = length
        while bytesRemaining > 0 {
            try Task.checkCancellation()
            let chunkLimit = min(responseChunkSize, bytesRemaining)
            let chunk = try handle.read(upToCount: chunkLimit) ?? Data()
            guard !chunk.isEmpty else { break }
            bytesRemaining -= chunk.count
            await delivery.deliver(chunk: chunk)
        }
    }

    nonisolated private static func totalLength(of source: ByteSource) throws -> Int {
        switch source {
        case .file(let url):
            return try fileSize(for: url)
        case .packageEntry(_, _, let size):
            guard let length = Int(exactly: size) else {
                throw makeError(.cannotOpenFile, "Package entry exceeds addressable size")
            }
            return length
        }
    }

    nonisolated private static func stream(
        _ source: ByteSource,
        to delivery: SchemeTaskDelivery,
        offset: Int,
        length: Int
    ) async throws {
        switch source {
        case .file(let url):
            try await streamFile(url, to: delivery, offset: offset, length: length)
        case .packageEntry(let packageURL, let absoluteStart, _):
            try await streamPackageEntry(
                packageURL: packageURL,
                absoluteStart: absoluteStart,
                to: delivery,
                offset: offset,
                length: length
            )
        }
    }

    /// Per-task handle so concurrent package reads never share a seek offset.
    nonisolated private static func streamPackageEntry(
        packageURL: URL,
        absoluteStart: UInt64,
        to delivery: SchemeTaskDelivery,
        offset: Int,
        length: Int
    ) async throws {
        let handle = try FileHandle(forReadingFrom: packageURL)
        defer { try? handle.close() }

        try handle.seek(toOffset: absoluteStart + UInt64(max(0, offset)))

        var bytesRemaining = length
        while bytesRemaining > 0 {
            try Task.checkCancellation()
            let chunkLimit = min(responseChunkSize, bytesRemaining)
            let chunk = try handle.read(upToCount: chunkLimit) ?? Data()
            guard !chunk.isEmpty else { break }
            bytesRemaining -= chunk.count
            await delivery.deliver(chunk: chunk)
        }
        // Known size: short read = truncated package, not EOF.
        if bytesRemaining > 0 {
            throw makeError(.cannotParseResponse, "Package entry truncated by \(bytesRemaining) bytes")
        }
    }

    nonisolated private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private struct ByteRange: Sendable {
        let start: Int
        let end: Int
        var length: Int { end - start + 1 }
    }

    nonisolated private static func byteRange(from header: String?, totalLength: Int) -> ByteRange? {
        guard totalLength > 0,
              let header,
              header.lowercased().hasPrefix("bytes="),
              !header.contains(",") else { return nil }

        let spec = String(header.dropFirst("bytes=".count))
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            guard let suffixLength = Int(parts[1]), suffixLength > 0 else { return nil }
            let length = min(suffixLength, totalLength)
            let start = totalLength - length
            return ByteRange(start: start, end: totalLength - 1)
        }

        guard let start = Int(parts[0]), start >= 0, start < totalLength else { return nil }

        let end: Int
        if parts[1].isEmpty {
            end = totalLength - 1
        } else if let parsed = Int(parts[1]), parsed >= start {
            end = min(parsed, totalLength - 1)
        } else {
            return nil
        }

        return ByteRange(start: start, end: end)
    }

    nonisolated private static func mimeType(for url: URL) -> String {
        mimeType(forPathExtension: url.pathExtension)
    }

    nonisolated private static func mimeType(forEntryName name: String) -> String {
        mimeType(forPathExtension: (name as NSString).pathExtension)
    }

    nonisolated private static func mimeType(forPathExtension rawExtension: String) -> String {
        let ext = rawExtension.lowercased()
        if let utType = UTType(filenameExtension: ext), let mime = utType.preferredMIMEType {
            return mime
        }
        switch ext {
        case "js", "mjs": return "application/javascript"
        case "wasm":      return "application/wasm"
        case "json":      return "application/json"
        case "ogg":       return "audio/ogg"
        case "oga":       return "audio/ogg"
        case "opus":      return "audio/ogg"
        case "mp3":       return "audio/mpeg"
        case "m4a":       return "audio/mp4"
        case "wav":       return "audio/wav"
        case "flac":      return "audio/flac"
        case "webm":      return "audio/webm"
        case "atlas":     return "text/plain"
        case "skel":      return "application/octet-stream"
        default:          return "application/octet-stream"
        }
    }

    /// Media only needs ACAO for nested-iframe playback; text stays same-origin.
    nonisolated static func requiresMediaCORSExposure(for mime: String) -> Bool {
        mime.hasPrefix("audio/") || mime.hasPrefix("video/")
    }

    nonisolated static func makeError(_ code: URLError.Code, _ message: String? = nil) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        return NSError(domain: NSURLErrorDomain, code: code.rawValue, userInfo: info)
    }
}

// MARK: - Internal Types

private enum ByteSource: Sendable {
    case file(URL)
    case packageEntry(packageURL: URL, absoluteStart: UInt64, size: UInt64)

    var lastComponent: String {
        switch self {
        case .file(let url):
            return url.lastPathComponent
        case .packageEntry(let packageURL, _, _):
            return "\(packageURL.lastPathComponent)#entry"
        }
    }
}

private struct ActiveTask {
    let worker: Task<Void, Never>
    let delivery: SchemeTaskDelivery

    @MainActor
    func cancel() {
        delivery.markStopped()
        worker.cancel()
    }
}

/// Main-thread task bridge; drops late chunks after `markStopped()`.
private final class SchemeTaskDelivery: @unchecked Sendable {
    private let task: any WKURLSchemeTask
    @MainActor private var isLive: Bool = true

    init(_ task: any WKURLSchemeTask) {
        self.task = task
    }

    @MainActor
    var hasTerminated: Bool { !isLive }

    @MainActor
    func markStopped() {
        isLive = false
    }

    @MainActor
    func deliver(response: URLResponse) {
        guard isLive else { return }
        task.didReceive(response)
    }

    @MainActor
    func deliver(chunk data: Data) {
        guard isLive else { return }
        task.didReceive(data)
    }

    @MainActor
    func finish() {
        guard isLive else { return }
        isLive = false
        task.didFinish()
    }

    @MainActor
    func fail(with error: Error) {
        guard isLive else { return }
        isLive = false
        task.didFailWithError(error)
    }
}
