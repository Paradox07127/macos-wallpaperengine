import Testing
import Foundation
import CoreGraphics
import LiveWallpaperCore
import SwiftUI
@testable import LiveWallpaper

@Suite("ResourceUtilities") @MainActor
struct ResourceUtilitiesTests {

    @Test("Bookmark creation options match read-only sandbox entitlement")
    func bookmarkCreationOptionsAreReadOnlyScoped() {
        let options = ResourceUtilities.bookmarkCreationOptions

        #expect(options.contains(.withSecurityScope))
        #expect(options.contains(.securityScopeAllowOnlyReadAccess))
    }

    @Test("Sandbox entitlements allow read-write user-selected files")
    func sandboxEntitlementsAllowReadWriteUserSelectedFiles() throws {
        let data = try RepositoryRoot.data("LiveWallpaper/LiveWallpaper.entitlements")
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["com.apple.security.files.bookmarks.app-scope"] as? Bool == true)
        #expect(plist["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(plist["com.apple.security.files.user-selected.read-only"] == nil)
    }

    @Test("Supported video URL detection accepts video files and rejects unrelated drops")
    func supportedVideoURLDetectionRejectsUnrelatedFiles() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let mp4URL = folder.appendingPathComponent("clip.mp4")
        let textURL = folder.appendingPathComponent("notes.txt")
        try Data([0x00]).write(to: mp4URL)
        try Data("not a video".utf8).write(to: textURL)

        #expect(ResourceUtilities.isSupportedVideoURL(mp4URL))
        #expect(!ResourceUtilities.isSupportedVideoURL(textURL))
    }

    @Test("HTML resource detection accepts HTML files and folders only")
    func htmlResourceDetectionAcceptsHTMLFilesAndFoldersOnly() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let htmlURL = folder.appendingPathComponent("index.html")
        let textURL = folder.appendingPathComponent("notes.txt")
        try Data("<!doctype html>".utf8).write(to: htmlURL)
        try Data("not html".utf8).write(to: textURL)

        #expect(ResourceUtilities.isSupportedHTMLResourceURL(folder))
        #expect(ResourceUtilities.isSupportedHTMLResourceURL(htmlURL))
        #expect(!ResourceUtilities.isSupportedHTMLResourceURL(textURL))
    }

    @Test("Picked HTML file stays a file source instead of switching UI to folder mode")
    func pickedHTMLFileStaysFileSource() throws {
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: folder) }
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let htmlURL = folder.appendingPathComponent("index.html")
        try Data("<!doctype html><title>QA</title>".utf8).write(to: htmlURL)

        let source = try #require(ResourceUtilities.htmlSourceFromPickedFile(htmlURL))

        guard case .file = source else {
            Issue.record("Picked HTML file should remain a file source; got \(source)")
            return
        }
    }

    @Test("Video bookmark creation falls back to an app-owned copy when scoped bookmark creation fails")
    func videoBookmarkCreationFallsBackToAppOwnedCopy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let appSupportRoot = root.appendingPathComponent("ApplicationSupport/LiveWallpaper", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("bg.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: sourceURL)

        let bookmark = ResourceUtilities.createVideoBookmark(
            for: sourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )

        let importedRoot = appSupportRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let importedDirectories = try fileManager.contentsOfDirectory(
            at: importedRoot,
            includingPropertiesForKeys: nil
        )
        let hashDirectoryName = try #require(importedDirectories.first?.lastPathComponent)
        let reconstructedCopiedURL = importedRoot
            .appendingPathComponent(hashDirectoryName, isDirectory: true)
            .appendingPathComponent("bg.mp4", isDirectory: false)

        #expect(bookmark == Data(reconstructedCopiedURL.path(percentEncoded: false).utf8))
        #expect(fileManager.fileExists(atPath: reconstructedCopiedURL.path(percentEncoded: false)))
        #expect(try Data(contentsOf: reconstructedCopiedURL) == Data([0x00, 0x01, 0x02]))
    }

    @Test("Video fallback reuses the app-owned copy for the same source")
    func videoBookmarkCreationReusesAppOwnedCopyForSameSource() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let appSupportRoot = root.appendingPathComponent("ApplicationSupport/LiveWallpaper", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("bg.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: sourceURL)

        let firstBookmark = ResourceUtilities.createVideoBookmark(
            for: sourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )
        let secondBookmark = ResourceUtilities.createVideoBookmark(
            for: sourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )

        let importedRoot = appSupportRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let importedDirectories = try fileManager.contentsOfDirectory(
            at: importedRoot,
            includingPropertiesForKeys: nil
        )

        #expect(firstBookmark == secondBookmark)
        #expect(importedDirectories.count == 1)
        #expect(fileManager.fileExists(
            atPath: importedDirectories[0].appendingPathComponent("bg.mp4").path(percentEncoded: false)
        ))
    }

    @Test("Video fallback fingerprint tracks source file attributes")
    func videoBookmarkFallbackFingerprintTracksSourceAttributes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("source", isDirectory: true)
        let appSupportRoot = root.appendingPathComponent("ApplicationSupport/LiveWallpaper", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let sourceURL = sourceDirectory.appendingPathComponent("bg.mp4")
        try Data([0x00, 0x01, 0x02]).write(to: sourceURL)

        _ = ResourceUtilities.createVideoBookmark(
            for: sourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )

        try Data([0x00, 0x01, 0x02, 0x03]).write(to: sourceURL)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: sourceURL.path(percentEncoded: false)
        )

        // Fresh URL instance: NSURL caches resourceValues per instance, so reusing `sourceURL`
        // would hand the fingerprint the pre-rewrite size/mtime and mask the regression.
        let rewrittenSourceURL = URL(fileURLWithPath: sourceURL.path(percentEncoded: false))

        _ = ResourceUtilities.createVideoBookmark(
            for: rewrittenSourceURL,
            applicationSupportRootURL: appSupportRoot,
            secureBookmarkCreator: { _ in nil },
            localBookmarkCreator: { Data($0.path(percentEncoded: false).utf8) }
        )

        let importedRoot = appSupportRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let importedDirectories = try fileManager.contentsOfDirectory(
            at: importedRoot,
            includingPropertiesForKeys: nil
        )
        #expect(importedDirectories.count == 2)
    }

    @Test("HTML folder index inference prefers standard names")
    func htmlFolderIndexInferencePrefersStandardNames() {
        let entries = ["about.html", "index.htm", "index.html"]

        let index = ResourceUtilities.inferHTMLIndexFileName(from: entries)

        #expect(index == "index.html")
    }

    @Test("HTML folder index inference falls back to first HTML file")
    func htmlFolderIndexInferenceFallsBackToFirstHTMLFile() {
        let entries = ["style.css", "landing.HTML", "script.js"]

        let index = ResourceUtilities.inferHTMLIndexFileName(from: entries)

        #expect(index == "landing.HTML")
    }

    @Test("HTML folder index inference preserves actual file name casing")
    func htmlFolderIndexInferencePreservesActualFileNameCasing() {
        let entries = ["Index.HTML", "about.html"]

        let index = ResourceUtilities.inferHTMLIndexFileName(from: entries)

        #expect(index == "Index.HTML")
    }
}

