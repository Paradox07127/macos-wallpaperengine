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

    /// Descriptors carry the file URL, so `CTFontCreateWithFontDescriptor` loads
    /// the face straight off disk — no `CTFontManagerRegisterFontsForURL`. We
    /// never look scene faces up by name, and the header states registration is
    /// what makes a face "participate in font descriptor matching", which is
    /// exactly the capability we don't use. Registering instead pinned every
    /// face a scene ever touched in the process font catalogue for the life of
    /// the process, and nothing here ever unregistered them.
    private func fontDescriptor(forPath path: String) -> CTFontDescriptor? {
        if let cached = descriptorCache[path] { return cached }
        guard let url = try? resolver.resolveExistingFileURL(relativePath: path),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first else { return nil }
        descriptorCache[path] = descriptor
        return descriptor
    }
}

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
