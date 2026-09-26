import Foundation
@testable import LiveWallpaper
import Testing

@Suite("System wallpaper maintenance boundaries")
struct SystemWallpaperMaintenanceTests {
    @Test @MainActor func embeddedHelperAuthenticatesHostAndInspectsRegistrations() async throws {
        try #require(SystemWallpaperMaintenanceClient.isAvailable)
        let report = await SystemWallpaperMaintenanceClient.perform(.inspect)
        #expect(report.outcome == .inspected)
        #expect(report.errorCode == nil)
        #expect(report.currentAppPath == SystemWallpaperRegistrationPolicy.canonicalPath(Bundle.main.bundleURL.path))
        #expect(report.copies.allSatisfy { SystemWallpaperRegistrationPolicy.hostIDs.contains($0.bundleID) })
    }

    @Test func parsesOnlyExactHostIdentities() {
        let records = SystemWallpaperRegistrationPolicy.registrations(in: """
        --------
        path: /tmp/Pro.app (0x123)
        identifier: com.loomscreen.pro
        --------
        path: /tmp/Pro.app/Contents/Extensions/Provider.appex (0x124)
        identifier: com.loomscreen.pro.wallpaper
        --------
        path: /tmp/Evil.app (0x125)
        identifier: com.loomscreen.pro.evil
        --------
        path: /tmp/Lite.app (0x126)
        identifier: com.loomscreen
        """)
        #expect(records.map(\.path) == ["/tmp/Lite.app", "/tmp/Pro.app"])
    }

    @Test func rejectsRelativeAndTraversalPaths() {
        let records = SystemWallpaperRegistrationPolicy.registrations(in: """
        --------
        path: -f.app
        identifier: com.loomscreen.pro
        --------
        path: /tmp/../Applications/Other.app
        identifier: com.loomscreen.pro
        """)
        #expect(records.isEmpty)
    }

    @Test func registrationsSurviveADumpLargerThanThirtyTwoMebibytes() throws {
        let noise = String(repeating: "    claimed schemes:           x-noise:\n", count: 1 << 15)
        let dump = try Self.dumpFile { writer in
            try writer.write(contentsOf: Data(Self.record("/tmp/First/Pro.app", "com.loomscreen.pro").utf8))
            while try writer.offset() <= 33 * 1024 * 1024 {
                try writer.write(contentsOf: Data(noise.utf8))
            }
            try writer.write(contentsOf: Data(Self.record("/tmp/Last/Loomscreen.app", "com.loomscreen").utf8))
        }
        defer { try? FileManager.default.removeItem(at: dump) }

        let records = try Self.parse(dump)
        #expect(records == ["/tmp/First/Pro.app|com.loomscreen.pro", "/tmp/Last/Loomscreen.app|com.loomscreen"])
    }

    @Test func readingAnOrdinaryDumpParsesLikeTheRawText() throws {
        let raw = Self.record("/tmp/Pro.app", "com.loomscreen.pro")
            + "    path: /tmp/Indented.app\nidentifier-like: com.loomscreen\n"
            + Self.record("/tmp/Pro.app/Contents/Extensions/Provider.appex", "com.loomscreen.pro.wallpaper")
            + Self.record("/tmp/Lite.app", "com.loomscreen")
        let dump = try Self.dumpFile { try $0.write(contentsOf: Data(raw.utf8)) }
        defer { try? FileManager.default.removeItem(at: dump) }

        let expected = SystemWallpaperRegistrationPolicy.registrations(in: raw).map { $0.path + "|" + $0.bundleID }
        #expect(try Self.parse(dump) == expected)
        #expect(expected == ["/tmp/Lite.app|com.loomscreen", "/tmp/Pro.app|com.loomscreen.pro"])
    }

    private static func record(_ path: String, _ identifier: String) -> String {
        "--------------------------------------------------------------------------------\n"
            + "bundle id:                  Host (0x1)\npath:                       \(path) (0x2)\n"
            + "identifier:                 \(identifier)\n"
    }

