import Foundation

@objc protocol SystemWallpaperMaintenanceProtocol {
    func inspect(with reply: @escaping @Sendable (Data) -> Void)
    func restart(with reply: @escaping @Sendable (Data) -> Void)
    func repair(revision: String, with reply: @escaping @Sendable (Data) -> Void)
}

struct SystemWallpaperMaintenanceReport: Codable, Sendable, Equatable {
    struct Copy: Codable, Sendable, Equatable, Identifiable {
        var id: String {
            path
        }

        let path: String
        let bundleID: String
        let exists: Bool
        let isCurrent: Bool
        let willUnregister: Bool
    }

    enum Outcome: String, Codable, Sendable {
        case inspected, restarted, repaired, changed, unavailable, refused, timedOut, failed
    }

    let outcome: Outcome
    var copies: [Copy] = []
    var revision = ""
    var removedCount = 0
    var errorCode: String?
    var currentAppPath: String?
}

/// Parses only the two host identities. Extension and unrelated application records are excluded.
enum SystemWallpaperRegistrationPolicy {
    static let hostIDs: Set<String> = ["com.loomscreen", "com.loomscreen.pro"]

    static func registrations(in dump: String) -> [(path: String, bundleID: String)] {
        var path: String?
        var identifier: String?
        var result: [String: String] = [:]
        func commit() {
            if let path, let identifier, hostIDs.contains(identifier),
               path.hasPrefix("/"), path.hasSuffix(".app"),
               !path.contains("\n"), !path.contains("\r"),
               !path.split(separator: "/").contains("..") {
                result[path] = identifier
            }
        }
        for line in dump.components(separatedBy: .newlines) {
            if line.hasPrefix("--------") {
                commit()
                path = nil
                identifier = nil
            } else if line.hasPrefix("path:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if let suffix = value.range(of: " (0x", options: .backwards) {
                    path = String(value[..<suffix.lowerBound])
                } else {
                    path = value
                }
            } else if line.hasPrefix("identifier:") {
                identifier = String(line.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            }
        }
        commit()
        return result.map { (path: $0.key, bundleID: $0.value) }.sorted { $0.path < $1.path }
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func shouldUnregister(path: String, bundleID: String, currentPath: String,
                                 currentID: String, exists: Bool, home: String) -> Bool {
        guard hostIDs.contains(bundleID), canonicalPath(path) != canonicalPath(currentPath) else { return false }
        if bundleID == currentID || !exists {
            return true
        }
        // Preserve a separately installed edition; only its disposable build registrations qualify.
        return path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/")
            || path.hasPrefix(home + "/Library/Developer/Xcode/DerivedData/")
    }
}

struct SystemWallpaperRecoveryPolicy {
    private var firstFailure: Date?
    private var lastEvaluation: Date?
    private var readyAt: Date
    private(set) var lastAttempt: Date

    init(now: Date, lastAttempt: Date = .distantPast) {
        readyAt = now.addingTimeInterval(60)
        self.lastAttempt = lastAttempt
    }

    mutating func shouldRecover(isFailure: Bool, now: Date) -> Bool {
        if let lastEvaluation, now.timeIntervalSince(lastEvaluation) > 90 {
            readyAt = now.addingTimeInterval(60)
            firstFailure = nil
        }
        lastEvaluation = now
        guard isFailure, now >= readyAt, now.timeIntervalSince(lastAttempt) >= 300 else {
            firstFailure = nil
            return false
        }
        guard let firstFailure else { firstFailure = now; return false }
        guard now.timeIntervalSince(firstFailure) >= 30 else { return false }
        self.firstFailure = nil
        lastAttempt = now
        return true
    }
}
