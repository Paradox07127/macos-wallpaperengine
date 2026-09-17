#if DEBUG
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("QA control plane defaults values")
struct QAControlPlaneDefaultsValueTests {
    @Test("Non-JSON defaults are reported by type instead of crashing the serializer")
    func opaqueValuesAreDescribedNotSerialized() throws {
        let bookmark = Data([0x62, 0x6F, 0x6F, 0x6B])
        let described = try #require(QAControlPlane.jsonSafeDefaultsValue(bookmark) as? [String: Any])
        #expect(described["opaque"] as? Bool == true)
        #expect(JSONSerialization.isValidJSONObject(["value": described]))
        #expect(QAControlPlane.jsonSafeDefaultsValue("plain") as? String == "plain")
        #expect(QAControlPlane.jsonSafeDefaultsValue(nil) is NSNull)
    }
}
#endif
