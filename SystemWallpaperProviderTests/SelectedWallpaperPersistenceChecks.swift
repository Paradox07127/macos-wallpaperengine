import Foundation

@main
struct SelectedWallpaperPersistenceChecks {
    static func main() throws {
        let input = Data(#"{"version":1,"items":[],"selectedItemID":"video-a","displaySelections":{"1":"video-a","2":"video-b"}}"#.utf8)
        let manifest = try JSONDecoder().decode(SystemWallpaperManifest.self, from: input)
        let encoded = try JSONEncoder().encode(manifest)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        guard object?["selectedItemID"] as? String == "video-a",
              object?["displaySelections"] as? [String: String] == ["1": "video-a", "2": "video-b"] else {
            print("FAIL: selected item and distinct per-display selections must survive manifest serialization")
            exit(1)
        }
        print("PASS: selected item and distinct per-display selections survive manifest serialization")
    }
}