@Suite("SettingsManager") @MainActor
struct SettingsManagerTests {
    private let bookmarksKey = "WallpaperBookmarks.v1"
    private let trustedHostsKey = "TrustedHTMLHosts.v1"

    @Test("Default configuration directory is isolated from the user's real container under tests")
    func defaultConfigurationDirectoryIsIsolatedUnderTests() {
        let root = ConfigurationDirectory().root
        #expect(root.path.contains("LiveWallpaperTests-Configuration-"))
        #expect(!root.path.hasSuffix("com.loomscreen.pro/Configuration"))
    }

    @Test("The shared manager never writes to the real defaults domain under tests")
    func sharedManagerIsIsolatedFromStandardDefaults() {
        let standard = UserDefaults.standard
        let key = "WPELibrary.RootBookmark.v1"
        let previous = standard.object(forKey: key)
        defer {
            if let previous { standard.set(previous, forKey: key) } else { standard.removeObject(forKey: key) }
        }
        standard.set(Data([0xBE, 0xEF]), forKey: key)

        SettingsManager.shared.cleanAllSettings(applyLoginSetting: false)

        #expect(standard.data(forKey: key) == Data([0xBE, 0xEF]))
    }

    @Test("Clean all settings clears trusted hosts and saved bookmarks")
    func cleanAllSettingsClearsTrustAndBookmarks() async throws {
        // Must be a fully isolated manager: running this wipe against `SettingsManager.shared`
        // would delete the user's real defaults keys (engine-assets and aerials bookmarks).
        let scratch = try TestScratch.defaultsSuite("LiveWallpaperTests.cleanAllSettings")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanAllSettings-\(UUID().uuidString)", isDirectory: true)

        defaults.set(["trusted.example"], forKey: trustedHostsKey)
        defaults.set(Data([0x01, 0x02]), forKey: bookmarksKey)

        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: root),
            defaults: defaults
        )
        manager.cleanAllSettings(applyLoginSetting: false)

        #expect(defaults.object(forKey: trustedHostsKey) == nil)
        #expect(defaults.object(forKey: bookmarksKey) == nil)
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("Clean all settings clears auxiliary component keys")
    func cleanAllSettingsClearsAuxiliaryKeys() async throws {
        let scratch = try TestScratch.defaultsSuite("LiveWallpaperTests.cleanAllSettingsAux")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleanAllSettingsAux-\(UUID().uuidString)", isDirectory: true)

        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: root),
            defaults: defaults
        )

        // Preset after init so the migration/schema stamps written by init are covered too.
        let auxiliaryKeys = [
            "WPEEngineAssets.ManagedBuildID.v1",
            "WPELibrary.RootBookmark.v1",
            "loomscreen.sidebar.displayOrder.v1",
            "monitor.source.claude.bookmark",
            "monitor.source.codex.bookmark",
            "loomscreen.library.bookmarks.v1",
            "loomscreen.library.bookmarks.migrated.v1",
            "loomscreen.savedLibrary.selectedTab.v1",
        ]
        for key in auxiliaryKeys {
            defaults.set(Data([0x01]), forKey: key)
        }
        defaults.set(true, forKey: "SUSendProfileInfo")
        #expect(defaults.object(forKey: "Settings.MigrationVersion") != nil)
        #expect(defaults.object(forKey: "Settings.BlobSchemaVersion") != nil)

        manager.cleanAllSettings(applyLoginSetting: false)

        for key in auxiliaryKeys + ["SUSendProfileInfo", "Settings.MigrationVersion", "Settings.BlobSchemaVersion"] {
            #expect(defaults.object(forKey: key) == nil, "\(key) must be cleared by cleanAllSettings")
        }
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("Reset restores the default wallpaper transition without wiping unrelated preferences")
    func cleanAllSettingsResetsWallpaperTransition() async throws {
        let scratch = try TestScratch.defaultsSuite("LiveWallpaperTests.resetTransition")
        let defaults = scratch.defaults
        defer { scratch.discard() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("resetTransition-\(UUID().uuidString)", isDirectory: true)
        let manager = SettingsManager(
            directory: ConfigurationDirectory(root: root),
            defaults: defaults
        )
        defaults.set(WallpaperTransitionChoice.meteor.rawValue, forKey: WallpaperTransitionChoice.defaultsKey)
        defaults.set(WallpaperOpeningChoice.dawn.rawValue, forKey: WallpaperOpeningChoice.defaultsKey)
        defaults.set("keep", forKey: "test.unrelated.preference")
        #expect(WallpaperTransitionChoice.stored(in: defaults) == .meteor)
        #expect(WallpaperOpeningChoice.stored(in: defaults) == .dawn)

        manager.cleanAllSettings(applyLoginSetting: false)

        #expect(defaults.object(forKey: WallpaperTransitionChoice.defaultsKey) == nil)
        #expect(WallpaperTransitionChoice.stored(in: defaults) == .crossfade)
        #expect(defaults.object(forKey: WallpaperOpeningChoice.defaultsKey) == nil)
        #expect(WallpaperOpeningChoice.stored(in: defaults) == .loom)
        #expect(defaults.string(forKey: "test.unrelated.preference") == "keep")
        await TestScratch.discard(root, flushing: manager)
    }

    @Test("Invalid local HTML bookmark fails configuration validation")
    func invalidLocalHTMLBookmarkFailsValidation() {
        let manager = SettingsManager.shared
        let previousConfigurations = manager.loadConfigurations()
        defer { manager.replaceAllConfigurations(previousConfigurations) }

        let screenID: CGDirectDisplayID = 909_001
        let config = ScreenConfiguration(
            screenID: screenID,
            wallpaper: .html(source: .file(bookmarkData: Data([0x01, 0x02])), config: .default)
        )
        manager.replaceAllConfigurations([config])

        #expect(!manager.validateConfiguration(for: screenID))
    }

    @Test("App-owned non-scoped video bookmark passes configuration validation")
    func appOwnedNonScopedVideoBookmarkPassesConfigurationValidation() throws {
        let manager = SettingsManager.shared
        let previousConfigurations = manager.loadConfigurations()
        defer { manager.replaceAllConfigurations(previousConfigurations) }

        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-local-video-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: videoURL) }
        try Data([0x00, 0x01]).write(to: videoURL)
        let bookmark = try videoURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )

        let screenID: CGDirectDisplayID = 909_002
        manager.replaceAllConfigurations([
            ScreenConfiguration(screenID: screenID, videoBookmarkData: bookmark)
        ])

        #expect(manager.validateConfiguration(for: screenID))
    }
}

