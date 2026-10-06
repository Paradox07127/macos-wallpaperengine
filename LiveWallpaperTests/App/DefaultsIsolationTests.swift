import Foundation
@testable import LiveWallpaper
import SwiftUI
import Testing

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

    @Test("Explicit app-suite fallbacks remain in the isolated test domain")
    func appSuiteUsesTheIsolatedStore() {
        let key = "LiveWallpaperTests.DefaultsIsolation.appSuite"
        let scoped = UserDefaults.appScoped()
        let previous = scoped.object(forKey: key)
        let standard = UserDefaults.standard.object(forKey: key) as? String
        defer {
            if let previous {
                scoped.set(previous, forKey: key)
            } else {
                scoped.removeObject(forKey: key)
            }
        }

        scoped.set("scoped", forKey: key)
        #expect(UserDefaults.appSuite.string(forKey: key) == "scoped")
        UserDefaults.appSuite.set("suite", forKey: key)
        #expect(scoped.string(forKey: key) == "suite")
        #expect(UserDefaults.standard.string(forKey: key) == standard)
    }

    @MainActor
    @Test("AppStorage and the monitor reader share live isolated preferences")
    func appStorageAndMonitorReadTheSameStore() {
        let key = MonitorTemperature.fahrenheitDefaultsKey
        let scoped = UserDefaults.appScoped()
        let previous = scoped.object(forKey: key)
        let standard = UserDefaults.standard.object(forKey: key) as? Bool
        defer {
            if let previous {
                scoped.set(previous, forKey: key)
            } else {
                scoped.removeObject(forKey: key)
            }
        }

        let storage = AppStorage(wrappedValue: false, key, store: scoped)
        storage.wrappedValue = true
        #expect(MonitorTemperature.isFahrenheit)
        #expect(MonitorTemperature.symbol == "°F")
        storage.wrappedValue = false
        #expect(!MonitorTemperature.isFahrenheit)
        #expect(MonitorTemperature.symbol == "°C")
        #expect(UserDefaults.standard.object(forKey: key) as? Bool == standard)
    }

    @Test("High-risk preference writers use the isolation seam")
    func highRiskWriterSourceGuard() throws {
        let serviceFiles = [
            "LiveWallpaper/Monitor/SourceAuthorization.swift",
            "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift",
            "LiveWallpaper/Views/Workshop/BrowseViewModel.swift",
            "LiveWallpaper/Views/Workshop/BrowseFilterRibbon.swift",
        ]
        for relativePath in serviceFiles {
            let source = try RepositoryRoot.source(relativePath)
            #expect(!source.contains("UserDefaults.standard"), "\(relativePath) bypasses appScoped/injection")
        }

        let appStorageFiles = [
            "LiveWallpaper/Views/Settings/WorkshopBadgeSection.swift",
            "LiveWallpaper/Views/Workshop/BrowseCard.swift",
            "LiveWallpaper/Views/Settings/WorkshopSettingsView.swift",
            "LiveWallpaper/Views/Settings/WorkshopConnectionSetup.swift",
            "LiveWallpaper/Views/Settings/WorkshopEngineAssetsSection.swift",
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
