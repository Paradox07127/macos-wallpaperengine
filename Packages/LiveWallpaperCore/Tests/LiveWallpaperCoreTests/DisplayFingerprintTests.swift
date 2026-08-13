import Foundation
import Testing
@testable import LiveWallpaperCore

@Suite("Display fingerprint identity")
struct DisplayFingerprintTests {

    /// Real values read off this project's own displays.
    private let benqSerial: UInt32 = 21573

    @Test("A panel with a real EDID serial keeps its existing key")
    func realSerialKeepsEDIDKey() {
        let key = DisplayFingerprint.make(
            vendor: 2513,
            model: 32829,
            serial: benqSerial,
            uuid: "EF83AF18-0D94-4837-9C0A-13B33C013B29",
            localizedName: "BenQ PD3205U"
        )
        #expect(key == "2513:32829:21573")
        #expect(DisplayFingerprint.legacyKey(vendor: 2513, model: 32829, serial: benqSerial, current: key) == nil)
    }

    /// Two units of the same model both report serial 0, so the EDID triple
    /// cannot separate them — this is the case the UUID exists for.
    @Test("A serial-0 panel is keyed by its per-display UUID instead")
    func zeroSerialFallsBackToUUID() {
        let key = DisplayFingerprint.make(
            vendor: 13929,
            model: 15830,
            serial: 0,
            uuid: "487D9D08-7415-44F4-9B38-9C68EE0A4271",
            localizedName: "MPG321CX OLED"
        )
        #expect(key == "uuid:487D9D08-7415-44F4-9B38-9C68EE0A4271")
    }

    @Test("Two identical serial-0 panels get different keys")
    func identicalPanelsDoNotCollide() {
        func key(uuid: String) -> String {
            DisplayFingerprint.make(
                vendor: 13929, model: 15830, serial: 0,
                uuid: uuid, localizedName: "MPG321CX OLED"
            )
        }
        #expect(key(uuid: "AAAA") != key(uuid: "BBBB"))
    }

    @Test("A serial-0 panel reports the EDID key it used before the switch")
    func zeroSerialExposesLegacyKey() {
        let key = DisplayFingerprint.make(
            vendor: 13929, model: 15830, serial: 0,
            uuid: "487D9D08", localizedName: "MPG321CX OLED"
        )
        #expect(DisplayFingerprint.legacyKey(vendor: 13929, model: 15830, serial: 0, current: key) == "13929:15830:0")
    }

    @Test("Without a UUID a serial-0 panel keeps the EDID key rather than losing identity")
    func zeroSerialWithoutUUIDStaysOnEDID() {
        let key = DisplayFingerprint.make(
            vendor: 13929, model: 15830, serial: 0,
            uuid: nil, localizedName: "MPG321CX OLED"
        )
        #expect(key == "13929:15830:0")
        #expect(DisplayFingerprint.legacyKey(vendor: 13929, model: 15830, serial: 0, current: key) == nil)
    }

    @Test("A panel with no EDID at all stays on the unknown key")
    func noEDIDStaysUnknown() {
        let key = DisplayFingerprint.make(
            vendor: 0, model: 0, serial: 0,
            uuid: nil, localizedName: "Some Panel"
        )
        #expect(key == "unknown:0:0:0:Some Panel")
        #expect(key.isUnknownDisplayFingerprint)
        #expect(DisplayFingerprint.legacyKey(vendor: 0, model: 0, serial: 0, current: key) == nil)
    }

    /// Guards the zero-migration promise: a display with a real serial must not
    /// even consult the UUID, so its key can never drift.
    @Test("The UUID is never consulted for a panel with a real serial")
    func uuidIsNotEvaluatedForRealSerials() {
        var reads = 0
        _ = DisplayFingerprint.make(
            vendor: 2513, model: 32829, serial: benqSerial,
            uuid: { reads += 1; return "UUID" }(),
            localizedName: "BenQ PD3205U"
        )
        #expect(reads == 0)
    }
}
