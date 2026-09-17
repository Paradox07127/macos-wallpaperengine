import Foundation

enum SystemWallpaperPlaybackMode: String, Codable, Equatable, CaseIterable {
    case always
    case stillOnDesktop
}

struct SystemWallpaperManifest: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var fileName: String
        var thumbnailFileName: String?
        var addedAt: Date
    }

    var version: Int
    var items: [Item]
    var playbackMode: SystemWallpaperPlaybackMode

    static let currentVersion = 1
    static let empty = SystemWallpaperManifest(
        version: currentVersion,
        items: [],
        playbackMode: .always
    )

    init(version: Int, items: [Item], playbackMode: SystemWallpaperPlaybackMode = .always) {
        self.version = version
        self.items = items
        self.playbackMode = playbackMode
    }

    private enum CodingKeys: String, CodingKey { case version, items, playbackMode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        // File names are used verbatim under Videos/; drop an item whose name would escape the directory rather than fail the whole manifest.
        items = try c.decode([Item].self, forKey: .items).filter { item in
            Self.isSafeFileName(item.fileName)
                && item.thumbnailFileName.map(Self.isSafeFileName) != false
        }
        // Manifests written before the switch existed kept playing on the
        // desktop, so that stays their behaviour after an update.
        playbackMode = try c.decodeIfPresent(SystemWallpaperPlaybackMode.self, forKey: .playbackMode) ?? .always
    }

    /// A single path component: no separators, no traversal, not empty.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\0")
            && name != "." && name != ".."
    }
}

struct SystemWallpaperProviderIdentity: Codable, Equatable {
    /// CFBundleVersion of the appex. This half separates two processes an in-place update leaves behind at the same path.
    var build: String
    /// Absolute path of the appex bundle. This is the other half: two copies
    /// installed at different paths share a bundle id and both stay registered.
    var bundlePath: String
    /// Diagnostics only — which process to look at when a stale beat shows up.
    var pid: Int32

    static func current(bundle: Bundle = .main) -> SystemWallpaperProviderIdentity {
        SystemWallpaperProviderIdentity(
            build: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "",
            bundlePath: bundle.bundlePath,
            pid: ProcessInfo.processInfo.processIdentifier
        )
    }

    /// Read the bundled appex, not the app Info.plist — they carry separate CFBundleVersions. Scan the directory so Lite and Pro share one path.
    static func bundledProvider(host hostBundle: Bundle = .main) -> SystemWallpaperProviderIdentity? {
        let extensions = hostBundle.bundleURL
            .appendingPathComponent("Contents/Extensions", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: extensions,
            includingPropertiesForKeys: nil
        ) else { return nil }
        guard let appex = entries.first(where: { $0.pathExtension == "appex" }),
              let bundle = Bundle(url: appex) else { return nil }
        return SystemWallpaperProviderIdentity(
            build: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "",
            bundlePath: bundle.bundlePath,
            // The bundled copy is not a process; only beats carry a real pid.
            pid: 0
        )
    }
}

/// An appex outlives the bundle it was launched from; lives here so the decision is unit-testable.
enum SystemWallpaperProviderStaleness {
    enum Verdict: Equatable {
        case current
        case bundleGone
        case buildChanged(loaded: String, onDisk: String)
        /// Idle only: the app declares which appex it ships, and this process is not it (another copy of the app, or a leftover build directory).
        case supersededByDeclared(declaredPath: String)

        var shouldRetire: Bool {
            self != .current
        }
    }

    /// `onDiskBuild` is nil when the bundle (or its `Info.plist`) cannot be read.
    static func verdict(loadedBuild: String, onDiskBuild: String?) -> Verdict {
        guard let onDiskBuild else { return .bundleGone }
        guard onDiskBuild == loadedBuild else {
            return .buildChanged(loaded: loadedBuild, onDisk: onDiskBuild)
        }
        return .current
    }

    /// For a process serving zero surfaces. A serving process is never retired for a path mismatch — WallpaperAgent keeps every registered provider resident (suspended once it disconnects), so only the declaration says which idle copy is the real one.
    static func idleVerdict(
        _ bundleVerdict: Verdict,
        ownBundlePath: String,
        declared: SystemWallpaperProviderIdentity?
    ) -> Verdict {
        guard bundleVerdict == .current else { return bundleVerdict }
        guard let declared, !declared.bundlePath.isEmpty,
              normalizedPath(declared.bundlePath) != normalizedPath(ownBundlePath)
        else { return .current }
        return .supersededByDeclared(declaredPath: declared.bundlePath)
    }

    /// Textual only: `standardizingPath` folds `/private` just when the path exists, and the sandboxed appex cannot stat the app's copy of the path anyway.
    private static func normalizedPath(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        for prefix in ["/private/tmp/", "/private/var/", "/private/etc/"] where normalized.hasPrefix(prefix) {
            normalized.removeFirst("/private".count)
            break
        }
        return normalized
    }
}

