#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Storage filter: app-managed cache copy (the usual shape for SteamCMD- downloaded scenes) vs a link to the user's own folder (manual imports + unpackaged downloads).
enum InstalledStorageKind: String, CaseIterable, Identifiable {
    case managed, linked

    var id: Self { self }

    var title: String {
        switch self {
        case .managed: return String(localized: "App copy", bundle: .appLanguage, comment: "Installed library storage filter: extracted into the app's managed cache.")
        case .linked: return String(localized: "Linked folder", bundle: .appLanguage, comment: "Installed library storage filter: links to the user's own folder.")
        }
    }

    func matches(_ entry: WPEHistoryEntry) -> Bool {
        let managed = entry.origin.resourceLocation == .cache
        return self == .managed ? managed : !managed
    }
}

#endif
