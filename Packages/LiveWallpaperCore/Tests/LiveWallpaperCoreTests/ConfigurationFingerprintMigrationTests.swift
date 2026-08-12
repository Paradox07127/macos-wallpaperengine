import Foundation
import CoreGraphics
import Testing
@testable import LiveWallpaperCore

@MainActor
@Suite("ConfigurationStore fingerprint fallback")
struct ConfigurationFingerprintMigrationTests {

    @Test("Direct ID hit returns cached config and back-fills missing fingerprint")
    func directIDHitBackfillsFingerprint() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        let original = makeVideoConfig(screenID: 42, fingerprint: nil)
        store.save(original)
        store.clearCache()

        let resolved = store.get(for: 42, fingerprint: "V:M:S")
        #expect(resolved?.screenID == 42)
        #expect(resolved?.displayFingerprint == "V:M:S")
        #expect(fakePersistence.allConfigs[42]?.displayFingerprint == "V:M:S")
    }

    @Test("ID miss + fingerprint hit migrates screenID and persists")
    func fingerprintMigration() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        let originalConfig = makeVideoConfig(screenID: 42, fingerprint: "V:M:S")
        store.save(originalConfig)
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: "V:M:S")

        #expect(resolved?.screenID == 999)
        #expect(resolved?.displayFingerprint == "V:M:S")
        #expect(fakePersistence.allConfigs[42] == nil)
        #expect(fakePersistence.allConfigs[999]?.displayFingerprint == "V:M:S")
        if case .video = fakePersistence.allConfigs[999]?.activeWallpaper {
            // ok
        } else {
            Issue.record("Migrated config lost its wallpaper content")
        }
    }

    @Test("ID miss + fingerprint miss returns nil")
    func bothMissReturnsNil() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        store.save(makeVideoConfig(screenID: 42, fingerprint: "V:M:S"))
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: "OTHER:M:S")
        #expect(resolved == nil)
        #expect(fakePersistence.allConfigs[42]?.screenID == 42)
    }

    @Test("Unknown fingerprint never triggers scan")
    func unknownFingerprintSkipsScan() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        store.save(makeVideoConfig(screenID: 42, fingerprint: "V:M:S"))
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: "unknown:Display 1")
        #expect(resolved == nil)
        #expect(fakePersistence.allConfigs[42]?.screenID == 42)
    }

    @Test("Nil fingerprint skips scan (preserves nil-fallback safety)")
    func nilFingerprintSkipsScan() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        store.save(makeVideoConfig(screenID: 42, fingerprint: "V:M:S"))
        store.clearCache()

        let resolved = store.get(for: 999, fingerprint: nil)
        #expect(resolved == nil)
    }

    @Test("Fingerprint conflict parks the displaced config instead of dropping it")
    func fingerprintConflictParksDisplacedConfig() {
        let fakePersistence = InMemoryConfigPersistence()
        let store = WallpaperConfigurationStore(persistence: fakePersistence)

        store.save(makeVideoConfig(screenID: 42, fingerprint: "OLD"))
        store.save(makeVideoConfig(screenID: 7, fingerprint: "NEW"))
        store.clearCache()

        // macOS recycled ID 42 onto the "NEW" panel.
        let resolved = store.get(for: 42, fingerprint: "NEW")
        #expect(resolved?.screenID == 42)
        #expect(resolved?.displayFingerprint == "NEW")

        // The displaced panel's config survives, parked off any live screen ID…
        let parked = fakePersistence.loadConfigurations().first { $0.displayFingerprint == "OLD" }
        #expect(parked != nil, "Displaced config must not be dropped by the screenID collision")
        #expect(parked?.screenID == WallpaperConfigurationStore.parkedScreenID)

        // …and its panel reclaims it by fingerprint when it comes back.
        let reclaimed = store.get(for: 99, fingerprint: "OLD")
        #expect(reclaimed?.screenID == 99)
        #expect(reclaimed?.displayFingerprint == "OLD")
        #expect(fakePersistence.loadConfigurations().count == 2)
    }

    @Test("Duplicate screenID entries in persistence do not trap loadAll")
    func duplicateScreenIDsDoNotTrapLoadAll() {
        let persistence = DuplicateTolerantConfigPersistence([
            makeVideoConfig(screenID: 42, fingerprint: "A"),
            makeVideoConfig(screenID: 42, fingerprint: "B")
        ])
        let store = WallpaperConfigurationStore(persistence: persistence)

        let configs = store.loadAll()

        #expect(configs.count == 2)
        #expect(store.get(for: 42)?.displayFingerprint == "B", "Later entry wins on duplicate screenID")
    }

    @Test("Per-screen revision advances for every semantic write")
    func revisionAdvancesForEveryWrite() {
        let store = WallpaperConfigurationStore(
            persistence: InMemoryConfigPersistence()
        )
        let configuration = makeVideoConfig(screenID: 42, fingerprint: nil)

        #expect(store.revision(for: 42) == 0)
        store.save(configuration)
        #expect(store.revision(for: 42) == 1)

        // Equal-value saves still represent newer user intent to a prepared
        // transaction and must therefore invalidate its captured revision.
        store.save(configuration)
        #expect(store.revision(for: 42) == 2)

        store.remove(for: 42)
        #expect(store.revision(for: 42) == 3)
    }

    private func makeVideoConfig(
        screenID: CGDirectDisplayID,
        fingerprint: String?
    ) -> ScreenConfiguration {
        var config = ScreenConfiguration(
            screenID: screenID,
            videoBookmarkData: Data([0x42, 0x42])
        )
        config.displayFingerprint = fingerprint
        return config
    }
}

@MainActor
private final class InMemoryConfigPersistence: ScreenConfigurationPersisting {
    private(set) var allConfigs: [CGDirectDisplayID: ScreenConfiguration] = [:]

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        allConfigs[screenID]
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        allConfigs[configuration.screenID] = configuration
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        allConfigs.removeValue(forKey: screenID)
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        Array(allConfigs.values)
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        allConfigs = Dictionary(uniqueKeysWithValues: configurations.map { ($0.screenID, $0) })
    }
}

/// Array-backed fake so tests can feed the store duplicate screenIDs, which
/// the dictionary-backed fake cannot represent.
@MainActor
private final class DuplicateTolerantConfigPersistence: ScreenConfigurationPersisting {
    private var configurations: [ScreenConfiguration]

    init(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }

    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        configurations.first { $0.screenID == screenID }
    }

    func saveConfiguration(_ configuration: ScreenConfiguration) {
        configurations.removeAll { $0.screenID == configuration.screenID }
        configurations.append(configuration)
    }

    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID) {
        configurations.removeAll { $0.screenID == screenID }
    }

    func loadConfigurations() -> [ScreenConfiguration] {
        configurations
    }

    func replaceAllConfigurations(_ configurations: [ScreenConfiguration]) {
        self.configurations = configurations
    }
}
