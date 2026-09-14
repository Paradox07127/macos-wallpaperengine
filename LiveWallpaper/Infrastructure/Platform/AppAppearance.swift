import AppKit
import Foundation

/// `.system` is `NSApp.appearance = nil`. This does not reach wallpaper-level surfaces (see `DesignTokens.Colors.BoardChrome`).
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
