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
        let clearedInput = Data(#"{"version":1,"items":[],"displaySelections":{"2":"video-b"},"clearedDisplays":{"1":4}}"#.utf8)
        let cleared = try JSONDecoder().decode(SystemWallpaperManifest.self, from: JSONEncoder().encode(
            JSONDecoder().decode(SystemWallpaperManifest.self, from: clearedInput)
        ))
        guard cleared.clearedDisplays == ["1": 4], cleared.isCleared(displayID: 1), !cleared.isCleared(displayID: 2) else {
            print("FAIL: an explicitly cleared display must survive manifest serialization")
            exit(1)
        }
        print("PASS: selected item, distinct per-display selections and cleared displays survive manifest serialization")
    }
}
