#if !LITE_BUILD
import AppKit
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

/// Opt-in scene-debug dumps (GLSL/MSL/errors/first-frame) under Application Support.
/// `@unchecked Sendable`: `session` under `sessionLock`; I/O on `writeQueue`.
final class WPESceneDebugArtifacts: @unchecked Sendable {

    static let shared = WPESceneDebugArtifacts()

    static let defaultsKey = "WPESceneDebugArtifactsEnabled"

    private struct ActiveSession {
        let workshopID: String
        let folderURL: URL
        let logURL: URL
        var passCounter: Int
        var noteNames: Set<String>
    }

    private var session: ActiveSession?
    private let sessionLock = NSLock()
    private let writeQueue = DispatchQueue(label: "wpe.scene.debug.artifacts", qos: .utility)

    #if DEBUG
    private let testingEnabledOverrideLock = NSLock()
    private var testingEnabledOverride: Bool?

    /// Pass nil to clear.
    func setEnabledForTesting(_ enabled: Bool?) {
        testingEnabledOverrideLock.lock()
        testingEnabledOverride = enabled
        testingEnabledOverrideLock.unlock()
    }
    #endif

    /// Oldest folders pruned first when either bound is exceeded; newest always kept.
    private let maxSessionFolders = 40
    private let maxTotalBytes: UInt64 = 512 * 1024 * 1024  // 512 MiB
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        return f
    }()

    /// DEBUG-only master enable (Release always off; default off even in DEBUG).
    var isEnabled: Bool {
        #if DEBUG
        testingEnabledOverrideLock.lock()
        let testingOverride = testingEnabledOverride
        testingEnabledOverrideLock.unlock()
        if let testingOverride {
            return testingOverride
        }
        // Oracle captures also use the shared artifact directory; both switches remain live reads.
        // DEBUG-only cost — Release compiles isEnabled to a constant false.
        return UserDefaults.appScoped().bool(forKey: Self.defaultsKey) || WPEOracleMode.isEnabled
        #else
        return false
        #endif
    }

    static var rootURL: URL? {
        let fm = FileManager.default
        guard let support = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let root = support
            .appendingPathComponent("LiveWallpaper", isDirectory: true)
            .appendingPathComponent("scene-debug", isDirectory: true)
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        } catch {
            Logger.warning(
                "Scene debug root unavailable: \(error)",
                category: .wpeRender
            )
            return nil
        }
    }

    /// Closes any prior session implicitly.
    @discardableResult
    func beginSession(workshopID: String, descriptor: String) -> URL? {
        guard isEnabled else { return nil }
        guard let root = Self.rootURL else { return nil }
        pruneOldSessions(under: root)

        let stamp = compactTimestamp(from: Date())
        let folder = root.appendingPathComponent("\(stamp)-\(workshopID)-\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            Logger.warning(
                "Scene debug session create failed: \(error)",
                category: .wpeRender
            )
            return nil
        }

        let logURL = folder.appendingPathComponent("scene.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        sessionLock.lock()
        session = ActiveSession(
            workshopID: workshopID,
            folderURL: folder,
            logURL: logURL,
            passCounter: 0,
            noteNames: []
        )
        sessionLock.unlock()

        let info = """
        workshopID: \(workshopID)
        opened: \(ISO8601DateFormatter().string(from: Date()))
        descriptor: \(descriptor)
        """
        write(info, to: folder.appendingPathComponent("scene-info.txt"))

        Logger.notice(
            "Scene debug session opened at \(folder.path)",
            category: .wpeRender
        )
        return folder
    }

    private func pruneOldSessions(under root: URL) {
        let maxFolders = maxSessionFolders
        let maxBytes = maxTotalBytes
        writeQueue.async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }

            let folders = children
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { url -> (url: URL, date: Date, size: UInt64) in
                    let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return (url, date, Self.directorySize(of: url, fm: fm))
                }
                .sorted { $0.date > $1.date }

            var runningBytes: UInt64 = 0
            for (index, folder) in folders.enumerated() {
                runningBytes += folder.size
                let overCount = index + 1 > maxFolders
                let overBytes = index > 0 && runningBytes > maxBytes
                if overCount || overBytes {
                    try? fm.removeItem(at: folder.url)
                }
            }
        }
    }

    private static func directorySize(of url: URL, fm: FileManager) -> UInt64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
            total += UInt64(size)
        }
        return total
    }

    /// Drops the session reference; files stay on disk.
    func endSession() {
        sessionLock.lock()
        let workshopID = session?.workshopID
        session = nil
        sessionLock.unlock()
        if let workshopID {
            Logger.notice(
                "Scene debug session closed for \(workshopID)",
                category: .wpeRender
            )
        }
    }

    /// Shared instead of one formatter per log line. Only ever touched inside
    /// `writeQueue` (serial), because `ISO8601DateFormatter` — unlike
    /// `DateFormatter`, which the SDK marks `NS_SWIFT_SENDABLE` — carries no
    /// documented thread-safety guarantee.
    private nonisolated(unsafe) static let logTimestampFormatter = ISO8601DateFormatter()

    func appendLog(_ message: String, level: Logger.Level = .info) {
        guard isEnabled else { return }
        sessionLock.lock()
        let url = session?.logURL
        sessionLock.unlock()
        guard let url else { return }
        let timestamp = Date()
        let tag = LogFileSink.levelTag(level)
        writeQueue.async {
            let line = "[\(Self.logTimestampFormatter.string(from: timestamp))][\(tag)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        }
    }

    func recordFirstFrameStats(_ stats: WPEMetalTextureVisualStats) {
        guard isEnabled else { return }
        recordNote(name: "first-frame-stats.txt", contents: stats.description)
        appendLog("[frame.stats] \(stats.oneLineDescription)")
    }

    func recordResolutionSummary(_ snapshot: WPEResolutionDiagnosticsSnapshot) {
        guard isEnabled else { return }
        let counts = snapshot.resolvedByOrigin
        let dependencyCount = counts.reduce(0) { partial, entry in
            if case .dependency = entry.key { return partial + entry.value }
            return partial
        }
        var lines: [String] = [
            "events: \(snapshot.events.count)",
            "resolved: \(snapshot.resolvedCount)",
            "missing: \(snapshot.missedRefs.count)",
            "scene: \(counts[.scene, default: 0])",
            "builtin: \(counts[.builtin, default: 0])",
            "engineAssets: \(counts[.engineAssets, default: 0])",
            "dependency: \(dependencyCount)"
        ]
        if !snapshot.missedRefs.isEmpty {
            lines.append("misses:")
            lines.append(contentsOf: snapshot.missedRefs.prefix(40).map {
                "  \($0.ref) -> \($0.finalOutcome.debugLabel)"
            })
        }
        recordNote(name: "resolution-summary.txt", contents: lines.joined(separator: "\n"))
        appendLog(
            "[resolution] events=\(snapshot.events.count) resolved=\(snapshot.resolvedCount) missing=\(snapshot.missedRefs.count)"
        )
    }

    func recordShaderFailure(
        shaderName: String,
        originalVertex: String?,
        processedVertex: String?,
        originalFragment: String?,
        processedFragment: String?,
        translatedMSL: String?,
        errorText: String
    ) {
        guard isEnabled else { return }

        sessionLock.lock()
        guard var current = session else {
            sessionLock.unlock()
            return
        }
        current.passCounter += 1
        let passIndex = current.passCounter
        let folderURL = current.folderURL
        session = current
        sessionLock.unlock()

        let folderName = String(format: "%03d-%@", passIndex, safeFileName(shaderName))
        let dir = folderURL
            .appendingPathComponent("shaders", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Logger.warning(
                "Scene debug shader dir create failed: \(error)",
                category: .wpeRender
            )
            return
        }

        if let originalVertex {
            write(originalVertex, to: dir.appendingPathComponent("01-vertex-original.glsl"))
        }
        if let processedVertex {
            write(processedVertex, to: dir.appendingPathComponent("02-vertex-processed.glsl"))
        }
        if let originalFragment {
            write(originalFragment, to: dir.appendingPathComponent("03-fragment-original.glsl"))
        }
        if let processedFragment {
            write(processedFragment, to: dir.appendingPathComponent("04-fragment-processed.glsl"))
        }
        if let translatedMSL {
            write(translatedMSL, to: dir.appendingPathComponent("05-msl-translated.msl"))
        }
        write(errorText, to: dir.appendingPathComponent("06-error.txt"))

        Logger.error(
            "Shader '\(shaderName)' compile failure dumped → \(dir.path) — \(firstLine(of: errorText))",
            category: .wpeRender
        )
        appendLog("[shader fail] '\(shaderName)' → shaders/\(folderName)/  \(firstLine(of: errorText))", level: .error)
    }

    func recordPipelineFailure(
        fragmentName: String,
        blendMode: String,
        detail: String
    ) {
        guard isEnabled else { return }
        sessionLock.lock()
        guard let current = session else {
            sessionLock.unlock()
            return
        }
        let folderURL = current.folderURL
        let counter = current.passCounter
        sessionLock.unlock()

        let dir = folderURL.appendingPathComponent("pipelines", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = String(
            format: "%03d-%@-%@.err",
            counter + 1,
            safeFileName(fragmentName),
            safeFileName(blendMode)
        )
        write(detail, to: dir.appendingPathComponent(filename))
        Logger.error(
            "Pipeline '\(fragmentName)' (blend=\(blendMode)) build failed: \(firstLine(of: detail))",
            category: .wpeRender
        )
        appendLog("[pipeline fail] '\(fragmentName)' blend=\(blendMode) → pipelines/\(filename)", level: .error)
    }

    func recordFirstFrame(image: NSImage) {
        guard isEnabled else { return }
        sessionLock.lock()
        let folderURL = session?.folderURL
        sessionLock.unlock()
        guard let folderURL else { return }
        let url = folderURL.appendingPathComponent("first-frame.png")
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            Logger.warning(
                "Scene debug first-frame snapshot failed (no PNG representation)",
                category: .wpeRender
            )
            return
        }
        do {
            try png.write(to: url, options: .atomic)
            Logger.notice(
                "Scene debug first frame saved → \(url.path)",
                category: .wpeRender
            )
        } catch {
            Logger.warning(
                "Scene debug first-frame write failed: \(error)",
                category: .wpeRender
            )
        }
    }

    func recordNote(name: String, contents: String) {
        guard isEnabled else { return }
        sessionLock.lock()
        let folderURL = session?.folderURL
        sessionLock.unlock()
        guard let folderURL else { return }
        write(contents, to: folderURL.appendingPathComponent(safeFileName(name)))
    }

    /// Writes once per session — for successful shader dumps that would
    /// otherwise be rewritten every rendered frame.
    func recordNoteOnce(name: String, contents: String) {
        guard isEnabled else { return }
        let safeName = safeFileName(name)
        sessionLock.lock()
        guard var current = session else {
            sessionLock.unlock()
            return
        }
        guard current.noteNames.insert(safeName).inserted else {
            sessionLock.unlock()
            return
        }
        let folderURL = current.folderURL
        session = current
        sessionLock.unlock()
        write(contents, to: folderURL.appendingPathComponent(safeName))
    }

    func dumpRawTexMetadata(name: String, info: WPETexInfo, bitmap: WPETexBitmapBlock) {
        guard isEnabled else { return }
        var lines: [String] = []
        lines.append("container=\(info.containerVersion) infoVersion=\(info.infoVersion)")
        lines.append("size=\(info.width)x\(info.height) imageSize=\(info.imageWidth)x\(info.imageHeight) unkInt0=\(info.unknownInt0)")
        let formatLabel = info.format?.debugLabel ?? "unknown(\(info.textureFormatCode))"
        lines.append("format=\(formatLabel) flags=0x\(String(info.flags, radix: 16))")
        if let rawExtension = info.flag0x40Extension {
            let rawBits = UInt32(bitPattern: rawExtension.rawValue)
            lines.append(
                "flag0x40Raw=0x\(String(rawBits, radix: 16)) sourceRange="
                    + "\(rawExtension.sourceRange.lowerBound)..<\(rawExtension.sourceRange.upperBound)"
            )
        }
        let sourceFormat = bitmap.sourceImageFormatCode?.description ?? "nil"
        lines.append("bitmapVersion=\(bitmap.version) sourceImageFormatCode=\(sourceFormat) isVideo=\(bitmap.isVideoPayload) usesEncoded=\(bitmap.usesEncodedImagePayload)")
        lines.append("frames=\(bitmap.frames.count)")
        for variant in bitmap.conditionalVariants {
            let mips = bitmap.conditionalRecords.count(where: { $0.variantID == variant.variantID })
            let condition = String(bytes: variant.conditionBytes, encoding: .utf8) ?? "<invalid UTF-8 condition>"
            lines.append("  conditional variantID=\(variant.variantID) mips=\(mips) condition=\(condition)")
        }
        for (frameIndex, mipmaps) in bitmap.frames.enumerated() {
            for mipmap in mipmaps {
                var line = "  frame=\(frameIndex) mip=\(mipmap.index) size=\(mipmap.width)x\(mipmap.height) stored=\(mipmap.storedByteCount) compressed=\(mipmap.isCompressed)"
                if let decompressed = mipmap.decompressedByteCount {
                    line += " decompressed=\(decompressed)"
                }
                lines.append(line)
            }
        }
        recordNote(name: "tex-meta-\(name).txt", contents: lines.joined(separator: "\n"))
    }

    var activeSessionFolder: URL? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return session?.folderURL
    }

    #if DEBUG
    func recordPassOutputBytes(name: String, bytes: Data, sessionFolder: URL) throws -> URL? {
        guard isEnabled, activeSessionFolder == sessionFolder else { return nil }
        let url = sessionFolder.appendingPathComponent(safeFileName(name))
        try writeQueue.sync {
            try bytes.write(to: url, options: .withoutOverwriting)
        }
        return url
    }
    #endif

    // MARK: - Helpers

    private func write(_ contents: String, to url: URL) {
        writeQueue.async {
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Logger.warning(
                    "Scene debug write failed for \(url.lastPathComponent): \(error)",
                    category: .wpeRender
                )
            }
        }
    }

    private func compactTimestamp(from date: Date) -> String {
        let raw = isoFormatter.string(from: date)
        return raw
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "T", with: "-")
    }

    private func safeFileName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>| \t\n")
        return raw
            .components(separatedBy: illegal)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    private func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }


}
#endif
