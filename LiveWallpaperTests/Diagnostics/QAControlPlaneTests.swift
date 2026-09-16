#if DEBUG
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("QA control plane defaults tool", .serialized)
@MainActor
struct QAControlPlaneDefaultsTests {
    private func call(_ tool: String, _ arguments: String) -> [String: Any] {
        let line = #"{"tool":"\#(tool)","arguments":\#(arguments)}"#
        let response = QAControlPlane.shared.respond(to: line)
        return (try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]) ?? [:]
    }

    /// `UserDefaults.set(NSNull())` raises an ObjC exception; a JSON null has to mean "remove".
    @Test("A null value removes the key instead of crashing the app")
    func nullRemovesKey() {
        let key = "loomscreen.qa.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let set = call("defaults.set", #"{"key":"\#(key)","value":1}"#)
        #expect(set["ok"] as? Bool == true)
        #expect(UserDefaults.standard.integer(forKey: key) == 1)

        let cleared = call("defaults.set", #"{"key":"\#(key)","value":null}"#)
        #expect(cleared["ok"] as? Bool == true)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(call("defaults.get", #"{"key":"\#(key)"}"#)["ok"] as? Bool == true)
    }

    @Test("A non-property-list value is refused, not written")
    func nonPropertyListIsRefused() {
        let key = "loomscreen.qa.test.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let refused = call("defaults.set", #"{"key":"\#(key)","value":{"nested":null}}"#)
        #expect(refused["ok"] as? Bool == false)
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}
#endif
