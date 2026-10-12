#if !LITE_BUILD
import Foundation

/// Scenes rendered by the parity pipeline instead of `WPEMetalSceneRenderer`.
enum WPEParityRendererFlag {
    enum Mode: String, CaseIterable {
        case off, all, listed
    }

    /// Workshop id strings; `"*"` selects every scene. Absent ⇒ none. Read only in `.listed` mode.
    static let defaultsKey = "loomscreen.wallpapers.parityRenderer.v1"
    /// A `Mode` raw value; absent ⇒ `.listed`.
    static let modeDefaultsKey = "loomscreen.wallpapers.parityRendererMode.v1"

    static func mode(defaults: UserDefaults = .appScoped()) -> Mode {
        defaults.string(forKey: modeDefaultsKey).flatMap(Mode.init(rawValue:)) ?? .listed
    }

    static func setMode(_ mode: Mode, defaults: UserDefaults = .appScoped()) {
        defaults.set(mode.rawValue, forKey: modeDefaultsKey)
    }

    static func isEnabled(workshopID: String?, defaults: UserDefaults = .appScoped()) -> Bool {
        switch mode(defaults: defaults) {
        case .off: return false
        case .all: return true
        case .listed:
            guard let ids = defaults.stringArray(forKey: defaultsKey) else { return false }
            return ids.contains("*") || workshopID.map(ids.contains) == true
        }
    }

    static func setListed(_ listed: Bool, workshopID: String, defaults: UserDefaults = .appScoped()) {
        var ids = defaults.stringArray(forKey: defaultsKey) ?? []
        ids.removeAll { $0 == workshopID }
        if listed {
            ids.append(workshopID)
        }
        defaults.set(ids, forKey: defaultsKey)
    }

    /// A scene's "Render with New Pipeline" menu row: only `.listed` mode lets the row change anything.
    static func menuState(workshopID: String, defaults: UserDefaults = .appScoped()) -> (isChecked: Bool, isEnabled: Bool) {
        (isEnabled(workshopID: workshopID, defaults: defaults), mode(defaults: defaults) == .listed)
    }
}
#endif
