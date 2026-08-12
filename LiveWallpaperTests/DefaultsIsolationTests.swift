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
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let serviceFiles = [
            "LiveWallpaper/Infrastructure/Services/UpdateChecker.swift",
            "LiveWallpaper/Monitor/MonitorSourceAuthorization.swift",
            "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift",
            "LiveWallpaper/Views/Workshop/WorkshopBrowseViewModel.swift",
            "LiveWallpaper/Views/Workshop/WorkshopBrowseFilterRibbon.swift"
        ]
        for relativePath in serviceFiles {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            #expect(!source.contains("UserDefaults.standard"), "\(relativePath) bypasses appScoped/injection")
        }

        let appStorageFiles = [
            "LiveWallpaper/Views/Settings/WorkshopBadgeSettingsSection.swift",
            "LiveWallpaper/Views/Workshop/WorkshopBrowseCard.swift",
            "LiveWallpaper/Views/ScreenDetail/WPEHistoryRow.swift",
            "LiveWallpaper/Views/Settings/WorkshopSettingsView.swift"
        ]
        for relativePath in appStorageFiles {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("@AppStorage") else { continue }
                #expect(trimmed.contains("store: .appScoped()"), "\(relativePath) has unscoped @AppStorage")
            }
        }
    }
}
