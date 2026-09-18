import CryptoKit
import Darwin
import Foundation

struct WallpaperMaintenanceEngine: Sendable {
    typealias Report = SystemWallpaperMaintenanceReport
    struct Run: Sendable { let code: Int32; let output: String }
    let hostPath: String
    let hostID: String
    let home: String
    var run: @Sendable (String, [String]) throws -> Run = WallpaperMaintenanceProcess.run
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    func inspect() throws -> Report {
        guard SystemWallpaperRegistrationPolicy.hostIDs.contains(hostID),
              Bundle(path: hostPath)?.bundleIdentifier == hostID else { throw Failure.refused }
        let dump = try run(Self.lsregister, ["-dump"])
        guard dump.code == 0 else { throw Failure.command }
        let records = SystemWallpaperRegistrationPolicy.registrations(in: dump.output)
        var report = Report(outcome: .inspected, currentAppPath: hostPath)
        report.copies = records.map { record in
            let exists = FileManager.default.fileExists(atPath: record.path)
            return Report.Copy(path: record.path, bundleID: record.bundleID, exists: exists,
                               isCurrent: SystemWallpaperRegistrationPolicy.canonicalPath(record.path) == hostPath,
                               willUnregister: SystemWallpaperRegistrationPolicy.shouldUnregister(
                                   path: record.path, bundleID: record.bundleID, currentPath: hostPath,
                                   currentID: hostID, exists: exists, home: home
                               ))
        }
        let snapshot = report.copies.filter(\.willUnregister).map { $0.bundleID + "\t" + $0.path }.joined(separator: "\n")
        report.revision = SHA256.hash(data: Data((hostPath + "\n" + snapshot).utf8)).map { String(format: "%02x", $0) }.joined()
        return report
    }

    func repair(revision: String) throws -> Report {
        let before = try inspect()
        guard !revision.isEmpty, before.revision == revision else {
            return Report(outcome: .changed, copies: before.copies, revision: before.revision, currentAppPath: hostPath)
        }
        let deadline = Date().addingTimeInterval(45)
        var removed = 0
        var failed = false
        for copy in before.copies where copy.willUnregister {
            guard Date() < deadline else { failed = true; break }
            // Recheck containment and identity immediately before the path-based mutation.
            let exists = FileManager.default.fileExists(atPath: copy.path)
            guard SystemWallpaperRegistrationPolicy.shouldUnregister(
                path: copy.path, bundleID: copy.bundleID, currentPath: hostPath,
                currentID: hostID, exists: exists, home: home
            ) else {
                failed = true
                continue
            }
            if exists, Bundle(path: copy.path)?.bundleIdentifier != copy.bundleID {
                failed = true
                continue
            }
            let result = try? run(Self.lsregister, ["-u", copy.path])
            if result?.code == 0 {
                removed += 1
            } else {
                failed = true
            }
        }
        // Removing candidates can expose an older record. Register the retained host last.
        guard try run(Self.lsregister, ["-f", hostPath]).code == 0 else { throw Failure.command }
        let after = try inspect()
        guard !failed, !after.copies.contains(where: \.willUnregister) else {
            return Report(outcome: .failed, copies: after.copies, revision: after.revision,
                          removedCount: removed, errorCode: "maintenance.cleanupIncomplete", currentAppPath: hostPath)
        }
        try restartAgent()
        return Report(outcome: .repaired, copies: after.copies, revision: after.revision,
                      removedCount: removed, currentAppPath: hostPath)
    }

    func restart() throws -> Report {
        try restartAgent()
        return Report(outcome: .restarted, currentAppPath: hostPath)
    }

    private func restartAgent() throws {
        // Fixed executable and argv; this cannot signal another user or an arbitrary process.
        let result = try run("/usr/bin/pkill", ["-u", String(getuid()), "-x", "WallpaperAgent"])
        // Exit 1 is "nothing matched": an agent that already died is what recovery is for.
        guard result.code == 0 || result.code == 1 else { throw Failure.command }
    }

    enum Failure: Error { case refused, command, timeout, outputTooLarge }
}

enum WallpaperMaintenanceProcess {
    static func run(_ executable: String, _ arguments: [String]) throws -> WallpaperMaintenanceEngine.Run {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw WallpaperMaintenanceEngine.Failure.command
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { @Sendable _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 10) == .success else {
            process.terminate()
            if done.wait(timeout: .now() + 1) != .success {
                kill(process.processIdentifier, SIGKILL)
            }
            throw WallpaperMaintenanceEngine.Failure.timeout
        }
        let reader = try FileHandle(forReadingFrom: outputURL)
        defer { try? reader.close() }
        let maximum = 32 * 1024 * 1024
        let data = try reader.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw WallpaperMaintenanceEngine.Failure.outputTooLarge }
        guard let text = String(bytes: data, encoding: .utf8) else { throw WallpaperMaintenanceEngine.Failure.command }
        return .init(code: process.terminationStatus, output: text)
    }
}
