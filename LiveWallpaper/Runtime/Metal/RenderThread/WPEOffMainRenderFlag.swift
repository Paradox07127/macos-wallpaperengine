import Foundation

/// Decides which thread each display's `WPEDisplayRenderActor` is backed by. `true`
/// (default) = a dedicated `WPERenderThread` per display; `false` = the actor's
/// isolation runs on the main run loop, through the *identical* code path — the only
/// variable is the backing thread.
///
/// The "Multithreaded rendering" setting writes this default-on key; `false` selects
/// main-thread rendering:
///   defaults write com.loomscreen.pro loomscreen.wallpapers.offMainRender.v1 -bool false
/// (Lite's domain is `com.loomscreen`; `com.livewallpaper` is the Logger subsystem, not a defaults domain.)
enum WPEOffMainRenderFlag {
    static let defaultsKey = "loomscreen.wallpapers.offMainRender.v1"

    /// Read once per display-actor construction. Absent ⇒ true (render-thread).
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    /// Maps the preference through one fail-consistent construction path.
    static var backing: WPEDisplayRenderActor.Backing {
        isEnabled ? .renderThread : .main
    }
}
