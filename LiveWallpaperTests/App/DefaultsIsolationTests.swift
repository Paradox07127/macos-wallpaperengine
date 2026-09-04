import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Writable defaults isolation", .serialized)
struct DefaultsIsolationTests {
    @Test("App-scoped writes never reach the standard test-host domain")
    func appScopedStoreIsIndependent() {
        let key = "LiveWallpaperTests.DefaultsIsolation.sentinel"
        let standard = UserDefaults.standard
        let scoped = UserDefaults.appScoped()
        let previous = standard.object(forKey: key)
        defer {
            scoped.removeObject(forKey: key)
            if let previous {
                standard.set(previous, forKey: key)
            } else {
                standard.removeObject(forKey: key)
            }
        }

        standard.set("standard", forKey: key)
        scoped.set("scoped", forKey: key)

        #expect(standard.string(forKey: key) == "standard")
        #expect(scoped.string(forKey: key) == "scoped")
    }

    @Test("High-risk preference writers use the isolation seam")
    func highRiskWriterSourceGuard() throws {
        let serviceFiles = [
            "LiveWallpaper/Monitor/SourceAuthorization.swift",
            "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift",
            "LiveWallpaper/Views/Workshop/BrowseViewModel.swift",
            "LiveWallpaper/Views/Workshop/BrowseFilterRibbon.swift"
        ]
        for relativePath in serviceFiles {
            let source = try RepositoryRoot.source(relativePath)
            #expect(!source.contains("UserDefaults.standard"), "\(relativePath) bypasses appScoped/injection")
        }

        let appStorageFiles = [
            "LiveWallpaper/Views/Settings/WorkshopBadgeSection.swift",
            "LiveWallpaper/Views/Workshop/BrowseCard.swift",
            "LiveWallpaper/Views/ScreenDetail/HistoryRow.swift",
            "LiveWallpaper/Views/Settings/WorkshopSettingsView.swift",
            // The Workshop settings page's `@AppStorage` moved into these two
            // when its setup rows became sections; the guard follows the code.
            "LiveWallpaper/Views/Settings/WorkshopConnectionSetup.swift",
            "LiveWallpaper/Views/Settings/WorkshopEngineAssetsSection.swift"
        ]
        for relativePath in appStorageFiles {
            let source = try RepositoryRoot.source(relativePath)
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@AppStorage") else { continue }
                #expect(trimmed.contains("store: .appScoped()"), "\(relativePath) has unscoped @AppStorage")
            }
        }
    }
}
