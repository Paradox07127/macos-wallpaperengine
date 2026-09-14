import Foundation

enum WPEOffMainRenderFlag {
    static let defaultsKey = "loomscreen.wallpapers.offMainRender.v1"

    /// Read once per display-actor construction. Absent ⇒ true (render-thread).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static var backing: WPEDisplayRenderActor.Backing {
        isEnabled ? .renderThread : .main
    }
}
