import Foundation

/// Resolves the sandbox-aware configuration directory shared by typed stores and migrations.
struct ConfigurationDirectory {
    enum File: String {
        case screenConfigurations = "screen-configurations.json"
        case globalSettings = "global-settings.json"
        case wallpaperBookmarks = "wallpaper-bookmarks.json"
        case screenSchemes = "screen-schemes.json"
    }

    let root: URL

    /// Standard container-aware production location.
    init(fileManager: FileManager = .default) {
        // Unit tests are hosted inside the real app, so this default path is the user's live container. A full suite run wiped global-settings.json and planted garbage screen configs (screen 77, bookmark 0x0304) through SettingsManager.shared.
        // Under a test process, every default-constructed directory shares one throwaway per-process root instead.
        if NSClassFromString("XCTestCase") != nil {
            _ = Self.reapStaleTestRootsOnce
            self.root = fileManager.temporaryDirectory
                .appendingPathComponent(
                    TestProcessScratch.name(TestProcessScratch.configurationPrefix),
                    isDirectory: true
                )
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.loomscreen.pro"
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        self.root = appSupport
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Configuration", isDirectory: true)
    }

    /// Test/migration injection point.
    init(root: URL) {
        self.root = root
    }

    /// Lazy static, so the scan happens once per process rather than on every
    /// default-constructed directory.
    private static let reapStaleTestRootsOnce: Void = {
        TestProcessScratch.reapStale(
            prefix: TestProcessScratch.configurationPrefix,
            in: FileManager.default.temporaryDirectory
        )
    }()

    func url(for file: File) -> URL {
        root.appendingPathComponent(file.rawValue, isDirectory: false)
    }
}
