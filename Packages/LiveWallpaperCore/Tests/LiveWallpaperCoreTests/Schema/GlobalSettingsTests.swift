import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("GlobalSettings")
struct GlobalSettingsTests {

    @Test("New installs show in the Dock; legacy settings keep their existing menu-bar-only default")
    func dockDefaultPreservesExistingInstalls() throws {
        #expect(GlobalSettings().showInDock)
        let legacy = try JSONDecoder().decode(GlobalSettings.self, from: Data("{}".utf8))
        #expect(!legacy.showInDock)
        for stored in [false, true] {
            let data = Data("{\"showInDock\":\(stored)}".utf8)
            #expect(try JSONDecoder().decode(GlobalSettings.self, from: data).showInDock == stored)
        }
    }

    @Test("Legacy JSON without globalShortcutsEnabled decodes to true")
    func legacyDecodeDefaultsToTrue() throws {
        let legacyJSON = """
        {
          "globalPauseOnBattery": false,
          "preservePlaybackOnLock": false,
          "startOnLogin": false,
          "pauseOnFullScreen": true,
          "showInDock": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)

        #expect(decoded.globalShortcutsEnabled == true)
        #expect(decoded.globalShortcuts.isEmpty)
    }

    @Test("Legacy game-mode preference is not re-encoded on the next save")
    func legacyGameModePreferenceIsDiscarded() throws {
        let legacyJSON = """
        {
          "pauseInGameMode": false,
          "pauseOnFullScreen": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        #expect(object["pauseInGameMode"] == nil)
        #expect(decoded.pauseOnFullScreen)
    }

    @Test("Round-trip preserves globalShortcutsEnabled when explicitly disabled")
    func roundTripDisabled() throws {
        var settings = GlobalSettings()
        settings.globalShortcutsEnabled = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.globalShortcutsEnabled == false)
    }

    @Test("Legacy JSON without the occlusion key defaults to true (power-saving)")
    func legacyOcclusionKeyDefaultsToTrue() throws {
        let legacyJSON = """
        {
          "globalPauseOnBattery": false,
          "pauseOnFullScreen": true,
          "showInDock": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacyJSON)

        #expect(decoded.pauseOnWindowOcclusion == true)
    }

    @Test("An explicitly stored occlusion=false still round-trips as false")
    func explicitOcclusionFalseSurvivesRoundTrip() throws {
        var settings = GlobalSettings()
        settings.pauseOnWindowOcclusion = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.pauseOnWindowOcclusion == false)
    }

    @Test("A malformed history row drops only that row, not the whole import list")
    func lossyDecodeSalvagesGoodHistoryEntries() throws {
        let good = makeHistoryEntry("100")
        let alsoGood = makeHistoryEntry("200")
        var settings = GlobalSettings()
        settings.recentWPEImports = [good, alsoGood]

        let data = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var imports = try #require(object["recentWPEImports"] as? [[String: Any]])
        try #require(imports.count == 2)
        imports[0] = ["origin": ["not": "a valid origin"]]
        object["recentWPEImports"] = imports
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: corrupted)

        #expect(decoded.recentWPEImports.map(\.origin.workshopID) == ["200"])
    }

    @Test("A completely malformed history array decodes to empty, not a throw")
    func lossyDecodeHandlesFullyBrokenArray() throws {
        let brokenJSON = """
        {
          "recentWPEImports": [ {"bad": 1}, "junk", 42, null ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: brokenJSON)

        #expect(decoded.recentWPEImports.isEmpty)
    }

    @Test("An unknown trigger drops only that rule, not the whole per-app rule list")
    func lossyDecodeSalvagesGoodPerformanceRules() throws {
        var settings = GlobalSettings()
        settings.applicationPerformanceRules = [
            ApplicationPerformanceRule(bundleID: "com.apple.Safari", displayName: "Safari", trigger: .frontmost),
            ApplicationPerformanceRule(bundleID: "com.valvesoftware.steam", displayName: "Steam", trigger: .running),
        ]

        let data = try JSONEncoder().encode(settings)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var rules = try #require(object["applicationPerformanceRules"] as? [[String: Any]])
        try #require(rules.count == 2)
        rules[1]["trigger"] = "pauseWhenIdle"
        object["applicationPerformanceRules"] = rules
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: corrupted)

        #expect(decoded.applicationPerformanceRules.map(\.bundleID) == ["com.apple.Safari"])
    }

    // MARK: - Helpers

