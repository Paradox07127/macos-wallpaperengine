import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Observation
import Testing

@MainActor
@Suite("Onboarding signals")
struct OnboardingSignalsTests {
    @Test("Home needs a non-nil identity different from the baseline")
    func home() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = WallpaperContent.html(source: .inline("original"), config: .default)
        fixture.stores.wallpapers = [1: original]
        let signals = fixture.signals()
        defer { withExtendedLifetime(signals) {} }
        fixture.center.post(name: .wallpaperConfigurationDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.wallpapers = [:]
        fixture.center.post(name: .wallpaperConfigurationDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.wallpapers = [1: original]
        fixture.center.post(name: .wallpaperConfigurationDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.wallpapers[2] = .html(source: .inline("new"), config: .default)
        fixture.center.post(name: .wallpaperConfigurationDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed == [.home])
        fixture.progress.reset()
        fixture.stores.wallpapers = [1: original]
        fixture.center.post(name: .wallpaperConfigurationDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
    }

    @Test("Unsupported apply and settings-only changes keep the active identity")
    func unchangedIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.stores.wallpapers = [1: .html(source: .inline("same"), config: .default)]
        let signals = fixture.signals()
        defer { withExtendedLifetime(signals) {} }
        var config = HTMLConfig.default
        config.allowMouseInteraction.toggle()
        fixture.stores.wallpapers[1] = .html(source: .inline("same"), config: config)
        fixture.center.post(name: .wallpaperConfigurationDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
    }

    @Test("Bookmarks use identities rather than count or metadata")
    func bookmarks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = WallpaperBookmark(label: "First", content: .html(source: .inline("first"), config: .default))
        fixture.stores.bookmarks = [first]
        let signals = fixture.signals()
        defer { withExtendedLifetime(signals) {} }
        fixture.stores.bookmarks[0].label = "Renamed"
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.bookmarks = []
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.bookmarks = [first]
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.bookmarks.append(WallpaperBookmark(label: "New", content: .html(source: .inline("new"), config: .default)))
        try await settle()
        #expect(fixture.progress.completed == [.library])
        fixture.progress.reset()
        signals.rebaseline()
        fixture.stores.bookmarks[0].label = "Renamed again"
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
    }

    #if !LITE_BUILD
    @Test("Capped history records a new identity even at equal count, but not a subset")
    func history() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.stores.historyIDs = ["old", "kept"]
        let signals = fixture.signals()
        defer { withExtendedLifetime(signals) {} }
        fixture.center.post(name: .wpeHistoryDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.historyIDs = ["kept"]
        fixture.center.post(name: .wpeHistoryDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.historyIDs = ["kept", "new"]
        fixture.center.post(name: .wpeHistoryDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed == [.library])
    }
    #endif

    @Test(
        "Workshop completes when downloading becomes confirmed or a local import adds wallpapers",
        .timeLimit(.minutes(1))
    )
    func workshopHooks() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signals = fixture.signals()
        defer { withExtendedLifetime(signals) {} }
        fixture.stores.username = "auto-selected"
        fixture.stores.onLocalLibraryImported?(0)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.downloadConfirmed = true
        try await settle()
        #expect(fixture.progress.completed == [.workshop])
        fixture.progress.reset()
        signals.rebaseline()
        // Still confirmed after the replayed tour's rebaseline, so this change is not a false → true edge.
        fixture.stores.username = "switched"
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
        fixture.stores.onLocalLibraryImported?(1)
        #expect(fixture.progress.completed == [.workshop])
    }

    @Test("Reset captures current wallpapers and library as the next baseline")
    func rebaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let signals = fixture.signals()
        defer { withExtendedLifetime(signals) {} }
        fixture.stores.wallpapers = [1: .html(source: .inline("existing"), config: .default)]
        fixture.stores.bookmarks = [WallpaperBookmark(label: "Existing", content: .html(source: .inline("existing"), config: .default))]
        fixture.progress.reset()
        signals.rebaseline()
        fixture.center.post(name: .wallpaperConfigurationDidChange, object: nil)
        try await settle()
        #expect(fixture.progress.completed.isEmpty)
    }

    @Test("The detail host can record overlay through the persisted-object hook")
    func overlayHook() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = OverlayEditorSession(defaults: fixture.defaults)
        session.onObjectPersisted = { fixture.progress.record(.overlay) }
        session.select(.clock)
        #expect(fixture.progress.completed.isEmpty)
        session.onObjectPersisted?()
        #expect(fixture.progress.completed == [.overlay])
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(20))
    }

    @MainActor
    private final class Fixture {
        let suite = "OnboardingSignalsTests.\(UUID())"
        let legacySuite = "OnboardingSignalsTests.legacy.\(UUID())"
        let defaults: UserDefaults
        let legacy: UserDefaults
        let progress: OnboardingProgress
        let stores = Stores()
        let center = NotificationCenter()

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            legacy = try #require(UserDefaults(suiteName: legacySuite))
            progress = OnboardingProgress(defaults: defaults, legacyDefaults: legacy, workshopAvailable: true)
        }

        func signals() -> OnboardingSignals {
            var inputs = OnboardingSignals.Inputs()
            inputs.wallpapers = { [stores] in stores.wallpapers }
            inputs.bookmarks = { [stores] in stores.bookmarks }
            inputs.historyIDs = { [stores] in stores.historyIDs }
            inputs.installWorkshopHooks = { [stores] imported in
                stores.onLocalLibraryImported = imported
            }
            // The doctor's confirmation implies a valid account, so it reads both, like the real one.
            inputs.workshopDownloadConfirmed = { [stores] in stores.username != nil && stores.downloadConfirmed }
            return OnboardingSignals(progress: progress, inputs: inputs, notificationCenter: center)
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            legacy.removePersistentDomain(forName: legacySuite)
        }
    }

    @MainActor @Observable
    fileprivate final class Stores {
        var wallpapers: [CGDirectDisplayID: WallpaperContent] = [:]
        var bookmarks: [WallpaperBookmark] = []
        var historyIDs: Set<String> = []
        var username: String?
        var downloadConfirmed = false
        var onLocalLibraryImported: (@MainActor (Int) -> Void)?
    }
}
