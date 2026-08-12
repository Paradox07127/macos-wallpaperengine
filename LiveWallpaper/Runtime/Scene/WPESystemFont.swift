#if !LITE_BUILD
import CoreGraphics
import CoreText

/// Map `systemfont_<family>` to the OS font by name (not an asset path — avoids phantom fileMissing).
enum WPESystemFont {
    private static let prefix = "systemfont_"

    static func isReference(_ path: String) -> Bool { path.hasPrefix(prefix) }

    /// `systemfont_arial` → `Arial` (case-insensitive; unknown → system default).
    static func familyName(for path: String) -> String {
        path.dropFirst(prefix.count)
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func font(for path: String, size: CGFloat) -> CTFont {
        CTFontCreateWithName(familyName(for: path) as CFString, size, nil)
    }
}
#endif