    private func makeHistoryEntry(_ workshopID: String) -> WPEHistoryEntry {
        WPEHistoryEntry(
            origin: WPEOrigin(
                workshopID: workshopID,
                title: "Wallpaper \(workshopID)",
                originalType: .video,
                sourceFolderBookmark: Data(workshopID.utf8),
                cacheRelativePath: "wpe-cache/\(workshopID)",
                previewFileName: "preview.gif"
            ),
            importedAt: Date(timeIntervalSince1970: Double(workshopID) ?? 0)
        )
    }

    @Test("An explicit opt-out on the retired game/Low-Power toggle carries forward")
    func retiredOptOutCarriesForward() throws {
        let legacy = Data("""
        {"pauseInGameMode": false, "pauseOnFullScreen": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: legacy)
        #expect(!decoded.pauseInLowPowerMode, "the stored opt-out must survive the rename")
    }

    @Test("The retired key does not override an explicit new value")
    func explicitNewValueWinsOverRetired() throws {
        let both = Data("""
        {"pauseInGameMode": false, "pauseInLowPowerMode": true}
        """.utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: both)
        #expect(decoded.pauseInLowPowerMode)
    }

    @Test("An install predating both keys still ships with the pause on")
    func predatesBothKeys() throws {
        let old = Data("{\"pauseOnFullScreen\": true}".utf8)
        #expect(try JSONDecoder().decode(GlobalSettings.self, from: old).pauseInLowPowerMode)
    }

    @Test("A retired opt-in also carries forward")
    func retiredOptInCarriesForward() throws {
        let legacy = Data("{\"pauseInGameMode\": true}".utf8)
        #expect(try JSONDecoder().decode(GlobalSettings.self, from: legacy).pauseInLowPowerMode)
    }

    @Test("Custom display names round-trip, keyed by display fingerprint")
    func screenNamesRoundTrip() throws {
        var settings = GlobalSettings()
        settings.screenNames = ["1552:24067:16843009": "Desk left"]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.screenNames["1552:24067:16843009"] == "Desk left")
    }

    @Test("An install predating the Workshop default sort browses Most Popular over one week")
    func workshopDefaultSortDefaults() throws {
        let old = Data("{\"pauseOnFullScreen\": true}".utf8)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: old)
        #expect(decoded.workshopDefaultSort == "mostPopular")
        #expect(decoded.workshopDefaultTimeFrame == "oneWeek")
    }

    @Test("A chosen Workshop default sort and window round-trip")
    func workshopDefaultSortRoundTrips() throws {
        var settings = GlobalSettings()
        settings.workshopDefaultSort = "lastUpdated"
        settings.workshopDefaultTimeFrame = "thirtyDays"

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: data)

        #expect(decoded.workshopDefaultSort == "lastUpdated")
        #expect(decoded.workshopDefaultTimeFrame == "thirtyDays")
    }

    @Test("An install predating custom display names decodes to none")
    func screenNamesDefaultToEmpty() throws {
        let old = Data("{\"pauseOnFullScreen\": true}".utf8)
        #expect(try JSONDecoder().decode(GlobalSettings.self, from: old).screenNames.isEmpty)
    }

    private static let shortcutOverrides: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [
        GlobalShortcutAction.togglePlayback.rawAction: GlobalShortcutBinding(keyCode: 49, modifiers: [.command, .shift]),
        GlobalShortcutAction.toggleMute.rawAction: .none,
        "retiredAction": GlobalShortcutBinding(keyCode: 1, modifiers: [.option]),
    ]

    @Test("One unreadable shortcut binding costs that action only, not every override")
    func unreadableShortcutBindingDropsOnlyItself() throws {
        var settings = GlobalSettings()
        settings.globalShortcuts = Self.shortcutOverrides
        settings.globalShortcuts[GlobalShortcutAction.nextWallpaper.rawAction] = GlobalShortcutBinding(keyCode: 124, modifiers: [.control])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        var shortcuts = try #require(json["globalShortcuts"] as? [String: Any])
        shortcuts[GlobalShortcutAction.nextWallpaper.rawAction] = ["keyCode": "not-a-key-code"]
        json["globalShortcuts"] = shortcuts

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONSerialization.data(withJSONObject: json))

        #expect(decoded.globalShortcuts == Self.shortcutOverrides, "one bad binding reset every shortcut to its default")
    }

    @Test("Readable overrides round-trip, including a cleared one and an action this build does not know")
    func readableShortcutOverridesRoundTrip() throws {
        var settings = GlobalSettings()
        settings.globalShortcuts = Self.shortcutOverrides

        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: JSONEncoder().encode(settings))

        #expect(decoded.globalShortcuts == Self.shortcutOverrides)
    }
}
