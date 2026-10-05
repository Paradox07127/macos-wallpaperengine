#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Modal display targets — a display shows only the exact copy and variant it runs")
struct ModalDisplayTargetTests {
    private static let workshopID = "2585024298"

    private let displays: [ModalActions.Display] = [
        .init(id: 1, name: "Left", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)),
        .init(id: 2, name: "Right", frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080)),
    ]

    private func entry(inFolder relativePath: String, under root: URL) throws -> WPEHistoryEntry {
        let folder = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try #require(ResourceUtilities.createBookmark(for: folder))
        let origin = WPEOrigin(
            workshopID: Self.workshopID, title: "Lunar Tear", originalType: .scene,
            sourceFolderBookmark: bookmark,
            cacheRelativePath: Self.workshopID, previewFileName: nil
        )
        return WPEHistoryEntry(origin: origin, importedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func running(
        _ origin: WPEOrigin, overrides: [String: WallpaperEngineProjectPropertyValue] = [:]
    ) -> ScreenConfiguration {
        let scene = SceneDescriptor(
            workshopID: Self.workshopID, cacheRelativePath: Self.workshopID, entryFile: "scene.json",
            capabilityTier: .imageOnly, propertyOverrides: overrides
        )
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(scene))
        configuration.wpeOrigin = origin
        return configuration
    }

    /// What display 1's button does in `entry`'s modal while display 1 runs `configuration`.
    private func press(for entry: WPEHistoryEntry, whileRunning configuration: ScreenConfiguration) -> ModalDisplayButtons.Press {
        let activeOn: Set<CGDirectDisplayID> = if SavedLibraryModel.isRunning(entry, in: configuration) {
            [1]
        } else {
            []
        }
        let target = ModalActions.targets(displays: displays, activeOn: activeOn, covers: [:])[0]
        return ModalDisplayButtons.press(for: target, canShow: true)
    }

    private func copies() throws -> (root: URL, local: WPEHistoryEntry, steam: WPEHistoryEntry) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("modal-targets-\(UUID().uuidString)", isDirectory: true)
        let local = try entry(inFolder: "Projects/Lunar Tear", under: root)
        let steam = try entry(inFolder: "steamapps/workshop/content/431960/3159206868", under: root)
        return (root, local, steam)
    }

    @Test("The Steam copy's button applies while the local copy of the same Workshop ID runs there")
    func anotherCopyUnderTheSameWorkshopIDIsNotApplied() throws {
        let (root, local, steam) = try copies()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(press(for: steam, whileRunning: running(local.origin)) == .apply, "the Steam copy's button opened the display running the local copy")
    }

    @Test("The copy running on a display opens that display")
    func theRunningCopyShowsItsDisplay() throws {
        let (root, local, _) = try copies()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(press(for: local, whileRunning: running(local.origin)) == .show)
    }

    @Test("The project's button applies while a variant tuning its scene runs there")
    func aRunningVariantDoesNotApplyItsProject() throws {
        let (root, local, _) = try copies()
        defer { try? FileManager.default.removeItem(at: root) }
        let variant = running(local.origin, overrides: ["speed": .number(2)])
        #expect(press(for: local, whileRunning: variant) == .apply, "the project's button opened the display running its variant")
    }
}
#endif
