import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("App-window pause setting persistence")
struct AppWindowSettingPersistenceTests {
    @Test("An opted-in app-window policy survives settings serialization")
    func retainsOptIn() throws {
        let decoded = try JSONDecoder().decode(GlobalSettings.self, from: Data(#"{"pauseOnAppWindow":true}"#.utf8))
        let encoded = try JSONEncoder().encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["pauseOnAppWindow"] as? Bool == true)
    }
}
