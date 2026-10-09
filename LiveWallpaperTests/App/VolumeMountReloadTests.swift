import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("Volume mount reload selection")
struct VolumeMountReloadTests {
    private static let externalBookmark = Data("external-volume-video".utf8)

    private static func needsReload(
        _ wallpaper: WallpaperContent,
        hasHealthySession: Bool = false,
        volumeUnavailable: Bool = false
    ) -> Bool {
        ScreenManager.needsReloadAfterVolumeMount(
            configuration: ScreenConfiguration(screenID: 1, wallpaper: wallpaper),
            hasHealthySession: hasHealthySession,
            volumeIsUnavailable: { _ in volumeUnavailable }
        )
    }

    @Test("A video on a now-mounted volume with no running session is reloaded")
    func videoWithoutSessionIsSelected() {
        #expect(Self.needsReload(.video(bookmarkData: Self.externalBookmark)))
    }

    @Test("A local HTML file or folder on a now-mounted volume with no running session is reloaded")
    func localHTMLWithoutSessionIsSelected() {
        #expect(Self.needsReload(.html(source: .file(bookmarkData: Self.externalBookmark), config: .default)))
        #expect(Self.needsReload(.html(source: .folder(bookmarkData: Self.externalBookmark, indexFileName: "index.html"), config: .default)))
    }

    @Test("A video whose volume is still unreachable is not reloaded")
    func unreachableVolumeIsSkipped() {
        #expect(!Self.needsReload(.video(bookmarkData: Self.externalBookmark), volumeUnavailable: true))
    }

    @Test("A screen already running a healthy session is not reloaded")
    func healthySessionIsSkipped() {
        #expect(!Self.needsReload(.video(bookmarkData: Self.externalBookmark), hasHealthySession: true))
    }

    @Test("Scene, inline and remote HTML configurations never depend on a mount")
    func nonBookmarkWallpapersAreSkipped() throws {
        let scene = SceneDescriptor(workshopID: "1", cacheRelativePath: "1", entryFile: "scene.json", capabilityTier: .imageOnly)
        let remote = try #require(URL(string: "https://example.com"))
        #expect(!Self.needsReload(.scene(scene)))
        #expect(!Self.needsReload(.html(source: .inline("<p>"), config: .default)))
        #expect(!Self.needsReload(.html(source: .url(remote), config: .default)))
    }

    #if !LITE_BUILD
    @Test("A scene read in place from a now-mounted Workshop source with no running session is reloaded")
    func sceneWithOriginIsSelected() {
        let scene = SceneDescriptor(workshopID: "1", cacheRelativePath: "1", entryFile: "scene.json", capabilityTier: .imageOnly)
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(scene))
        configuration.wpeOrigin = WPEOrigin(
            workshopID: "1", title: "Scene", originalType: .scene, sourceFolderBookmark: Self.externalBookmark,
            cacheRelativePath: "1", previewFileName: nil
        )
        var checked: Data?
        #expect(ScreenManager.needsReloadAfterVolumeMount(
            configuration: configuration,
            hasHealthySession: false,
            volumeIsUnavailable: { checked = $0; return false }
        ))
        #expect(checked == Self.externalBookmark)
    }
    #endif

    @Test("A screen with no configuration is not reloaded")
    func missingConfigurationIsSkipped() {
        #expect(!ScreenManager.needsReloadAfterVolumeMount(
            configuration: nil,
            hasHealthySession: false,
            volumeIsUnavailable: { _ in false }
        ))
    }
}
