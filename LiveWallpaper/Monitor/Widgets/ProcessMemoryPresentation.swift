import Foundation
import LiveWallpaperCore

enum ProcessMemoryPresentation {
    static func metricText(_ metric: String?) -> String {
        let key: String.LocalizationValue = switch metric {
        case "footprint": "Physical footprint (process group)"
        case "resident": "Resident memory (RSS fallback)"
        case "mixed": "Mixed footprint and RSS (process group)"
        default: "Memory metric unavailable"
        }
        return String(localized: key, bundle: .appLanguage)
    }
}
