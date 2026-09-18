import Foundation

private enum CheckFailure: Error { case failed(String) }

private final class FakeRegistry: @unchecked Sendable { // Every read/write of state uses lock.
    private let lock = NSLock()
    private var removed = false
    private var invocations: [(String, [String])] = []
    let current: String
    let refusesRemoval: Bool
    /// pkill exits 1 when nothing matched: the agent had already died.
    let agentAbsent: Bool

    init(current: String, refusesRemoval: Bool = false, agentAbsent: Bool = false) {
        self.current = current
        self.refusesRemoval = refusesRemoval
        self.agentAbsent = agentAbsent
    }

    func run(_ executable: String, _ arguments: [String]) -> WallpaperMaintenanceEngine.Run {
        lock.lock()
        defer { lock.unlock() }
        invocations.append((executable, arguments))
        if executable == "/usr/bin/pkill" {
            return .init(code: agentAbsent ? 1 : 0, output: "")
        }
        if arguments == ["-dump"] {
            var output = "--------\npath: \(current) (0x123)\nidentifier: com.loomscreen.pro\n"
            if !removed {
                output += "--------\npath: /private/tmp/Old.app (0x124)\nidentifier: com.loomscreen.pro\n"
            }
            return .init(code: 0, output: output)
        }
        if arguments.first == "-u" {
            if refusesRemoval {
                return .init(code: 1, output: "")
            }
            removed = true
        }
        return .init(code: 0, output: "")
    }

    func calls() -> [(String, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

@main
private enum EngineChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = root.appendingPathComponent("Current.app")
        try FileManager.default.createDirectory(at: host.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.loomscreen.pro"], format: .xml, options: 0)
        try plist.write(to: host.appendingPathComponent("Contents/Info.plist"))
        var passed = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw CheckFailure.failed(name) }
            passed += 1
        }
        let registry = FakeRegistry(current: host.path)
        let engine = WallpaperMaintenanceEngine(hostPath: host.path, hostID: "com.loomscreen.pro", home: root.path,
                                                run: { registry.run($0, $1) })
        let report = try engine.inspect()
        try check(report.copies.filter(\.willUnregister).map(\.path) == ["/private/tmp/Old.app"], "inspect scopes removals")
        let changed = try engine.repair(revision: "stale")
        try check(changed.outcome == .changed, "stale review refused")
        try check(!registry.calls().contains { $0.1.first == "-u" }, "stale review makes no mutation")
        let repaired = try engine.repair(revision: report.revision)
        try check(repaired.outcome == .repaired && repaired.removedCount == 1, "cleanup succeeds")
        let calls = registry.calls()
        let registerIndex = calls.firstIndex { $0.1 == ["-f", host.path] }
        let killIndex = calls.firstIndex { $0.0 == "/usr/bin/pkill" }
        try check(registerIndex != nil && killIndex != nil && registerIndex! < killIndex!, "register retained host before restart")
        try check(calls[killIndex!].1 == ["-u", String(getuid()), "-x", "WallpaperAgent"], "restart restricted to current user and agent")
        let refused = FakeRegistry(current: host.path, refusesRemoval: true)
        let failing = WallpaperMaintenanceEngine(hostPath: host.path, hostID: "com.loomscreen.pro", home: root.path,
                                                 run: { refused.run($0, $1) })
        let before = try failing.inspect()
        let partial = try failing.repair(revision: before.revision)
        try check(partial.outcome == .failed, "partial cleanup is not success")
        try check(refused.calls().contains { $0.1 == ["-f", host.path] }, "retained host re-registered after failure")
        try check(!refused.calls().contains { $0.0 == "/usr/bin/pkill" }, "no restart after incomplete cleanup")
        let absent = FakeRegistry(current: host.path, agentAbsent: true)
        let stopped = WallpaperMaintenanceEngine(hostPath: host.path, hostID: "com.loomscreen.pro", home: root.path,
                                                 run: { absent.run($0, $1) })
        try check(stopped.restart().outcome == .restarted, "restart with no running agent is not a failure")
        let stoppedReview = try stopped.inspect()
        try check(stopped.repair(revision: stoppedReview.revision).outcome == .repaired,
                  "repair completes when the agent was already gone")
        let output = try WallpaperMaintenanceProcess.run("/usr/bin/printf", ["maintenance-probe"])
        try check(output.code == 0 && output.output == "maintenance-probe", "real process output captured")
        print("Wallpaper maintenance engine: \(passed) checks passed, 0 failed")
    }
}