@Suite("FrameRateLimit.getEffectiveLimit")
struct FrameRateLimitTests {
    @Test("Source and display caps preserve explicit targets", arguments: [
        (FrameRateLimit.matchDisplay, 30.0, 60.0, 0.0),
        (.matchDisplay, 120.0, 60.0, 60.0),
        (.matchDisplay, 60.0, 0.0, 0.0),
        (.fps30, 60.0, 60.0, 30.0),
        (.fps60, 30.0, 60.0, 0.0),
        (.fps60, 120.0, 48.0, 48.0),
        (.fps60, 120.0, 120.0, 60.0),
        (.matchDisplay, 120.0, 120.0, 0.0),
        (.fps30, 60.0, 24.0, 24.0),
    ])
    func effectiveLimit(limit: FrameRateLimit, video: Double, display: Double, expected: Double) {
        #expect(limit.getEffectiveLimit(videoFrameRate: video, screenRefreshRate: display) == Float(expected))
    }

    @Test("New wallpaper defaults preserve content cadence", arguments: [
        (WallpaperType.scene, FrameRateLimit.fps30), (.video, .matchDisplay), (.html, .matchDisplay),
    ])
    func naturalDefault(type: WallpaperType, expected: FrameRateLimit) {
        #expect(FrameRateLimit.naturalDefault(for: type) == expected)
    }
}

