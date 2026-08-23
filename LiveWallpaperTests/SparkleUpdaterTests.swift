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
    }
}
