import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Sparkle update surfaces share one updater")
struct SparkleUpdaterOwnershipTests {
    @MainActor
    private final class StartupUpdater: SparkleUpdateStarting {
        var automaticallyChecksForUpdates: Bool
        var failsToStart = false
        var events: [String] = []

        init(automaticallyChecksForUpdates: Bool) {
            self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }

        func start() throws {
            events.append("start")
            if failsToStart {
                throw CocoaError(.fileReadUnknown)
            }
        }

        func checkForUpdatesInBackground() {
            events.append("check")
        }
    }

    @MainActor
    @Test("Launch checks immediately only when automatic checks are enabled", arguments: [true, false])
    func launchCheckRespectsAutomaticChecks(_ enabled: Bool) throws {
        let updater = StartupUpdater(automaticallyChecksForUpdates: enabled)
        var startup = SparkleUpdateStartup()

        try startup.start(updater: updater)

        #expect(startup.hasStarted)
        #expect(updater.events == (enabled ? ["start", "check"] : ["start"]))
        try startup.start(updater: updater)
        #expect(updater.events == (enabled ? ["start", "check"] : ["start"]))
    }

    @MainActor
    @Test("Launch reads the current automatic-check choice, including a migrated opt-out")
    func launchReadsTheCurrentPreference() throws {
        let updater = StartupUpdater(automaticallyChecksForUpdates: true)
        var startup = SparkleUpdateStartup()
        updater.automaticallyChecksForUpdates = false

        try startup.start(updater: updater)

        #expect(updater.events == ["start"])
    }

    @MainActor
    @Test("Failed startup cannot check and can be retried")
    func failedStartupDoesNotCheck() throws {
        let updater = StartupUpdater(automaticallyChecksForUpdates: true)
        updater.failsToStart = true
        var startup = SparkleUpdateStartup()

        #expect(throws: CocoaError.self) { try startup.start(updater: updater) }
        #expect(!startup.hasStarted)
        #expect(updater.events == ["start"])

        updater.failsToStart = false
        try startup.start(updater: updater)
        #expect(startup.hasStarted)
        #expect(updater.events == ["start", "start", "check"])
    }

    private static let surfaces = [
        "LiveWallpaper/Views/Settings/UpdateStatusLine.swift",
        "LiveWallpaper/Views/MenuBarContent.swift",
    ]

