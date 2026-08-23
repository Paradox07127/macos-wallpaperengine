import Darwin
import Foundation

struct CodexSessionScanner: Sendable {
    struct SessionFile: Sendable, Equatable {
        var url: URL
        var modificationDate: Date
        var processAlive: Bool
    }

    enum ScanError: Error, Equatable {
        case unauthorized
    }

    private static let scanWindow: TimeInterval = 48 * 60 * 60
    private static let liveFileWindow: TimeInterval = 10 * 60
    private static let maxFiles = 40
    /// Compatibility budgets for layouts that do not use `sessions/YYYY/MM/DD`.
    private static let fallbackTopLevelEntryLimit = 96
    private static let fallbackDescendantEntryLimit = 256
    private static let fallbackRootLimit = 32
    private static let fallbackDepthLimit = 3

    let rootURL: URL
    private let processProbe: @Sendable () -> Bool
    private let visitObserver: (@Sendable (URL) -> Void)?

    init(
        rootURL: URL,
        processProbe: @escaping @Sendable () -> Bool = { CodexProcessProbe.isCodexRunning() },
        visitObserver: (@Sendable (URL) -> Void)? = nil
    ) {
        self.rootURL = rootURL
        self.processProbe = processProbe
        self.visitObserver = visitObserver
    }

    func scan(now: Date = Date()) throws -> [SessionFile] {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        let rootPath = rootURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ScanError.unauthorized
        }

        let sessionsURL = rootURL.appendingPathComponent("sessions", isDirectory: true)
        var sessionsIsDirectory = ObjCBool(false)
        let sessionsPath = sessionsURL.path(percentEncoded: false)
        guard fileManager.fileExists(atPath: sessionsPath, isDirectory: &sessionsIsDirectory) else {
            return []
        }
        guard sessionsIsDirectory.boolValue else { return [] }
        guard let sessionsValues = try? sessionsURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
            sessionsValues.isDirectory == true,
            sessionsValues.isSymbolicLink != true else {
            throw ScanError.unauthorized
        }

        let cutoff = now.addingTimeInterval(-Self.scanWindow)
        let candidates = try candidateFiles(
            under: sessionsURL,
            cutoff: cutoff,
            now: now,
            fileManager: fileManager
        )

        let codexRunning = processProbe()
        return candidates
            .sorted { lhs, rhs in
                if lhs.modificationDate != rhs.modificationDate {
                    return lhs.modificationDate > rhs.modificationDate
                }
                return lhs.url.path(percentEncoded: false) < rhs.url.path(percentEncoded: false)
            }
            .prefix(Self.maxFiles)
            .map { candidate in
                SessionFile(
                    url: candidate.url,
                    modificationDate: candidate.modificationDate,
                    processAlive: codexRunning && candidate.modificationDate >= now.addingTimeInterval(-Self.liveFileWindow)
                )
            }
    }

    private func candidateFiles(
        under sessionsURL: URL,
        cutoff: Date,
        now: Date,
        fileManager: FileManager
    ) throws -> [(url: URL, modificationDate: Date)] {
        let fileKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .contentModificationDateKey,
        ]
        var candidates: [URL: Date] = [:]

        func consider(_ url: URL, reportVisit: Bool = true) {
            if reportVisit {
                visitObserver?(url)
            }
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: fileKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate >= cutoff else {
                return
            }
            candidates[url.standardizedFileURL] = modificationDate
        }

        for dayURL in Self.inWindowDayDirectories(
            under: sessionsURL,
            cutoff: cutoff,
            now: now
        ) {
            guard Self.isNonSymlinkDirectory(dayURL, beneath: sessionsURL) else { continue }
            visitObserver?(dayURL)
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(
                    at: dayURL,
                    includingPropertiesForKeys: Array(fileKeys),
                    options: [.skipsHiddenFiles]
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                // One unreadable shard must not hide other recent sessions.
                continue
            }
            for child in children {
                consider(child)
            }
        }

        // Older Codex builds or hand-migrated stores may have a non-date layout.
        guard let topLevelEnumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: Array(fileKeys),
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { _, _ in false }
        ) else {
            throw ScanError.unauthorized
        }

        let sessionsComponents = sessionsURL.standardizedFileURL.pathComponents.count
        var topLevelEntries = 0
        var fallbackRoots: [(url: URL, values: URLResourceValues)] = []
        while topLevelEntries < Self.fallbackTopLevelEntryLimit,
              let url = topLevelEnumerator.nextObject() as? URL {
            topLevelEntries += 1
            visitObserver?(url)

            guard let values = try? url.resourceValues(forKeys: fileKeys),
                  values.isSymbolicLink != true,
                  !url.lastPathComponent.hasPrefix("."),
                  !(values.isDirectory == true && Self.isCanonicalYear(url.lastPathComponent)),
                  values.isDirectory == true
                  || (values.isRegularFile == true
                      && url.lastPathComponent.hasPrefix("rollout-")
                      && url.pathExtension == "jsonl") else {
                continue
            }
            if fallbackRoots.count < Self.fallbackRootLimit {
                fallbackRoots.append((url, values))
            }
        }

        var fallbackDescendantEntries = 0
        var walkers: [(enumerator: FileManager.DirectoryEnumerator, exhausted: Bool)] = []
        for root in fallbackRoots {
            if root.values.isDirectory == true {
                if let enumerator = fileManager.enumerator(
                    at: root.url,
                    includingPropertiesForKeys: Array(fileKeys),
                    options: [],
                    errorHandler: { _, _ in true }
                ) {
                    walkers.append((enumerator, false))
                }
            } else {
                consider(root.url, reportVisit: false)
            }
        }

        // Round-robin across unexpected roots.
        while fallbackDescendantEntries < Self.fallbackDescendantEntryLimit,
              walkers.contains(where: { !$0.exhausted }) {
            for index in walkers.indices
                where fallbackDescendantEntries < Self.fallbackDescendantEntryLimit {
                guard !walkers[index].exhausted else { continue }
                let enumerator = walkers[index].enumerator
                guard let url = enumerator.nextObject() as? URL else {
                    walkers[index].exhausted = true
                    continue
                }

                fallbackDescendantEntries += 1
                visitObserver?(url)
                let values = try? url.resourceValues(forKeys: fileKeys)
                let depth = url.standardizedFileURL.pathComponents.count - sessionsComponents
                if values?.isSymbolicLink == true || url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                    continue
                }
                if values?.isDirectory == true {
                    if depth >= Self.fallbackDepthLimit {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                consider(url, reportVisit: false)
            }
        }

        return candidates.map { (url: $0.key, modificationDate: $0.value) }
    }

    private static func inWindowDayDirectories(
        under sessionsURL: URL,
        cutoff: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> [URL] {
        var day = calendar.startOfDay(for: cutoff)
        let finalDay = calendar.startOfDay(for: now)
        var result: [URL] = []

        while day <= finalDay {
            let components = calendar.dateComponents([.year, .month, .day], from: day)
            if let year = components.year,
               let month = components.month,
               let dayNumber = components.day {
                result.append(
                    sessionsURL
                        .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                        .appendingPathComponent(String(format: "%02d", dayNumber), isDirectory: true)
                )
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day),
                  next > day else { break }
            day = next
        }
        return result
    }

    /// Direct date-leaf access must not follow a symlink out of the granted
    /// Codex root. Validate each existing path component from year through day.
    private static func isNonSymlinkDirectory(_ url: URL, beneath root: URL) -> Bool {
        let root = root.standardizedFileURL
        let target = url.standardizedFileURL
        guard target.pathComponents.starts(with: root.pathComponents) else { return false }

        var current = root
        for component in target.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component, isDirectory: true)
            guard let values = try? current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                return false
            }
        }
        return true
    }

    private static func isCanonicalYear(_ component: String) -> Bool {
        component.count == 4 && component.allSatisfy { $0.isNumber }
    }
}

