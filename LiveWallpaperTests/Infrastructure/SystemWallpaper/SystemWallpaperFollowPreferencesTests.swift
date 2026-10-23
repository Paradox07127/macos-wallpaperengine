import CoreGraphics
import Foundation
@testable import LiveWallpaper
import Testing

struct SystemWallpaperFollowPreferencesTests {
    @Test func defaultsMatchDisplayAndCapAtFourK() throws {
        let name = "SystemWallpaperFollowPreferencesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let options = SystemWallpaperFollowPreferences.options(defaults: defaults, displaySize: CGSize(width: 5120, height: 2880))
        #expect(options.sceneMode == .live)
        #expect(options.framesPerSecond == 30)
        #expect(options.duration == 15)
        #expect(options.size == CGSize(width: 3840, height: 2160))
        #expect(SystemWallpaperFollowPreferences.options(defaults: defaults, displaySize: CGSize(width: 2880, height: 1800)).size
            == CGSize(width: 2880, height: 1800))
    }

    @Test(arguments: SystemWallpaperFollowPreferences.ResolutionCap.allCases, [15, 30, 60])
    func preferencesProduceValidOptions(cap: SystemWallpaperFollowPreferences.ResolutionCap, value: Int) throws {
        let name = "SystemWallpaperFollowPreferencesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("videoCopy", forKey: SystemWallpaperFollowPreferences.sceneMode)
        defaults.set(cap.rawValue, forKey: SystemWallpaperFollowPreferences.resolutionCap)
        defaults.set(value, forKey: SystemWallpaperFollowPreferences.frameRate)
        defaults.set(value, forKey: SystemWallpaperFollowPreferences.loopLength)
        let options = SystemWallpaperFollowPreferences.options(defaults: defaults, displaySize: CGSize(width: 7680, height: 4320))
        #expect(options.sceneMode == .videoCopy)
        #expect(options.framesPerSecond == value)
        #expect(options.duration == Double(value))
        #expect(options.size == cap.size)
        #expect(options.isValid)
    }

    @Test func invalidPreferencesFallBackAndPortraitSizesStayEven() throws {
        let name = "SystemWallpaperFollowPreferencesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("unknown", forKey: SystemWallpaperFollowPreferences.sceneMode)
        defaults.set("unknown", forKey: SystemWallpaperFollowPreferences.resolutionCap)
        defaults.set(12, forKey: SystemWallpaperFollowPreferences.frameRate)
        defaults.set(-1, forKey: SystemWallpaperFollowPreferences.loopLength)
        let options = SystemWallpaperFollowPreferences.options(defaults: defaults, displaySize: CGSize(width: 2161, height: 3841))
        #expect(options.sceneMode == .live && options.framesPerSecond == 30 && options.duration == 15)
        #expect(options.size == CGSize(width: 1214, height: 2160))
        #expect(options.isValid)
        #expect(SystemWallpaperFollowPreferences.options(defaults: defaults, displaySize: .zero).isValid)
    }

    @Test(arguments: [
        (SystemWallpaperFollowPreferences.ResolutionCap.matchDisplay, CGSize(width: 2880, height: 1800), CGSize(width: 2560, height: 1440)),
        (.matchDisplay, CGSize(width: 1280, height: 800), CGSize(width: 1280, height: 720)),
        (.matchDisplay, CGSize(width: 1024, height: 640), CGSize(width: 1280, height: 720)),
        (.p1080, CGSize(width: 5120, height: 2880), CGSize(width: 1920, height: 1080)),
        (.p4K, CGSize(width: 5120, height: 2880), CGSize(width: 3840, height: 2160)),
    ])
    func copySheetStartsFromPreferences(cap: SystemWallpaperFollowPreferences.ResolutionCap, display: CGSize, expected: CGSize) throws {
        let name = "SystemWallpaperFollowPreferencesTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("videoCopy", forKey: SystemWallpaperFollowPreferences.sceneMode)
        defaults.set(cap.rawValue, forKey: SystemWallpaperFollowPreferences.resolutionCap)
        defaults.set(60, forKey: SystemWallpaperFollowPreferences.frameRate)
        defaults.set(30, forKey: SystemWallpaperFollowPreferences.loopLength)
        let options = SystemWallpaperFollowPreferences.copyOptions(defaults: defaults, displaySize: display)
        #expect(options.sceneMode == .videoCopy)
        #expect(options.framesPerSecond == 60)
        #expect(options.duration == 30)
        #expect(options.size == expected)
        #expect(SystemWallpaperFollowPreferences.copySizes.contains(options.size))
        #expect(options.isValid)
    }
}
