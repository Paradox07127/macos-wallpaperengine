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

    private static func fixedCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        return calendar
    }

    @Test("The first update check with no stored day carries the daily flag")
    func dailyFlagFirstCheck() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "SparkleDailyFlagTests")
        defer { scratch.discard() }
        let calendar = try Self.fixedCalendar()
        let now = Date(timeIntervalSince1970: 1_760_000_000)

        #expect(UpdateAvailabilityDelegate.consumeDailyFlag(defaults: scratch.defaults, now: now, calendar: calendar))
        #expect(
            scratch.defaults.object(forKey: UpdateAvailabilityDelegate.dailyFlagDayKey) as? Date
                == calendar.startOfDay(for: now)
        )
    }

    @Test("A second update check on the same day omits the daily flag")
    func dailyFlagSameDay() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "SparkleDailyFlagTests")
        defer { scratch.discard() }
        let calendar = try Self.fixedCalendar()
        let morning = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 0, minute: 5)))
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 23, minute: 55)))

        #expect(UpdateAvailabilityDelegate.consumeDailyFlag(defaults: scratch.defaults, now: morning, calendar: calendar))
        #expect(
            !UpdateAvailabilityDelegate.consumeDailyFlag(defaults: scratch.defaults, now: evening, calendar: calendar),
            "a second check on the same day counted the Mac twice"
        )
    }

    @Test("The first update check after local midnight carries the daily flag again")
    func dailyFlagAcrossMidnight() throws {
        let scratch = try TestScratch.defaultsSuite(prefix: "SparkleDailyFlagTests")
        defer { scratch.discard() }
        let calendar = try Self.fixedCalendar()
        let beforeMidnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 23, minute: 59)))
        let afterMidnight = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 0, minute: 1)))

        #expect(UpdateAvailabilityDelegate.consumeDailyFlag(defaults: scratch.defaults, now: beforeMidnight, calendar: calendar))
        #expect(
            UpdateAvailabilityDelegate.consumeDailyFlag(defaults: scratch.defaults, now: afterMidnight, calendar: calendar),
            "the first check of a new local day was not counted"
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
        let flag = CallbackFlag()
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

    @MainActor
    @Test("Skip This Version withdraws the found version; an older skip leaves a newer one standing")
    func skippingTheFoundVersionWithdrawsIt() throws {
        let updater = SparkleUpdaterController.shared
        defer { updater.noteNoUpdateFound() }
        let sparkle = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.SparkleUpdater")
        defer { sparkle.discard() }
        updater.noteUpdateFound(version: "0.6.2")

        sparkle.defaults.set("0.6.1", forKey: "SUSkippedVersion")
        updater.noteUpdateSessionFinished(defaults: sparkle.defaults)
        #expect(updater.availableVersion == "0.6.2", "a skip of an older version withdrew a newer update")

        sparkle.defaults.set("0.6.2", forKey: "SUSkippedVersion")
        updater.noteUpdateSessionFinished(defaults: sparkle.defaults)
        #expect(updater.availableVersion == nil, "the version the user skipped still shows as available")
    }
}