enum CodexProcessProbe {
    private static let pathBufferSize = 4096
    private static let codexNameBytes: [CChar] = "codex".utf8.map { CChar(bitPattern: $0) }

    /// Working directories of the running `codex` processes.
    /// `complete` is false when any codex process refused the cwd query, because
    /// then an absent directory means "unknown", not "not running".
    static func codexWorkingDirectories() -> (directories: Set<String>, complete: Bool) {
        var result: Set<String> = []
        var complete = true
        for pid in codexPIDs() {
            guard let dir = workingDirectory(pid: pid) else {
                complete = false
                continue
            }
            // A process that chdir'd to "/" tells us nothing about which session it is.
            if dir == "/" { complete = false; continue }
            result.insert((dir as NSString).standardizingPath)
        }
        return (result, complete)
    }

    /// One 4 KB buffer for the whole process table: this walks ~1100 PIDs on
    /// every 1.5 s monitor tick. Ablated 2026-08-23 — reuse is worth ~0.1 ms of
    /// the 4.9 ms walk; the `URL` build in `hasCodexBasename` was the other 3.4.
    private static func codexPIDs() -> [Int32] {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        var result: [Int32] = []
        for pid in allPIDs() where isCodexExecutable(pid: pid, buffer: &buffer) {
            result.append(pid)
        }
        return result
    }

    /// `proc_listallpids` returns the number of PIDs written, not a byte count —
    /// measured 2026-08-09: 1131 returned against 1130 real PIDs. Dividing by the
    /// element stride, as this file used to, silently examined only a quarter of
    /// the process table.
    private static func allPIDs() -> [Int32] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        // Head-room so a process spawned between the two calls cannot truncate us.
        var pids = [Int32](repeating: 0, count: Int(capacity) + 64)
        let written = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<Int32>.stride))
        guard written > 0 else { return [] }
        return Array(pids.prefix(min(Int(written), pids.count))).filter { $0 > 0 }
    }

    /// `nil` when the sandbox or ownership refuses the query — indistinguishable
    /// from "no cwd", which is why the caller treats an empty set as "unknown".
    private static func workingDirectory(pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard rc == Int32(size) else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func isCodexRunning() -> Bool {
        var buffer = [CChar](repeating: 0, count: pathBufferSize)
        for pid in allPIDs() where isCodexExecutable(pid: pid, buffer: &buffer) {
            return true
        }
        return false
    }

    private static func isCodexExecutable(pid: Int32, buffer: inout [CChar]) -> Bool {
        let length = Int(buffer.withUnsafeMutableBytes { rawBuffer in
            proc_pidpath(pid, rawBuffer.baseAddress, UInt32(rawBuffer.count))
        })
        guard length > 0, length <= buffer.count else { return false }
        return hasCodexBasename(buffer, length: length)
    }

    /// Whether the last path component of `path[0..<length]` is exactly `codex`.
    /// Measured 2026-08-23 over 1079 PIDs: decoding a `String` and building a
    /// `URL` just to read `lastPathComponent` cost 5.2 ms per walk against
    /// 0.97 ms for this comparison. Bytes past `length` are stale from the
    /// previous PID and must never be read.
    static func hasCodexBasename(_ path: [CChar], length: Int) -> Bool {
        let name = codexNameBytes
        guard length >= name.count, length <= path.count else { return false }
        let start = length - name.count
        return path.withUnsafeBufferPointer { bytes -> Bool in
            for index in name.indices where bytes[start + index] != name[index] {
                return false
            }
            return start == 0 || bytes[start - 1] == CChar(UInt8(ascii: "/"))
        }
    }
}
