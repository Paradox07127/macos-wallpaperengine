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
