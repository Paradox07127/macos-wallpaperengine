@testable import LiveWallpaper
import Testing

/// MAC-09: two same-model panels (both EDID serial 0) share one legacy fingerprint key.
/// A naive `removeValue`-in-a-loop migration lets the first screen consume the shared
/// legacy value, leaving the second screen with nil. `migrateLegacyFingerprintKeys`
/// must clone the shared value to every mapped screen instead.
@Suite("Legacy display fingerprint migration")
struct LegacyFingerprintMigrationTests {
    @Test("Two screens sharing one legacy fingerprint both receive the value")
    func sharedLegacyFingerprintClonesToBothScreens() {
        let dict = ["shared:legacy": "Living Room"]
        let mappings = [
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:A"),
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:B"),
        ]

        let migrated = ScreenManager.migrateLegacyFingerprintKeys(dict, mappings: mappings)

        #expect(migrated["uuid:A"] == "Living Room")
        #expect(migrated["uuid:B"] == "Living Room")
        #expect(migrated["shared:legacy"] == nil)
    }

    @Test("Result is independent of mapping enumeration order")
    func orderIndependent() {
        let dict = ["shared:legacy": "Living Room"]
        let mappings = [
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:A"),
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:B"),
        ]

        let forward = ScreenManager.migrateLegacyFingerprintKeys(dict, mappings: mappings)
        let reversed = ScreenManager.migrateLegacyFingerprintKeys(dict, mappings: Array(mappings.reversed()))

        #expect(forward == reversed)
    }

    @Test("An existing current-key value is never overwritten by the legacy value")
    func existingCurrentValueWins() {
        let dict = [
            "shared:legacy": "Old Name",
            "uuid:A": "Already Named",
        ]
        let mappings = [
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:A"),
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:B"),
        ]

        let migrated = ScreenManager.migrateLegacyFingerprintKeys(dict, mappings: mappings)

        #expect(migrated["uuid:A"] == "Already Named")
        #expect(migrated["uuid:B"] == "Old Name")
    }

    @Test("Running the migration twice is a no-op the second time")
    func idempotent() {
        let dict = ["shared:legacy": "Living Room"]
        let mappings = [
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:A"),
            LegacyFingerprintMapping(legacy: "shared:legacy", current: "uuid:B"),
        ]

        let once = ScreenManager.migrateLegacyFingerprintKeys(dict, mappings: mappings)
        let twice = ScreenManager.migrateLegacyFingerprintKeys(once, mappings: mappings)

        #expect(once == twice)
    }
}