    private static func dumpFile(_ fill: (FileHandle) throws -> Void) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try fill(writer)
        return url
    }

    private static func parse(_ dump: URL) throws -> [String] {
        let reader = try FileHandle(forReadingFrom: dump)
        defer { try? reader.close() }
        return try SystemWallpaperRegistrationPolicy.registrations(
            in: SystemWallpaperRegistrationPolicy.registrationText(from: reader)
        ).map { $0.path + "|" + $0.bundleID }
    }

    @Test func preservesCurrentAndSeparatelyInstalledEdition() {
        let current = "/Applications/Loomscreen Pro.app"
        func removes(_ path: String, _ id: String, exists: Bool = true) -> Bool {
            SystemWallpaperRegistrationPolicy.shouldUnregister(path: path, bundleID: id,
                                                               currentPath: current, currentID: "com.loomscreen.pro", exists: exists, home: "/Users/test")
        }
        #expect(!removes(current, "com.loomscreen.pro"))
        #expect(!removes("/Applications/Loomscreen.app", "com.loomscreen"))
        #expect(removes("/private/tmp/Build/Loomscreen.app", "com.loomscreen"))
        #expect(removes("/Users/test/Library/Developer/Xcode/DerivedData/Build/Pro.app", "com.loomscreen.pro"))
        #expect(!removes("/Applications/Other.app", "com.other"))
    }

    @Test func symlinkAliasCannotUnregisterRetainedHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("Host.app")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: host)
        #expect(!SystemWallpaperRegistrationPolicy.shouldUnregister(path: alias.path, bundleID: "com.loomscreen.pro",
                                                                    currentPath: host.path, currentID: "com.loomscreen.pro", exists: true, home: root.path))
    }

    /// A scratch-directory registration can be a symlink to an edition installed elsewhere,
    /// so the disposable-prefix rule has to judge the resolved path, not the dump's.
    @Test func disposableAliasOfAnInstalledEditionIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = root.appendingPathComponent("Applications/Loomscreen.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let derivedData = root.appendingPathComponent("Library/Developer/Xcode/DerivedData")
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        let alias = derivedData.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: installed)
        let real = derivedData.appendingPathComponent("Real.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let current = root.appendingPathComponent("Applications/Loomscreen Pro.app").path
        func removes(_ path: String) -> Bool {
            SystemWallpaperRegistrationPolicy.shouldUnregister(path: path, bundleID: "com.loomscreen",
                                                               currentPath: current, currentID: "com.loomscreen.pro", exists: true, home: root.path)
        }
        #expect(!removes(alias.path), "the alias resolves to an installed edition, which repair must keep")
        #expect(removes(real.path), "a real scratch build stays disposable")
    }

    @Test @MainActor func reconnectionRequiresAHealthyBeatFromTheNewProcess() {
        let began = Date(timeIntervalSince1970: 1000)
        func beat(pid: Int32, healthy: Bool) -> SystemWallpaperHeartbeat {
            SystemWallpaperHeartbeat(timestamp: began.addingTimeInterval(5), activeChoiceID: "a", runtimeHealthy: healthy,
                                     provider: SystemWallpaperProviderIdentity(build: "1", bundlePath: "/x", pid: pid))
        }
        func reconnected(_ heartbeat: SystemWallpaperHeartbeat, issue: WallpaperExportService.ProviderIssue? = nil,
                         running: Bool = true) -> Bool {
            SystemWallpaperMaintenanceController.isReconnected(heartbeat: heartbeat, began: began, previousPID: 41,
                                                               issue: issue, running: running)
        }
        #expect(reconnected(beat(pid: 42, healthy: true)))
        #expect(!reconnected(beat(pid: 42, healthy: false)), "a provider that refused its connection over the runtime layout is not verified")
        #expect(!reconnected(beat(pid: 41, healthy: true)), "the old process's beat")
        #expect(!reconnected(beat(pid: 42, healthy: true), issue: .unresponsive))
        #expect(!reconnected(beat(pid: 42, healthy: true), running: false))
    }

    @Test func automaticRecoveryRequiresPersistentFailureAndCooldown() {
        let start = Date(timeIntervalSince1970: 1000)
        var policy = SystemWallpaperRecoveryPolicy(now: start)
        let steps: [(Double, Bool)] = [(0, false), (60, false), (90, true), (120, false),
                                       (180, false), (240, false), (300, false), (360, false), (390, false), (420, true)]
        for (seconds, expected) in steps {
            let actual = policy.shouldRecover(isFailure: true, now: start.addingTimeInterval(seconds))
            #expect(actual == expected)
        }
    }

    @Test func recoveryResetsAfterHealthAndSleep() {
        let start = Date(timeIntervalSince1970: 1000)
        var policy = SystemWallpaperRecoveryPolicy(now: start)
        let steps: [(Double, Bool, Bool)] = [(60, true, false), (80, false, false), (100, true, false),
                                             (1000, true, false), (1060, true, false), (1090, true, true)]
        for (seconds, failure, expected) in steps {
            let actual = policy.shouldRecover(isFailure: failure, now: start.addingTimeInterval(seconds))
            #expect(actual == expected)
        }
    }
}