struct SystemWallpaperHeartbeat: Codable, Equatable {
    var timestamp: Date
    var activeChoiceID: String?
    /// Every choice currently on some display — the single field above keeps
    /// one arbitrary member for readers that predate multi-display support.
    var activeChoiceIDs: [String]?
    /// False when the appex's private-API layout check failed on this OS —
    /// the app shows the "system incompatible" state instead of guessing.
    var runtimeHealthy: Bool
    /// OS build the verdict was reached on. A stale unhealthy from an old build must not keep the feature locked out.
    var osVersion: String?
    /// Layout-check revision. Absent in heartbeats from before this field existed, which were all revision 1.
    var runtimeCheckVersion: Int?
    /// nil provider is unknown, never a mismatch, so a missing stamp cannot make a live extension look dead.
    var provider: SystemWallpaperProviderIdentity?

    /// Bump when the private-API layout check changes, or a fixed check cannot overwrite its predecessor's unhealthy verdict.
    static let currentRuntimeCheckVersion = 1

    init(timestamp: Date, activeChoiceID: String?, activeChoiceIDs: [String]? = nil,
         runtimeHealthy: Bool = true, osVersion: String? = nil,
         runtimeCheckVersion: Int? = SystemWallpaperHeartbeat.currentRuntimeCheckVersion,
         provider: SystemWallpaperProviderIdentity? = nil) {
        self.timestamp = timestamp
        self.activeChoiceID = activeChoiceID
        self.activeChoiceIDs = activeChoiceIDs
        self.runtimeHealthy = runtimeHealthy
        self.osVersion = osVersion
        self.runtimeCheckVersion = runtimeCheckVersion
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, activeChoiceID, activeChoiceIDs, runtimeHealthy, osVersion, runtimeCheckVersion
        case provider
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        activeChoiceID = try c.decodeIfPresent(String.self, forKey: .activeChoiceID)
        activeChoiceIDs = try c.decodeIfPresent([String].self, forKey: .activeChoiceIDs)
        runtimeHealthy = try c.decodeIfPresent(Bool.self, forKey: .runtimeHealthy) ?? true
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion)
        runtimeCheckVersion = try c.decodeIfPresent(Int.self, forKey: .runtimeCheckVersion)
        provider = try c.decodeIfPresent(SystemWallpaperProviderIdentity.self, forKey: .provider)
    }

    /// Reject a beat whose stamp disagrees, and an unstamped beat (leftover 0.6.2). Only a missing expectation disables the check.
    func isFromProvider(matching expected: SystemWallpaperProviderIdentity?) -> Bool {
        guard let expected else { return true }
        guard let provider else { return false }
        return provider.build == expected.build && provider.bundlePath == expected.bundlePath
    }

    /// Bars publishing only when reached on the OS build running now and by the layout-check revision running now.
    var barsPublishing: Bool {
        guard !runtimeHealthy else { return false }
        guard osVersion == nil || osVersion == Self.currentOSVersion() else { return false }
        return (runtimeCheckVersion ?? 1) == Self.currentRuntimeCheckVersion
    }

    func showsChoice(_ itemID: String) -> Bool {
        if let activeChoiceIDs { return activeChoiceIDs.contains(itemID) }
        return activeChoiceID == itemID
    }

    /// Version plus build: beta seeds keep the same x.y.z across weekly builds,
    /// and a layout verdict is only valid for the exact build that produced it.
    static func currentOSVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: max(size, 1))
        let build: String
        if size > 0, sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 {
            build = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        } else {
            build = ""
        }
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)-\(build)"
    }
}

/// Both sides must encode with identical settings or the appex silently reads
/// an empty library — keep the coders here rather than at each call site.
enum SystemWallpaperCoding {
    static var encoder: JSONEncoder { JSONEncoder() }
    static var decoder: JSONDecoder { JSONDecoder() }
}

enum SystemWallpaperPaths {
    static let darwinLibraryChangedNote = "com.loomscreen.wallpaper.libraryChanged"

    /// Real home, not NSHomeDirectory()/homeDirectoryForCurrentUser — those point at the container inside a sandbox.
    static var realHomeDirectory: URL {
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
    }

    static func sharedRoot(hostBundleID: String) -> URL {
        realHomeDirectory
            .appendingPathComponent("Library/Containers/\(hostBundleID)/Data/Library/Application Support/Loomscreen/SystemWallpaper", isDirectory: true)
    }

    static func manifestURL(hostBundleID: String) -> URL {
        sharedRoot(hostBundleID: hostBundleID).appendingPathComponent("manifest.json")
    }

    static func heartbeatURL(hostBundleID: String) -> URL {
        sharedRoot(hostBundleID: hostBundleID).appendingPathComponent("heartbeat.json")
    }

