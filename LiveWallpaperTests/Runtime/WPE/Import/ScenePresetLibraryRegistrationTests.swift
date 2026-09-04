import Foundation
import LiveWallpaperCore
import Testing
@testable import LiveWallpaper

/// Registration is the single write path into the preset library, and it runs
/// on both a first download and every re-download of the same Workshop item.
@MainActor
@Suite("Scene preset registration")
struct ScenePresetLibraryRegistrationTests {

    private func manager(function: String = #function) throws -> SettingsManager {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("preset-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try TestScratch.defaultsSuite(prefix: "preset-reg", function: function).defaults
        return SettingsManager(directory: ConfigurationDirectory(root: root), defaults: defaults)
    }

    private func workshopPreset(
        name: String,
        values: [String: WallpaperEngineProjectPropertyValue]
    ) -> ScenePreset {
        .workshop(
            workshopID: "3471679253",
            name: name,
            baseWorkshopID: "3470764447",
            values: values
        )
    }

    @Test("A re-download refreshes values but keeps the name the user gave it")
    func redownloadPreservesLocalRename() async throws {
        let sut = try manager()
        await sut.registerScenePreset(workshopPreset(name: "Steam Title", values: ["a": .number(1)]))
        sut.renameScenePreset(id: "3471679253", to: "My Night Look")

        // Same id, Steam's title back, different values — exactly a re-download.
        await sut.registerScenePreset(workshopPreset(name: "Steam Title", values: ["a": .number(2)]))

        let stored = try #require(sut.loadGlobalSettings().scenePresets["3471679253"])
        #expect(stored.name == "My Night Look")
        // Control: the refresh must still land, or this "fix" would just be
        // pinning presets to whatever was downloaded first.
        #expect(stored.values == ["a": .number(2)])
    }

    @Test("Control: without a rename the incoming title is adopted")
    func titleUpdatesWhenUserNeverRenamed() async throws {
        let sut = try manager()
        await sut.registerScenePreset(workshopPreset(name: "Old Title", values: ["a": .number(1)]))
        await sut.registerScenePreset(workshopPreset(name: "New Title", values: ["a": .number(1)]))

        #expect(sut.loadGlobalSettings().scenePresets["3471679253"]?.name == "New Title")
    }

    @Test("The descriptor hook runs after the library write and before observers")
    func thenPersistRunsBetweenWriteAndNotification() async throws {
        let sut = try manager()
        // Written on the main actor and read from the notification observer,
        // which this suite's `@MainActor` isolation posts on the same actor —
        // the ordering under test is exactly what makes the two never overlap.
        nonisolated(unsafe) var libraryVisibleInsideHook: ScenePreset?
        nonisolated(unsafe) var notifiedBeforeHook = false
        let observer = NotificationCenter.default.addObserver(
            forName: .scenePresetLibraryDidChange, object: nil, queue: nil
        ) { _ in
            if libraryVisibleInsideHook == nil { notifiedBeforeHook = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        await sut.registerScenePreset(workshopPreset(name: "T", values: ["a": .number(1)])) {
            // Ordering is the whole point: a caller that persists a descriptor
            // pointing at this preset needs it already in the library, and needs
            // to be done before anything reconciles.
            libraryVisibleInsideHook = sut.loadGlobalSettings().scenePresets["3471679253"]
        }

        #expect(libraryVisibleInsideHook != nil)
        #expect(notifiedBeforeHook == false)
    }
}
