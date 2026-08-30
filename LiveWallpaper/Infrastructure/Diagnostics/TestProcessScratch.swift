import Foundation

/// Per-PID scratch names for test processes, plus the reaper that keeps them from piling up. A test process gets its own configuration root and defaults suite so a suite run can never write into the user's real container.
/// Nothing can delete them on the way out: cfprefsd writes a suite's plist *after* the owning process dies, so each new test process clears the ones whose owner is gone — 250 plists and 85 directories had accumulated in the container before this existed.
enum TestProcessScratch {
    static let configurationPrefix = "LiveWallpaperTests-Configuration-"
    static let defaultsPrefix = "LiveWallpaperTests-Defaults-"

    static var pid: Int32 { ProcessInfo.processInfo.processIdentifier }

    static func name(_ prefix: String) -> String { "\(prefix)\(pid)" }

    /// The sandboxed host's own preference directory — `NSHomeDirectory()` is the
    /// container's Data root, so suite plists land here.
    static var preferencesURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    /// Removes entries named `<prefix><pid>` whose owning process is gone. A recycled PID only ever means one stray survives to the next run; it can never delete a live sibling's scratch, which is the direction that matters when two test processes overlap.
    static func reapStale(
        prefix: String,
        in directory: URL,
        fileManager fm: FileManager = .default
    ) {
        guard let names = try? fm.contentsOfDirectory(
            atPath: directory.path(percentEncoded: false)
        ) else { return }
        for name in names where name.hasPrefix(prefix) {
            var suffix = String(name.dropFirst(prefix.count))
            if suffix.hasSuffix(".plist") { suffix.removeLast(6) }
            guard let owner = Int32(suffix), owner != pid, !isRunning(owner) else { continue }
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// `EPERM` means the PID exists but belongs to someone else — still alive.
    private static func isRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