@Suite("PlainVideoFrameRateCompositionPolicy")
struct PlainVideoFrameRateCompositionPolicyTests {
    @Test("Explicit caps are passed to the player for source-cadence resolution")
    func explicitCapsReachPlayer() {
        #expect(PlainVideoFrameRateCompositionPolicy.compositionLimit(frameRateLimit: .fps15, screenRefreshRate: 60) == 15)
        #expect(PlainVideoFrameRateCompositionPolicy.compositionLimit(frameRateLimit: .fps30, screenRefreshRate: 60) == 30)
        #expect(PlainVideoFrameRateCompositionPolicy.compositionLimit(frameRateLimit: .fps60, screenRefreshRate: 120) == 60)
    }

    @Test("Max preserves native playback without requesting a composition")
    func unlimitedDoesNotUsePlainComposition() {
        #expect(PlainVideoFrameRateCompositionPolicy.compositionLimit(frameRateLimit: .matchDisplay, screenRefreshRate: 60) == nil)
    }

    @Test("Explicit cap is bounded by the current display and unknown display uses 60")
    func requestedCapFollowsDisplay() {
        #expect(PlainVideoFrameRateCompositionPolicy.compositionLimit(frameRateLimit: .fps120, screenRefreshRate: 60) == 60)
        #expect(PlainVideoFrameRateCompositionPolicy.compositionLimit(frameRateLimit: .fps120, screenRefreshRate: 0) == 60)
    }
}

@Suite("ParticleEffect Codable")
struct ParticleEffectCodableTests {
    @Test("Unknown raw value decodes to .none for compatibility")
    func unknownRawValueDecodesToNone() throws {
        let data = try JSONEncoder().encode("Lightning")
        let decoded = try JSONDecoder().decode(ParticleEffect.self, from: data)
        #expect(decoded == .none)
    }

    @Test("Known raw values still round-trip")
    func knownRawValuesRoundTrip() throws {
        for effect in ParticleEffect.allCases {
            let data = try JSONEncoder().encode(effect)
            let decoded = try JSONDecoder().decode(ParticleEffect.self, from: data)
            #expect(decoded == effect)
        }
    }
}

