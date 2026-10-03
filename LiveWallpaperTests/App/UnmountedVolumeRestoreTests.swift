import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Restoring a saved video whose bookmark cannot resolve")
struct UnmountedVolumeRestoreTests {
    private static let bookmark = Data("external-volume-video".utf8)

    private struct Outcome {
        let saved: ScreenConfiguration?
        let errors: [WallpaperRuntimeError]
        let releases: Int
    }

    private func restoreUnresolvable(volumeUnavailable: Bool) throws -> Outcome {
        let screen = try #require(NSScreen.screens.first.map(Screen.init(nsScreen:)))
        let store = WallpaperConfigurationStore(persistence: VolumeRestorePersistence())
        var configuration = ScreenConfiguration(screenID: screen.id, videoBookmarkData: Self.bookmark)
        configuration.displayFingerprint = screen.displayFingerprint
        store.save(configuration)
        var errors: [WallpaperRuntimeError] = []
        var releases = 0
        let coordinator = PlaybackCoordinator(
            configurationStore: store,
            configurationCommands: DisplayConfigurationTestSupport.commands(for: store),
            playableVideoLoader: FakePlayableVideoLoader(),
            bookmarkResolver: SecurityScopedBookmarkResolver(
                resolveData: { _ in throw CocoaError(.fileNoSuchFile) }, refreshData: { _ in Data() }
            ),
            applyPolicy: { _ in }, applyVideoEffects: { _, _ in },
            refreshRateLookup: { _ in 60 }, screensProvider: { [screen] },
            markSessionStateChanged: {}, releaseRuntimeSession: { _ in releases += 1 },
            notifyWallpaperSessionChanged: {},
            reportRuntimeError: { _, error in error.map { errors.append($0) } },
            originReconciler: PreservingOriginReconciler()
        )
        coordinator.applyConfiguration(
            configuration,
            to: screen,
            bookmarkVolumeIsUnavailable: { _ in volumeUnavailable }
        )
        return Outcome(saved: store.get(for: screen.id), errors: errors, releases: releases)
    }

    @Test("A saved video on an unmounted volume keeps its saved row so a later mount can restore it")
    func unmountedVolumeKeepsConfiguration() throws {
        let outcome = try restoreUnresolvable(volumeUnavailable: true)

        #expect(outcome.saved?.videoBookmarkData == Self.bookmark, "the saved wallpaper was deleted while its disk was unplugged")
        #expect(!outcome.errors.isEmpty)
        #expect(outcome.releases == 1)
    }

    @Test("An unresolvable bookmark on a reachable volume is still cleared")
    func reachableVolumeClearsConfiguration() throws {
        let outcome = try restoreUnresolvable(volumeUnavailable: false)

        #expect(outcome.saved == nil)
        #expect(!outcome.errors.isEmpty)
        #expect(outcome.releases == 1)
    }
}

@MainActor
private final class VolumeRestorePersistence: ScreenConfigurationPersisting {
    private var configurations: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations[screenID] = nil
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(configurations.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = Dictionary(uniqueKeysWithValues: configurations.map { ($0.screenID, $0) })
    }
}
