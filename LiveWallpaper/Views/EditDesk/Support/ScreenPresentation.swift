import AppKit
import Foundation
import IOKit
import LiveWallpaperCore

enum DisplayKind: Equatable {
    case macBookPro
    case macBookAir
    case builtinOther
    case studioDisplay
    case proDisplayXDR
    case external
}

/// Pure presentation helpers for the Edit Desk stage's display badge and name row
/// (design handoff SCREENS.md S1: "类型角标" / "名称行").
enum ScreenPresentation {
    /// Verbatim glyphs, not translated — same rule as `VideoFormatBadge.displayLabel`.
    static func badgeText(kind: DisplayKind, diagonalInches: Double?, refreshRate: Int) -> String {
        var segments = [prefix(for: kind)]
        if let diagonalInches {
            segments.append("\(Int(diagonalInches.rounded()))″")
        }
        segments.append("\(refreshRate) Hz")
        return segments.joined(separator: " · ")
    }

    static func statusText(pointSize: CGSize, isMain: Bool) -> String {
        let resolution = "\(Int(pointSize.width.rounded()))×\(Int(pointSize.height.rounded()))"
        guard isMain else { return resolution }
        let mainLabel = String(
            localized: "Main", bundle: .appLanguage,
            comment: "Short status suffix marking the main display on the Edit Desk stage."
        )
        return resolution + " · " + mainLabel
    }

    /// `productName` is the IORegistry marketing name ("MacBook Pro") when available; Apple
    /// Silicon model identifiers (Mac14,7, Mac15,12…) carry no MacBookPro/MacBookAir prefix,
    /// so the raw `hw.model` prefix only classifies Intel-era fallbacks.
    static func kind(isBuiltin: Bool, localizedName: String, productName: String) -> DisplayKind {
        if isBuiltin {
            let lowered = productName.lowercased()
            if lowered.contains("macbook pro") || productName.hasPrefix("MacBookPro") {
                return .macBookPro
            }
            if lowered.contains("macbook air") || productName.hasPrefix("MacBookAir") {
                return .macBookAir
            }
            return .builtinOther
        }
        let lowered = localizedName.lowercased()
        if lowered.contains("studio display") {
            return .studioDisplay
        }
        if lowered.contains("pro display xdr") {
            return .proDisplayXDR
        }
        return .external
    }

    private static func prefix(for kind: DisplayKind) -> String {
        switch kind {
        case .macBookPro: "MACBOOK PRO"
        case .macBookAir: "MACBOOK AIR"
        case .builtinOther: "BUILT-IN"
        case .studioDisplay: "STUDIO DISPLAY"
        case .proDisplayXDR: "PRO DISPLAY XDR"
        case .external: "EXTERNAL"
        }
    }

    /// Reads live AppKit/CoreGraphics state; the functions above are what the tests exercise.
    @MainActor
    static func presentation(for screen: Screen, refreshRate: Int) -> (badge: String, status: String) {
        var productName = ioPlatformProductName()
        if productName.isEmpty {
            productName = hardwareModelIdentifier()
        }
        let displayKind = kind(
            isBuiltin: CGDisplayIsBuiltin(screen.id) != 0,
            localizedName: screen.nsScreen.localizedName,
            productName: productName
        )
        let badge = badgeText(kind: displayKind, diagonalInches: screen.diagonalInches, refreshRate: refreshRate)
        let status = statusText(pointSize: screen.frame.size, isMain: CGDisplayIsMain(screen.id) != 0)
        return (badge, status)
    }

    /// `product-name` is the marketing name ("MacBook Pro"); absent on older Intel Macs,
    /// which fall back to `hardwareModelIdentifier()`.
    private static func ioPlatformProductName() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "product-name" as CFString, kCFAllocatorDefault, 0),
              let data = property.takeRetainedValue() as? Data else {
            return ""
        }
        return String(bytes: data.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
    }

    private static func hardwareModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(bytes: buffer.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
    }
}
