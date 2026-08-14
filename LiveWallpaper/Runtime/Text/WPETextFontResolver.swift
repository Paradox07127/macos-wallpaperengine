#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE

/// Resolves a text object's typeface once per scene. Shared by the layout pass
/// (which computes exact block/surface extents) and the coverage-atlas mesh
/// builder so both see the SAME font — a mismatch would place glyphs using one
/// typeface's metrics and rasterize another.
/// Not `@MainActor`: lives inside the renderer's actor isolation.
final class WPETextFontResolver {
    private let resolver: WPEMultiRootResourceResolver
    private var descriptorCache: [String: CTFontDescriptor] = [:]
    private var registeredFonts: Set<String> = []

    init(resolver: WPEMultiRootResourceResolver) {
        self.resolver = resolver
    }

    /// The object's font at its em pixel size (`pointsize × 300/72`).
    func font(for object: WPESceneTextObject) -> CTFont {
        let em = max(object.pointSize, 1) * WPETextLayoutEngine.pixelsPerPoint
        return font(path: object.fontRelativePath, size: CGFloat(em))
    }

    func font(path: String?, size: CGFloat) -> CTFont {
        if let path {
            if WPESystemFont.isReference(path) {
                return WPESystemFont.font(for: path, size: size)
            }
            if let descriptor = fontDescriptor(forPath: path) {
                return CTFontCreateWithFontDescriptor(descriptor, size, nil)
            }
        }
        return CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }

    private func fontDescriptor(forPath path: String) -> CTFontDescriptor? {
        if let cached = descriptorCache[path] { return cached }
        registerFontIfNeeded(path)
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }
        descriptorCache[path] = descriptor
        return descriptor
    }

    private func registerFontIfNeeded(_ path: String) {
        guard !WPESystemFont.isReference(path), !registeredFonts.contains(path) else { return }
        registeredFonts.insert(path)
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path) else { return }
        var unmanagedError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &unmanagedError)
        unmanagedError?.release()
    }
}

// Merged from WPESystemFont.swift: single consumer, no independent test surface.
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