    @Test("No update surface constructs its own updater")
    func surfacesUseTheSharedUpdater() throws {
        for path in Self.surfaces {
            let source = try RepositoryRoot.source(path)
            #expect(source.contains("SparkleUpdaterController.shared"), "\(path) does not read the shared updater")
            #expect(
                !source.contains("SPUStandardUpdaterController("),
                "\(path) builds its own Sparkle controller"
            )
        }
    }

    @Test("The menu bar Update button only exists when an update is pending")
    func menuBarButtonIsGatedOnAvailability() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/MenuBarContent.swift")
        #expect(source.contains("if updater.availableVersion != nil"))
        #expect(source.contains("updater.checkForUpdates()"))
    }

    @Test("A scheduled check shows Sparkle's alert and lights the menu bar")
    func scheduledChecksShowSparkleAlert() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Infrastructure/Services/SparkleUpdaterController.swift")
        #expect(source.contains("supportsGentleScheduledUpdateReminders: Bool { true }"))
        #expect(source.contains("standardUserDriverShouldHandleShowingScheduledUpdate"))
        // The delegate method's body is a bare `true`.
        #expect(source.contains("    ) -> Bool {\n        true\n    }"))
        #expect(source.contains("onUpdateFound?(version)"))
    }

    @Test("Both SKUs ship the same EdDSA public key and their own feed", arguments: [
        ("LiveWallpaperInfo.plist", "appcast-pro.xml"),
        ("LoomscreenInfo.plist", "appcast-lite.xml"),
    ])
    func infoPlistsCarrySparkleKeys(_ plistName: String, _ expectedFeedFile: String) throws {
        let data = try RepositoryRoot.data(plistName)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        #expect(plist["SUPublicEDKey"] as? String == "V1TAiPupv91eQ9YlbHDBxPdztUhLrvG1TTJMYyArArs=")
        #expect(plist["SUEnableInstallerLauncherService"] as? Bool == true)
        // Pre-answers Sparkle's first-launch permission dialog; without it that
        // dialog appears over a running wallpaper.
        #expect(plist["SUEnableAutomaticChecks"] as? Bool == true)
        let feed = try #require(plist["SUFeedURL"] as? String)
        #expect(feed.hasPrefix("https://"), "the feed must not be fetched over cleartext")
        #expect(feed.hasSuffix(expectedFeedFile), "\(plistName) points at the wrong SKU's appcast")
        // Sparkle compares CFBundleVersion, not CFBundleShortVersionString. A
        // frozen "1" here means every release looks the same and nobody updates.
        #expect(
            plist["CFBundleVersion"] as? String == "$(MARKETING_VERSION)",
            "\(plistName) CFBundleVersion must track the marketing version"
        )
        #expect(plist["CFBundleShortVersionString"] as? String == "$(MARKETING_VERSION)")
    }

    @Test("A 0.5.7 opt-out carries over, once, and never beats a Sparkle-side choice", arguments: [
        // legacy value, Sparkle already stores a choice, what should be applied
        (false, false, false as Bool?),
        (true, false, true as Bool?),
        (false, true, nil as Bool?),
    ])
    func legacyOptOutMigration(_ legacy: Bool, _ sparkleStored: Bool, _ expected: Bool?) throws {
        // Parameterized: the case's arguments are part of the name, since all three
        // cases share one `#function` and Swift Testing may run them concurrently.
        let scratch = try TestScratch.defaultsSuite(
            "SparkleMigrationTests.legacyOptOut.\(legacy)-\(sparkleStored)"
        )
        let defaults = scratch.defaults
        defer { scratch.discard() }
        defaults.set(legacy, forKey: SparkleUpdaterController.legacyCheckAtLaunchKey)

        let carried = SparkleUpdaterController.legacyOptOutToCarryOver(
            defaults: defaults,
            sparkleChoiceIsStored: sparkleStored
        )

        #expect(carried == expected)
        #expect(defaults.object(forKey: SparkleUpdaterController.legacyCheckAtLaunchKey) == nil)
    }

    @Test("With no 0.5.7 key there is nothing to carry over")
    func migrationIsANoOpWithoutTheLegacyKey() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "SparkleMigrationTests")
        let defaults = scratch.defaults
        defer { scratch.discard() }

        #expect(
            SparkleUpdaterController.legacyOptOutToCarryOver(
                defaults: defaults,
                sparkleChoiceIsStored: false
            ) == nil
        )
    }

    @MainActor
    private final class CallbackFlag {
        var fired = false
    }

    /// Sparkle's own `assert` that this lands on the main thread is compiled out of
    /// release and the protocol does not promise it — assuming isolation would crash.
    @Test("The session-finished callback survives arriving off the main thread")
    func sessionFinishedFromBackgroundThreadDoesNotTrap() async throws {
        let delegate = await GentleReminderDelegate()
        let flag = await CallbackFlag()
        await MainActor.run {
            delegate.onSessionFinished = {
                MainActor.assertIsolated("the callback must land back on the main actor")
                flag.fired = true
            }
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(!Thread.isMainThread)
                delegate.standardUserDriverWillFinishUpdateSession()
                continuation.resume()
            }
        }

        try await Task.sleep(for: .milliseconds(200))
        #expect(await flag.fired)
    }

    @Test("Release packaging re-signs Sparkle helpers and allows a dirty appcast between SKUs")
    func releaseScriptWiresSparkleInstall() throws {
        let source = try RepositoryRoot.source("scripts/release-app.sh")
        #expect(source.contains("XPCServices/Installer.xpc"), "Installer.xpc would stay ad-hoc")
        #expect(source.contains("loomscreen-sparkle-ent"), "must reseal with extracted archive entitlements")
        #expect(source.contains("appcast-lite.xml"))
        #expect(source.contains("ACTUAL_BUNDLE_VERSION"))
    }
    /// Availability and session lifetime arrive through different delegates:
    /// "Remind Me Later" ends the session without withdrawing the update.
    @MainActor
    @Test("Dismissing the update alert leaves the found version standing")
    func remindMeLaterKeepsTheFoundVersion() {
        let updater = SparkleUpdaterController.shared
        defer { updater.noteNoUpdateFound() }

        updater.noteUpdateFound(version: "0.6.2")
        #expect(updater.availableVersion == "0.6.2")

        updater.noteUpdateSessionFinished()

        #expect(
            updater.availableVersion == "0.6.2",
            "dismissing the alert cleared the pending update, so every surface says the app is current"
        )
    }

    @MainActor
    @Test("A check that finds nothing clears the pending update")
    func aCheckWithNoUpdateClearsIt() {
        let updater = SparkleUpdaterController.shared
        updater.noteUpdateFound(version: "0.6.2")

        updater.noteNoUpdateFound()

        #expect(updater.availableVersion == nil)
    }
}
