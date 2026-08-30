import Foundation
import Darwin

struct SessionFileCandidate: Equatable {
    var url: URL
    var sessionId: String          // filename stem (the session UUID)
    var projectDirName: String     // encoded cwd, e.g. "-Users-me-proj"
    var modifiedAt: Date
    var sizeBytes: UInt64
}

/// A `sessions/<PID>.json` process descriptor.
struct ClaudePIDDescriptor: Equatable {
    var pid: Int32
    var sessionId: String
    var cwd: String?
    var kind: String?
    var name: String?
    var startedAt: Date?
}

/// Filesystem discovery + process-liveness for Claude Code sessions. All methods
/// are read-only against the user-granted `~/.claude` root.
struct ClaudeSessionScanner {
    let rootURL: URL

    /// Reject descriptors whose live process start time drifts from the recorded
    /// `startedAt` by more than this — cheap defense against PID reuse.
    private static let pidReuseSlack: TimeInterval = 5

    /// A directory's mtime moves when an entry is added, removed, or renamed, but not when a file inside it
    /// is appended to — so it may gate re-*listing* the directory and nothing else. Every listed transcript
    /// is still stat'd on every pass, or a resumed session older than `lookback` would never come back into
    /// view.
    private struct DirectoryListing {
        var modifiedAt: Date
        var transcriptPaths: [String]
    }

    private var cachedProjectsRootModifiedAt: Date?
    private var cachedProjectDirs: [URL] = []
    private var cachedListings: [URL: DirectoryListing] = [:]

    /// Test seam: `contentsOfDirectory` calls issued since init.
    private(set) var directoryListingCount = 0

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: - Transcript discovery

    mutating func discoverTranscripts(
        now: Date = Date(),
        lookback: TimeInterval = 48 * 3600,
        limit: Int = 40
    ) throws -> [SessionFileCandidate] {
        let projectsRoot = rootURL.appendingPathComponent("projects", isDirectory: true)
        let fm = FileManager.default

        let rootModifiedAt = Self.status(ofPath: projectsRoot.path(percentEncoded: false))?.modifiedAt
        if rootModifiedAt == nil || rootModifiedAt != cachedProjectsRootModifiedAt {
            directoryListingCount += 1
            let entries = try fm.contentsOfDirectory(
                at: projectsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            cachedProjectDirs = entries.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            }
            cachedProjectsRootModifiedAt = rootModifiedAt
            let live = Set(cachedProjectDirs)
            cachedListings = cachedListings.filter { live.contains($0.key) }
        }

        let cutoff = now.addingTimeInterval(-lookback)
        var candidates: [SessionFileCandidate] = []

        for dir in cachedProjectDirs {
            let projectDirName = dir.lastPathComponent
            let dirModifiedAt = Self.status(ofPath: dir.path(percentEncoded: false))?.modifiedAt
            let transcriptPaths: [String]
            if let dirModifiedAt, let cached = cachedListings[dir], cached.modifiedAt == dirModifiedAt {
                transcriptPaths = cached.transcriptPaths
            } else {
                directoryListingCount += 1
                transcriptPaths = ((try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? [])
                    .filter { $0.pathExtension == "jsonl" }
                    .map { $0.path(percentEncoded: false) }
                if let dirModifiedAt {
                    cachedListings[dir] = DirectoryListing(
                        modifiedAt: dirModifiedAt,
                        transcriptPaths: transcriptPaths
                    )
                } else {
                    cachedListings[dir] = nil
                }
            }

            for path in transcriptPaths {
                guard let status = Self.status(ofPath: path), status.modifiedAt >= cutoff else { continue }
                let file = URL(fileURLWithPath: path)
                candidates.append(SessionFileCandidate(
                    url: file,
                    sessionId: file.deletingPathExtension().lastPathComponent,
                    projectDirName: projectDirName,
                    modifiedAt: status.modifiedAt,
                    sizeBytes: status.sizeBytes
                ))
            }
        }

        candidates.sort { $0.modifiedAt > $1.modifiedAt }
        if candidates.count > limit {
            candidates = Array(candidates.prefix(limit))
        }
        return candidates
    }

    /// `stat(2)`, not `URLResourceValues`: an `NSURL` memoizes every resource value it's asked for, so
    /// re-reading a URL held across passes hands back the mtime from when the listing was built — exactly what
    /// must not be missed when a transcript is being appended to. `stat` also follows symlinks, so a linked
    /// project directory reports its target's mtime, not the link's (which never moves).
    private static func status(ofPath path: String) -> (modifiedAt: Date, sizeBytes: UInt64)? {
        var info = Darwin.stat()
        guard stat(path, &info) == 0 else { return nil }
        let seconds = Double(info.st_mtimespec.tv_sec)
            + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return (Date(timeIntervalSince1970: seconds), UInt64(max(info.st_size, 0)))
    }

    // MARK: - PID descriptors

    /// Parse every `sessions/<PID>.json`. Missing dir ⇒ empty (not an error);
    /// malformed individual files are skipped.
    func loadPIDDescriptors() -> [ClaudePIDDescriptor] {
        let sessionsRoot = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [ClaudePIDDescriptor] = []
        for file in files where file.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let pid = (object["pid"] as? Int).map(Int32.init) ?? (object["pid"] as? NSNumber).map({ $0.int32Value }),
                let sessionId = object["sessionId"] as? String
            else { continue }

            var startedAt: Date?
            if let ms = object["startedAt"] as? Double {
                startedAt = Date(timeIntervalSince1970: ms / 1000)
            } else if let ms = object["startedAt"] as? Int {
                startedAt = Date(timeIntervalSince1970: Double(ms) / 1000)
            }

            result.append(ClaudePIDDescriptor(
                pid: pid,
                sessionId: sessionId,
                cwd: object["cwd"] as? String,
                kind: object["kind"] as? String,
                name: object["name"] as? String,
                startedAt: startedAt
            ))
        }
        return result
    }

    func livenessBySession(_ descriptors: [ClaudePIDDescriptor]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for descriptor in descriptors {
            let alive = isAlive(descriptor)
            map[descriptor.sessionId] = (map[descriptor.sessionId] ?? false) || alive
        }
        return map
    }

    /// Liveness for one descriptor: `kill(pid, 0) == 0`, plus a best-effort start
    /// time cross-check when the OS can supply it.
    func isAlive(_ descriptor: ClaudePIDDescriptor) -> Bool {
        guard descriptor.pid > 0 else { return false }
        if kill(descriptor.pid, 0) != 0 {
            return errno == EPERM
        }
        guard
            let recorded = descriptor.startedAt,
            let actual = Self.processStartTime(pid: descriptor.pid)
        else {
            return true   // can't verify start time ⇒ trust kill(0).
        }
        return abs(actual.timeIntervalSince(recorded)) <= Self.pidReuseSlack
    }

    /// Process start time via `sysctl(KERN_PROC_PID)`. Best-effort — returns nil
    /// on any failure so callers fall back to the kill(0) result.
    static func processStartTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec != 0 || tv.tv_usec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
    }
}
