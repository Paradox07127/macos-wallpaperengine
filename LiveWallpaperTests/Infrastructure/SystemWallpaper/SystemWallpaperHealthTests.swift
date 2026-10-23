import Foundation
@testable import LiveWallpaper
import Testing

@Suite("System wallpaper health")
struct SystemWallpaperHealthTests {
    @Test("An incompatible system outranks every provider issue")
    func incompatibleWins() {
        let health = SystemWallpaperHealth.evaluate(status: .systemIncompatible, providerIssue: .unresponsive, activeDisplayCount: 2)
        #expect(health == .unavailable)
    }

    @Test("A stopped or silent provider reads as an unresponsive service, even with displays still listed")
    func stoppedProviderIsUnresponsive() {
        for issue in [WallpaperExportService.ProviderIssue.stopped, .unresponsive] {
            let health = SystemWallpaperHealth.evaluate(status: .inUse(itemTitle: "Forest"), providerIssue: issue, activeDisplayCount: 2)
            #expect(health == .serviceUnresponsive)
        }
    }

    @Test("Another app copy's provider is its own state, not a failure")
    func differentCopy() {
        let health = SystemWallpaperHealth.evaluate(status: .publishedNotSelected, providerIssue: .differentCopy, activeDisplayCount: 0)
        #expect(health == .otherCopyProvides)
    }

    @Test("Follow count comes from the displays macOS reports, not from the library")
    func followingCountsDisplays() {
        #expect(SystemWallpaperHealth.evaluate(status: .inUse(itemTitle: "Forest"), providerIssue: nil, activeDisplayCount: 2) == .following(displayCount: 2))
        #expect(SystemWallpaperHealth.evaluate(status: .publishedNotSelected, providerIssue: nil, activeDisplayCount: 0) == .notConfigured)
        #expect(SystemWallpaperHealth.evaluate(status: .empty, providerIssue: nil, activeDisplayCount: 0) == .notConfigured)
    }

    @Test("Only displays on the selected-wallpaper tile count as following")
    func followingCountExcludesLegacyChoices() {
        let selected = SystemWallpaperManifest.selectedChoiceID
        var beat = SystemWallpaperHeartbeat(timestamp: Date(), activeChoiceID: selected, activeChoiceIDs: [selected, "legacy"],
                                            activeDisplayIDs: [1, 2, 3], selectedTileDisplayIDs: [1, 3])
        #expect(beat.followingDisplayCount == 2)
        beat.selectedTileDisplayIDs = nil
        #expect(beat.followingDisplayCount == 1, "an unnamed display still shows the tile")
        beat.activeChoiceIDs = ["legacy"]
        beat.activeChoiceID = "legacy"
        #expect(beat.followingDisplayCount == 0)
    }

    @Test("Only copies without a follow source are legacy")
    func legacyCopiesHaveNoSourceKey() {
        let followed = SystemWallpaperManifest.Item(id: "a", title: "A", fileName: "a.mov", addedAt: Date(), sourceKey: "bookmark:a")
        let imported = SystemWallpaperManifest.Item(id: "b", title: "B", fileName: "b.mov", addedAt: Date(), sourceKey: nil)
        #expect(SystemWallpaperLegacyCopies.items(in: [followed, imported]).map(\.id) == ["b"])
    }

    @Test("Legacy size sums files and the contents of scene directories")
    func byteCountSumsDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = root.appendingPathComponent("s.scene", isDirectory: true)
        try FileManager.default.createDirectory(at: scene, withIntermediateDirectories: true)
        try Data(count: 300).write(to: scene.appendingPathComponent("scene.pkg"))
        try Data(count: 100).write(to: root.appendingPathComponent("v.mov"))
        try Data(count: 20).write(to: root.appendingPathComponent("v.jpg"))

        let total = SystemWallpaperLegacyCopies.byteCount(of: ["s.scene", "v.mov", "v.jpg", "missing.mov"], in: root)
        #expect(total == 420)
    }
}
