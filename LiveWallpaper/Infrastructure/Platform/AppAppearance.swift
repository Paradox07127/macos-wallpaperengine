import AppKit
import Foundation

/// App-wide window appearance override. The palette is built on dynamic `NSColor`s, so `.system` is the state the app was designed in and needs no override at all — `NSApp.appearance = nil` hands the decision back to macOS; the other two pin every window regardless of the system setting.
/// This does NOT reach the wallpaper-level surfaces: the monitor board chrome, the widget settings card and the media-preview scrims are deliberately fixed dark (see `DesignTokens.Colors.BoardChrome`) because they float over the user's own wallpaper, where "follow the system" would turn them white over a light picture — an appearance override is about app windows, not that layer.
enum AppAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    static let defaultsKey = "Appearance.Preference.v1"

    /// Unknown/legacy stored values fall back to `.system` rather than pinning a
    /// mode the user never picked.
    static func stored(in defaults: UserDefaults) -> AppAppearance {
        defaults.string(forKey: defaultsKey).flatMap(AppAppearance.init(rawValue:)) ?? .system
    }

    /// nil = no override, which is the only way to keep tracking the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    @MainActor
    func apply(to application: NSApplication = .shared) {
        application.appearance = appearanceName.flatMap(NSAppearance.init(named:))
    }
}