@Suite("FrameRateLimit.enforcesCompositionCap")
struct FrameRateLimitEnforcesCompositionCapTests {
    @Test("Every targeted cap forces composition")
    func dividedCapsForce() {
        #expect(FrameRateLimit.fps15.enforcesCompositionCap)
        #expect(FrameRateLimit.fps30.enforcesCompositionCap)
        #expect(FrameRateLimit.fps60.enforcesCompositionCap)
    }

    @Test("The panel's own rate stays on the native pass-through")
    func fullRateSkipsComposition() {
        #expect(!FrameRateLimit.matchDisplay.enforcesCompositionCap)
    }
}

@Suite("ScheduleSlot")
struct ScheduleSlotTests {
    @Test("Ranges include their start and exclude their end across midnight", arguments: [
        (6, 12, 9, true), (6, 12, 13, false), (6, 12, 6, true), (6, 12, 12, false),
        (22, 6, 23, true), (22, 6, 3, true), (22, 6, 12, false), (22, 6, 0, true),
    ])
    func containsHour(start: Int, end: Int, hour: Int, expected: Bool) {
        #expect(ScheduleSlot(startHour: start, endHour: end, label: "Range").containsMinute(hour * 60) == expected)
    }

    @Test("Default slots cover all 24 hours")
    func defaultSlotsCoverAllHours() {
        let slots = ScheduleSlot.defaultSlots
        for hour in 0..<24 {
            #expect(slots.contains { $0.containsMinute(hour * 60) }, "Hour \(hour) is not covered by any default slot")
        }
    }

    @Test("A slot saved with only whole hours decodes to the same minutes")
    func hourOnlySlotDecodesToMinutes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","startHour":22,"endHour":6,"label":"Night"}"#
        let slot = try JSONDecoder().decode(ScheduleSlot.self, from: Data(json.utf8))
        #expect(slot.startMinute == 1320)
        #expect(slot.endMinute == 360)
    }

    @Test("Invalid persisted schedule times throw instead of overflowing or reaching the dial", arguments: [
        ("startHour", Int.max), ("endHour", Int.min), ("startHour", 24), ("endHour", 25),
        ("startMinute", -1), ("startMinute", 1440), ("endMinute", -1), ("endMinute", Int.max),
    ])
    func invalidStoredTimesAreRejected(key: String, value: Int) throws {
        var payload: [String: Any] = [
            "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "startHour": 6, "endHour": 12, "label": "Range",
        ]
        payload[key] = value
        let data = try JSONSerialization.data(withJSONObject: payload)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ScheduleSlot.self, from: data)
        }
    }

    @Test("A slot writes its minutes plus whole hours an older app can read, and decodes back unchanged")
    func encodedSlotCarriesMinutesAndHours() throws {
        let slot = ScheduleSlot(startMinute: 450, endMinute: 765, label: "Morning")
        let data = try JSONEncoder().encode(slot)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["startMinute"] as? Int == 450)
        #expect(object["endMinute"] as? Int == 765)
        #expect(object["startHour"] as? Int == 7)
        #expect(object["endHour"] as? Int == 12)
        #expect(try JSONDecoder().decode(ScheduleSlot.self, from: data) == slot)
    }

    @Test("A slot across midnight includes its start minute and excludes its end minute")
    func minuteRangeAcrossMidnight() {
        let slot = ScheduleSlot(startMinute: 1350, endMinute: 375, label: "Night")
        #expect(!slot.containsMinute(1349))
        #expect(slot.containsMinute(1350))
        #expect(slot.containsMinute(0))
        #expect(slot.containsMinute(374))
        #expect(!slot.containsMinute(375))
    }

    @Test("Range text shows a midnight end as 24:00 and drops :00 in compact form only when both ends are on the hour")
    func rangeTextFormats() {
        #expect(ScheduleSlot(startMinute: 450, endMinute: 0, label: "A").rangeText() == "07:30–24:00")
        #expect(ScheduleSlot(startMinute: 360, endMinute: 720, label: "B").rangeText(compact: true) == "06–12")
        #expect(ScheduleSlot(startMinute: 390, endMinute: 720, label: "C").rangeText(compact: true) == "06:30–12:00")
    }
}