    /// The appex the installed app ships (`SystemWallpaperProviderIdentity`, pid 0), written by the app at launch.
    static func providerURL(hostBundleID: String) -> URL {
        sharedRoot(hostBundleID: hostBundleID).appendingPathComponent("provider.json")
    }

    static func videosDirectory(hostBundleID: String) -> URL {
        sharedRoot(hostBundleID: hostBundleID).appendingPathComponent("Videos", isDirectory: true)
    }
}

enum SystemWallpaperLibrary {
    /// Persist the shrunk manifest first, then delete files — a failed persist stays consistent; a failed delete is an orphan the sweep reclaims.
    static func remove(
        id: String,
        from manifest: SystemWallpaperManifest,
        videosDirectory: URL,
        persist: (SystemWallpaperManifest) throws -> Void,
        onFileRemovalFailure: ((String, any Error) -> Void)? = nil
    ) rethrows -> SystemWallpaperManifest? {
        guard let item = manifest.items.first(where: { $0.id == id }) else { return nil }
        var updated = manifest
        updated.items.removeAll { $0.id == id }
        try persist(updated)
        let manager = FileManager.default
        for name in [item.fileName, item.thumbnailFileName].compactMap({ $0 }) {
            let url = videosDirectory.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.path) else { continue }
            do {
                try manager.removeItem(at: url)
            } catch {
                onFileRemovalFailure?(name, error)
            }
        }
        return updated
    }

    /// Creation time is in the name because copyItem carries the source mtime, so a concurrent sweep would treat a year-old source as ancient. Do not end in .partial — AVFoundation would refuse the file.
    static func stagingFileName(itemID: String, ext: String, now: Date, tag: UUID = UUID()) -> String {
        ".stage-\(Int(now.timeIntervalSince1970))-\(itemID)-\(tag.uuidString).\(ext)"
    }

    /// Use a staging name: this file carries the previous video's mtime, so the sweep's mtime rule would reclaim it mid-republish.
    static func transientBackupName(itemID: String, ext: String, tag: UUID, now: Date) -> String {
        stagingFileName(itemID: "\(itemID)-backup", ext: ext, now: now, tag: tag)
    }

    /// Creation time encoded by `stagingFileName`, or nil for anything that is
    /// not one of ours.
    static func stagingCreation(fileName: String) -> Date? {
        let prefix = ".stage-"
        // Prefix plus a parsable timestamp is the whole test — which also
        // still matches the older `.partial`-suffixed names left on disk.
        guard fileName.hasPrefix(prefix) else { return nil }
        let rest = fileName.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-"),
              let seconds = TimeInterval(rest[rest.startIndex..<dash])
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Two clocks: ordinary orphans by mtime, staging files by the timestamp in the name (source mtime is not theirs), with a longer grace so a slow 4K copy is never touched.
    static func sweepOrphans(
        manifest: SystemWallpaperManifest,
        videosDirectory: URL,
        olderThan age: TimeInterval = 3600,
        stagingGrace: TimeInterval = 24 * 3600,
        now: Date = Date()
    ) {
        var referenced = Set<String>()
        for item in manifest.items {
            referenced.insert(item.fileName)
            if let thumb = item.thumbnailFileName { referenced.insert(thumb) }
        }
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(
            at: videosDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        )) ?? []
        for file in files where !referenced.contains(file.lastPathComponent) {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            // Never recurse into or delete a directory: removing one here would take a whole subtree with it.
            if values?.isDirectory == true { continue }
            let cutoff: TimeInterval
            let reference: Date
            if let created = stagingCreation(fileName: file.lastPathComponent) {
                cutoff = stagingGrace
                reference = created
            } else {
                cutoff = age
                reference = values?.contentModificationDate ?? now
            }
            guard now.timeIntervalSince(reference) > cutoff else { continue }
            try? manager.removeItem(at: file)
        }
    }
}

/// Atomic writes only prevent torn JSON; without this lock the later writer silently drops the earlier change.
enum SystemWallpaperLock {
    enum LockError: LocalizedError {
        case unavailable(Int32)

        var errorDescription: String? {
            String(
                localized: "Couldn't get exclusive access to the System Wallpaper library.",
                comment: "Error shown when the cross-process manifest lock cannot be taken."
            )
        }
    }

    static func withExclusiveLock<T>(root: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = root.appendingPathComponent("manifest.lock")
        let fd = open(lockURL.path, O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else {
            // Fail closed. Running the mutation unserialized is the lost update this lock exists to prevent.
            throw LockError.unavailable(errno)
        }
        defer { close(fd) }
        // EINTR can interrupt flock; giving up there would silently run the mutation unserialized.
        var locked = false
        repeat {
            if flock(fd, LOCK_EX) == 0 {
                locked = true
                break
            }
        } while errno == EINTR
        defer { if locked { flock(fd, LOCK_UN) } }
        guard locked else { throw LockError.unavailable(errno) }
        return try body()
    }
}
