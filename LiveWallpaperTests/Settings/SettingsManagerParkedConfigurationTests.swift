import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Saving a parked configuration only touches the row with the same fingerprint", .serialized)
@MainActor
struct SettingsManagerParkedConfigurationTests {
    private func parked(_ fingerprint: String, byte: UInt8) -> ScreenConfiguration {
        var config = ScreenConfiguration(
            screenID: WallpaperConfigurationStore.parkedScreenID,
            wallpaper: .video(bookmarkData: Data([byte]))
        )
        config.displayFingerprint = fingerprint
        return config
    }

    @Test("Rewriting the second parked row leaves the first parked row untouched")
    func rewritingSecondParkedRowKeepsFirst() async throws {
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.Parked")
        defer { defaults.discard() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parked-\(UUID())")
        let directory = ConfigurationDirectory(root: root)
        let manager = SettingsManager(directory: directory, defaults: defaults.defaults)
        let first = parked("panel-A", byte: 1)
        var second = parked("panel-B", byte: 2)
        manager.replaceAllConfigurations([first, second])

        second.playbackSpeed = 1.75
        manager.saveConfiguration(second)

        #expect(manager.loadConfigurations() == [first, second])
        await manager.waitForPendingWrites()
        #expect(AtomicFileStore<[ScreenConfiguration]>(fileURL: directory.url(for: .screenConfigurations)).read() == [first, second])
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("Saving a parked row whose fingerprint is not stored appends instead of overwriting")
    func parkedRowWithNewFingerprintAppends() async throws {
        let defaults = try TestScratch.defaultsSuite(prefix: "LiveWallpaperTests.Parked")
        defer { defaults.discard() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parked-\(UUID())")
        let directory = ConfigurationDirectory(root: root)
        let manager = SettingsManager(directory: directory, defaults: defaults.defaults)
        let existing = parked("panel-A", byte: 1)
        manager.replaceAllConfigurations([existing])

        let incoming = parked("panel-B", byte: 2)
        manager.saveConfiguration(incoming)

        #expect(manager.loadConfigurations() == [existing, incoming])
        await TestScratch.discard(root, flushing: manager)
    }
}