@Suite("VideoEffectConfig")
struct VideoEffectConfigTests {

    @Test("Default config has no active effects")
    func defaultNoActiveEffects() {
        let config = VideoEffectConfig.default
        #expect(!config.hasActiveEffect)
    }

    @Test("Blur triggers active effect")
    func blurActive() {
        var config = VideoEffectConfig.default
        config.blurRadius = 5
        #expect(config.hasActiveEffect)
    }

    @Test("Saturation != 1 triggers active effect")
    func saturationActive() {
        var config = VideoEffectConfig.default
        config.saturation = 0.5
        #expect(config.hasActiveEffect)
    }

    @Test("Auto time tint triggers active effect")
    func autoTimeTintActive() {
        var config = VideoEffectConfig.default
        config.autoTimeTint = true
        #expect(config.hasActiveEffect)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        var config = VideoEffectConfig()
        config.blurRadius = 10
        config.saturation = 0.8
        config.brightness = -0.2
        config.warmth = 4000
        config.vignetteIntensity = 3
        config.autoTimeTint = true
        config.particleDensity = 2.5

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoEffectConfig.self, from: data)

        #expect(decoded == config)
    }

    /// The stored-property default is a separate literal from the decoder's `?? 1.0`
    /// fallback that `legacyJsonDefaultsParticleDensityToOne` covers; neither fails for the other.
    @Test("Default particleDensity is 1.0")
    func defaultParticleDensity() {
        let config = VideoEffectConfig.default
        #expect(config.particleDensity == 1.0)
    }

    @Test("particleDensity does NOT trigger hasActiveEffect")
    func particleDensityIsNotAColorEffect() {
        var config = VideoEffectConfig.default
        config.particleDensity = 2.5
        #expect(!config.hasActiveEffect)
    }

    @Test("Legacy JSON without particleDensity decodes to 1.0")
    func legacyJsonDefaultsParticleDensityToOne() throws {
        let legacyJSON = """
        {
            "blurRadius": 0,
            "saturation": 1.0,
            "brightness": 0,
            "warmth": 6500,
            "vignetteIntensity": 0,
            "autoTimeTint": false,
            "weatherReactive": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(VideoEffectConfig.self, from: legacyJSON)
        #expect(decoded.particleDensity == 1.0)
    }

    @Test("particleDensity round-trip preserves arbitrary value")
    func particleDensityRoundTrip() throws {
        var config = VideoEffectConfig()
        config.particleDensity = 0.3

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VideoEffectConfig.self, from: data)

        #expect(decoded.particleDensity == 0.3)
    }
}

@Suite("ScreenConfiguration custom decoder")
struct ScreenConfigurationDecoderTests {

    @Test("HTML wallpaper config round-trips correctly")
    func htmlConfigRoundTrip() throws {
        let url = URL(string: "https://example.com/wallpaper")!
        let original = ScreenConfiguration(
            screenID: 42,
            wallpaper: .html(source: .url(url), config: .default)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.activeWallpaper == .html(source: .url(url), config: .default))
        #expect(decoded.wallpaperType == .html)
        #expect(decoded.htmlSource == .url(url))
        #expect(decoded.htmlConfig?.allowJavaScript == true)
        #expect(decoded.htmlConfig?.allowMouseInteraction == false)
        #expect(decoded.htmlConfig?.blockTrackers == true)
        #expect(decoded.screenID == 42)
        #expect(decoded.videoBookmarkData == nil)
    }

    @Test("HTML wallpaper config persists customised toggles")
    func htmlConfigPersistsCustomToggles() throws {
        let url = URL(string: "https://example.com/wallpaper")!
        let custom = HTMLConfig(
            allowJavaScript: false,
            allowMouseInteraction: true,
            blockTrackers: false,
            customCSS: "body { background: black; }"
        )
        let original = ScreenConfiguration(
            screenID: 11,
            wallpaper: .html(source: .url(url), config: custom)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.htmlConfig == custom)
    }

    @Test("Switching from HTML back to video restores the saved bookmark")
    func switchingBackToVideoRestoresSavedBookmark() {
        let bookmark = Data([0x10, 0x20, 0x30])
        var configuration = ScreenConfiguration(
            screenID: 314,
            videoBookmarkData: bookmark
        )

        configuration.setHTMLWallpaper(source: .url(URL(string: "https://example.com/live")!))
        let restored = configuration.activateSavedVideoWallpaper()

        #expect(restored == true)
        #expect(configuration.activeWallpaper == .video(bookmarkData: bookmark))
        #expect(configuration.videoBookmarkData == bookmark)
    }

    @Test("setAsLockScreen persists across encode/decode")
    func setAsLockScreenRoundTrip() throws {
        let original = ScreenConfiguration(
            screenID: 1,
            videoBookmarkData: Data(),
            setAsLockScreen: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.setAsLockScreen == true)
    }

    @Test("particleDensity inside effectConfig survives full round-trip")
    func nestedParticleDensityRoundTrip() throws {
        var effectConfig = VideoEffectConfig()
        effectConfig.particleDensity = 1.7
        let original = ScreenConfiguration(
            screenID: 99,
            videoBookmarkData: Data(),
            particleEffect: .snow,
            effectConfig: effectConfig
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.effectConfig.particleDensity == 1.7)
        #expect(decoded.particleEffect == .snow)
    }

    @Test("Playlist + schedule fields round-trip")
    func playlistAndScheduleRoundTrip() throws {
        let slots = ScheduleSlot.defaultSlots
        let bookmarks = [Data([0x01]), Data([0x02])]
        let original = ScreenConfiguration(
            screenID: 200,
            videoBookmarkData: Data(),
            scheduleSlots: slots,
            playlistBookmarks: bookmarks,
            shufflePlaylist: true,
            playlistRotationMinutes: 15,
            playlistAutoAdvance: false,
            playlistLoops: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: data)

        #expect(decoded.scheduleSlots?.count == slots.count)
        #expect(decoded.playlistBookmarks == bookmarks)
        #expect(decoded.shufflePlaylist == true)
        #expect(decoded.playlistRotationMinutes == 15)
        #expect(decoded.playlistAutoAdvance == false)
        #expect(decoded.playlistLoops == false)
    }

    private static func decodedWithoutPlaybackSwitches(_ config: ScreenConfiguration) throws -> ScreenConfiguration {
        let encoded = try JSONEncoder().encode(config)
        var dict = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(dict["playlistAutoAdvance"] as? Bool == config.playlistAutoAdvance)
        #expect(dict["playlistLoops"] as? Bool == config.playlistLoops)
        dict.removeValue(forKey: "playlistAutoAdvance")
        dict.removeValue(forKey: "playlistLoops")
        return try JSONDecoder().decode(ScreenConfiguration.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    private static func htmlQueue(_ count: Int) -> [WallpaperQueueEntry] {
        (0 ..< count).map { WallpaperQueueEntry(id: "row\($0)", title: "", content: .html(source: .inline("row\($0)"), config: .default)) }
    }

    @Test("Legacy JSON: a multi-entry list without an interval stays manual; loop defaults on")
    func legacyManualListStaysManual() throws {
        var config = ScreenConfiguration(screenID: 5, wallpaper: .html(source: .inline("row0"), config: .default))
        config.wallpaperQueue = Self.htmlQueue(2)
        let decoded = try Self.decodedWithoutPlaybackSwitches(config)
        #expect(decoded.playlistRotationMinutes == nil)
        #expect(decoded.playlistAutoAdvance == false)
        #expect(decoded.playlistLoops == true)
    }

    @Test("Legacy JSON: a list with an interval keeps advancing")
    func legacyTimedListKeepsAdvancing() throws {
        var config = ScreenConfiguration(screenID: 6, wallpaper: .html(source: .inline("row0"), config: .default))
        config.wallpaperQueue = Self.htmlQueue(2)
        config.playlistRotationMinutes = 30
        let decoded = try Self.decodedWithoutPlaybackSwitches(config)
        #expect(decoded.playlistAutoAdvance == true)
        #expect(decoded.playlistLoops == true)
    }

    @Test("Legacy JSON: a display with a single entry takes the new auto-advance default")
    func legacySingleEntryTakesNewDefault() throws {
        var config = ScreenConfiguration(screenID: 7, wallpaper: .html(source: .inline("row0"), config: .default))
        config.wallpaperQueue = Self.htmlQueue(1)
        let decoded = try Self.decodedWithoutPlaybackSwitches(config)
        #expect(decoded.playlistAutoAdvance == true)
    }

    @Test("Legacy JSON: a video list kept only in bookmarks without an interval stays manual")
    func legacyBookmarkVideoListStaysManual() throws {
        let config = ScreenConfiguration(screenID: 8, videoBookmarkData: Data([0x01]), playlistBookmarks: [Data([0x02])])
        #expect(config.wallpaperQueue == nil)
        let decoded = try Self.decodedWithoutPlaybackSwitches(config)
        #expect(decoded.playlistAutoAdvance == false)
    }

    @Test("Legacy JSON without wallpaperMode (no schedule) → defaults to .playlist")
    func legacyInferDefaultPlaylistMode() throws {
        let config = ScreenConfiguration(
            screenID: 3,
            videoBookmarkData: Data([0x01])
        )
        let encoded = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict.removeValue(forKey: "wallpaperMode")
        let stripped = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: stripped)
        #expect(decoded.wallpaperMode == .playlist)
    }

    @Test("A stored `single` wallpaperMode decodes to single wallpaper")
    func storedSingleStringDecodesToSingle() throws {
        let config = ScreenConfiguration(
            screenID: 4,
            videoBookmarkData: Data([0x01])
        )
        let encoded = try JSONEncoder().encode(config)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded)
        var dict = try #require(jsonObject as? [String: Any])
        dict["wallpaperMode"] = "single"
        let mutated = try JSONSerialization.data(withJSONObject: dict)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: mutated)
        #expect(decoded.wallpaperMode == .single)
    }

    @Test("Explicit wallpaperMode field round-trips intact")
    func wallpaperModeRoundTrip() throws {
        let bookmark = Data([0x01])
        var config = ScreenConfiguration(
            screenID: 4,
            videoBookmarkData: bookmark
        )
        config.wallpaperMode = .playlist

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ScreenConfiguration.self, from: encoded)
        #expect(decoded.wallpaperMode == .playlist)
    }
}

@Suite("GlobalSettings custom decoder")
struct GlobalSettingsDecoderTests {

    @Test("Empty JSON object fills all defaults")
    func emptyJsonDefaults() throws {
        let emptyJSON = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: emptyJSON)

        #expect(decoded.globalPauseOnBattery == false)
        #expect(decoded.preservePlaybackOnLock == false)
        #expect(decoded.startOnLogin == false)
        #expect(decoded.pauseOnFullScreen == true)
    }

    @Test("Full round-trip preserves every remaining field")
    func fullRoundTrip() throws {
        let original = GlobalSettings(
            globalPauseOnBattery: false,
            preservePlaybackOnLock: true,
            startOnLogin: true,
            pauseOnFullScreen: false
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.globalPauseOnBattery == false)
        #expect(decoded.preservePlaybackOnLock == true)
        #expect(decoded.startOnLogin == true)
        #expect(decoded.pauseOnFullScreen == false)
    }
}

@Suite("FrameRateLimit.resolveCompositionFPS")
struct ResolveCompositionFPSTests {
    @Test("Composition respects source cadence, target and display fallback", arguments: [
        (FrameRateLimit.matchDisplay, 120.0, 60.0, 60.0),
        (.matchDisplay, 120.0, 120.0, 120.0),
        (.matchDisplay, 30.0, 60.0, 30.0),
        (.matchDisplay, 0.0, 144.0, 144.0),
        (.matchDisplay, 0.0, 0.0, 60.0),
        (.fps60, 120.0, 60.0, 60.0),
        (.fps60, 30.0, 60.0, 30.0),
        (.fps60, 120.0, 144.0, 60.0),
        (.fps30, 60.0, 60.0, 30.0),
        (.fps15, 30.0, 60.0, 15.0),
    ])
    func compositionFPS(limit: FrameRateLimit, video: Double, display: Double, expected: Double) {
        #expect(FrameRateLimit.resolveCompositionFPS(limit: limit, videoFrameRate: video, screenRefreshRate: display) == expected)
    }
}

@Suite("FilterParameters")
struct FilterParametersTests {

    @Test("Immutable snapshot from config")
    func snapshotFromConfig() {
        var config = VideoEffectConfig.default
        config.blurRadius = 15
        config.warmth = 4000

        let params = FilterParameters(from: config)
        #expect(params.blurRadius == 15)
        #expect(params.warmth == 4000)
        #expect(params.saturation == 1.0)
    }
}
