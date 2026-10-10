import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@Suite("MenuBar shortcut + recents behavior", .serialized)
@MainActor
struct MenuBarBehaviorTests {

    @Test("Menu-bar status distinguishes playback intent, system holds and restoration", arguments: [
        (WallpaperSessionActivity.active, MenuBarWallpaperStatus.playing),
        (.paused, .paused), (.policySuspended, .policySuspended),
        (.restoring, .restoring), (.off, .off), (.error, .error), (.inactive, .notConfigured),
    ])
    func menuBarStatus(activity: WallpaperSessionActivity, expected: MenuBarWallpaperStatus) {
        #expect(MenuBarWallpaperStatus.resolve(summaries: [Self.summary(activity)], globallyEnabled: true) == expected)
    }

    @Test("Mixed playback and a failure on another display remain visible in the menu bar")
    func mixedPlaybackAndFailureAreVisible() {
        #expect(MenuBarWallpaperStatus.resolve(summaries: [Self.summary(.active), Self.summary(.paused)], globallyEnabled: true) == .mixed)
        #expect(MenuBarWallpaperStatus.resolve(summaries: [Self.summary(.active), Self.summary(.error)], globallyEnabled: true) == .error)
        #expect(MenuBarWallpaperStatus.resolve(summaries: [Self.summary(.active)], globallyEnabled: true, hasFailedLoad: true) == .error)
        #expect(MenuBarWallpaperStatus.resolve(summaries: [], globallyEnabled: true, hasFailedLoad: true) == .error)
        #expect(MenuBarWallpaperStatus.resolve(summaries: [], globallyEnabled: true, hasPendingLoad: true) == .loading)
        #expect(MenuBarWallpaperStatus.resolve(summaries: [Self.summary(.active)], globallyEnabled: false) == .off)
        #expect(MenuBarWallpaperStatus.resolve(summaries: [], globallyEnabled: true) == .notConfigured)
        let web = WallpaperSessionSummary(wallpaperType: .html, activity: .active, supportsPlaybackControl: false, subtitle: nil)
        #expect(MenuBarWallpaperStatus.resolve(summaries: [web], globallyEnabled: true) == .visible)
    }

    private static func summary(_ activity: WallpaperSessionActivity) -> WallpaperSessionSummary {
        WallpaperSessionSummary(wallpaperType: .video, activity: activity, supportsPlaybackControl: true, subtitle: nil)
    }

    @Test("Status, metric and shortcut glyphs exist in the system symbol library")
    func symbolsExist() {
        let states: [MenuBarWallpaperStatus] = [.notConfigured, .playing, .visible, .mixed, .paused, .policySuspended, .restoring, .loading, .off, .error]
        let glyphs = states.map(\.symbol) + ["cpu", "square.3.layers.3d", "memorychip", "thermometer", "control", "option", "shift", "command", "space", "return"]
        for glyph in glyphs {
            #expect(NSImage(systemSymbolName: glyph, accessibilityDescription: nil) != nil, Comment(rawValue: glyph))
        }
    }

    @Test("Removing a known WPE import drops it from the recents list")
    func removingKnownImportDropsIt() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("alpha"))
            manager.recordWPEImport(makeEntry("beta"))

            manager.removeWPEImport(workshopID: "alpha")

            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["beta"])
        }
    }

    @Test("Removing an unknown WPE import is a no-op (no notification posted)")
    func removingUnknownImportIsNoOp() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("alpha"))

            let observer = NotificationObserver(name: .wpeHistoryDidChange)
            defer { observer.detach() }

            manager.removeWPEImport(workshopID: "ghost-id")

            #expect(observer.callCount == 0)
            let ids = manager.loadGlobalSettings().recentWPEImports.map(\.origin.workshopID)
            #expect(ids == ["alpha"])
        }
    }

    @Test("Removing every entry leaves the recents list empty")
    func removingAllEntriesEmptiesList() throws {
        withIsolatedGlobalSettings {
            let manager = SettingsManager.shared
            manager.recordWPEImport(makeEntry("one"))
            manager.recordWPEImport(makeEntry("two"))
            manager.removeWPEImport(workshopID: "one")
            manager.removeWPEImport(workshopID: "two")

            #expect(manager.loadGlobalSettings().recentWPEImports.isEmpty)
        }
    }

    @Test("Recording an import posts a wpeHistoryDidChange notification")
    func recordingImportPostsNotification() throws {
        withIsolatedGlobalSettings {
            let observer = NotificationObserver(name: .wpeHistoryDidChange)
            defer { observer.detach() }

            SettingsManager.shared.recordWPEImport(makeEntry("notify"))

            #expect(observer.callCount == 1)
        }
    }

    private func withIsolatedGlobalSettings(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "screenConfigurations",
            "globalSettings",
            "AerialsLibrary.DirectoryBookmark",
            "WallpaperBookmarks.v1",
            "TrustedHTMLHosts.v1",
        ]
        let previousValues = keys.reduce(into: [String: Any]()) { result, key in
            result[key] = defaults.object(forKey: key)
        }

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
        defer {
            SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)
            for key in keys {
                if let value = previousValues[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        try body()
    }

    private func makeEntry(
        _ workshopID: String,
        title: String? = nil,
        lastUsedAt: Date? = nil
    ) -> WPEHistoryEntry {
        let origin = WPEOrigin(
            workshopID: workshopID,
            title: title ?? "Wallpaper \(workshopID)",
            originalType: .video,
            sourceFolderBookmark: Data(workshopID.utf8),
            cacheRelativePath: "wpe-cache/\(workshopID)",
            previewFileName: "preview.gif"
        )
        return WPEHistoryEntry(
            origin: origin,
            importedAt: Date(timeIntervalSince1970: 0),
            lastUsedAt: lastUsedAt
        )
    }

}

private final class NotificationObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var token: NSObjectProtocol?

    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.bump()
        }
    }

    deinit {
        detach()
    }

    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _callCount
    }

    func detach() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    private func bump() {
        lock.lock(); defer { lock.unlock() }
        _callCount += 1
    }
}
