#if !LITE_BUILD
import Foundation

/// Scenes rendered by the parity pipeline instead of `WPEMetalSceneRenderer`.
enum WPEParityRendererFlag {
    /// Workshop id strings; `"*"` selects every scene. Absent ⇒ none.
    static let defaultsKey = "loomscreen.wallpapers.parityRenderer.v1"

    static func isEnabled(workshopID: String?, defaults: UserDefaults = .appScoped()) -> Bool {
        guard let ids = defaults.stringArray(forKey: defaultsKey) else { return false }
        return ids.contains("*") || workshopID.map(ids.contains) == true
    }
}
#endif
