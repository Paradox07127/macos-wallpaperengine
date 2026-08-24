import Foundation
import Testing
@testable import LiveWallpaper

/// Replaces the retired `UpdateSurfaceOwnershipTests`. Every update surface has
/// to read the one shared updater, or two of them could disagree about whether
/// an update is pending.
@Suite("Sparkle update surfaces share one updater")
struct SparkleUpdaterOwnershipTests {
    private static let surfaces = [
        "LiveWallpaper/Views/Settings/UpdateBannerView.swift",
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

    /// The button is the only thing that tells the user an update exists, so it
    /// has to be gated on one actually being available.
    @Test("The menu bar Update button only exists when an update is pending")
    func menuBarButtonIsGatedOnAvailability() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Views/MenuBarContent.swift")
        #expect(source.contains("if updater.availableVersion != nil"))
        #expect(source.contains("updater.checkForUpdates()"))
    }

    /// The whole point of wiring Sparkle through a gentle-reminder delegate: a
    /// scheduled check must never throw a dialog over a running wallpaper. If
    /// this regresses, updates start interrupting the user again.
    @Test("Scheduled checks stay silent and only light up the menu bar")
    func scheduledChecksDoNotShowDialogs() throws {
        let source = try RepositoryRoot.source("LiveWallpaper/Infrastructure/Services/SparkleUpdaterController.swift")
        #expect(source.contains("supportsGentleScheduledUpdateReminders: Bool { true }"))
        #expect(source.contains("standardUserDriverShouldHandleShowingScheduledUpdate"))
        // The delegate method's body is a bare `false`.
        #expect(source.contains("    ) -> Bool {\n        false\n    }"))
    }

    /// Sparkle refuses an update whose signature does not verify against this
    /// key, so a missing or drifted key silently disables update delivery.
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

    /// A failed check (no network, 404, bad signature) ends the session, so this
    /// callback is on the failure path. Sparkle 2.9.6 delivers it on the main
    /// thread, but its own `assert` for that is compiled out of release and the
    /// protocol header does not promise it — assuming isolation would turn a
    /// future version bump into a crash on every failed update check.
    @MainActor
    private final class CallbackFlag {
        var fired = false
    }

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
}
