import CFreeType
import CoreText
import Foundation

/// Font files and faces for parity text, cached so the bytes outlive their faces and each face loads once.
/// Holds FreeType objects: not thread-safe, one owner at a time.
public final class WPEParityFontLibrary {
    private let loader: WPEParityFontLoader
    private struct ChainKey: Hashable {
        let fontPath: String
        let pointSizeBits: UInt32
    }

    private var chains: [ChainKey: WPEParityFontChain] = [:]

    public init(assets: WPEParityProgramAssets) {
        loader = WPEParityFontLoader(assets: assets)
    }

    /// WPE clamps the point size to [1, 256] before loading (1401b0410.c:228-237).
    public static func clampedPointSize(_ pointSize: Float) -> Float {
        var clamped = pointSize
        if clamped >= 256 {
            clamped = 256
        }
        if clamped < 1 {
            clamped = 1
        }
        return clamped
    }

    /// AD400 keys the chain record by Float size in both modes; the bitmap atlas's string key is separate.
    public func chain(fontPath: String, pointSize: Float) -> WPEParityFontChain {
        let clamped = Self.clampedPointSize(pointSize)
        if !clamped.isFinite {
            // Preserve the former conversion failure for invalid input; this is not a NaN fallback policy.
            _ = Int64(clamped * 64)
        }
        let key = ChainKey(fontPath: fontPath, pointSizeBits: clamped.bitPattern)
        if let cached = chains[key] {
            return cached
        }
        let chain = WPEParityFontChain(loader: loader, fontPath: fontPath, pointSize: clamped)
        chains[key] = chain
        return chain
    }
}

/// The primary face followed by the fallback faces appended while laying out text (1401ad670.c:72-199).
public final class WPEParityFontChain {
    /// WPE tries at most eight fallback fonts per chain; its fifth is the assets' Twemoji.
    private static let fallbackAttemptLimit = 8
    private static let twemojiAttempt = 4
    private static let twemojiPath = "fonts/TwemojiMozilla.ttf"

    public private(set) var faces: [WPEParityFontFace] = []
    public let pointSize: Float
    private let loader: WPEParityFontLoader
    private var cascadeBase: CTFont?
    private var fallbackAttempts = 0

    init(loader: WPEParityFontLoader, fontPath: String, pointSize: Float) {
        self.loader = loader
        self.pointSize = pointSize
        if WPEParityFontLoader.isSystemFont(fontPath) {
            appendSystemFont(named: WPEParityFontLoader.systemFamilyName(fontPath))
        } else if let face = loader.assetFace(path: fontPath, pointSize: pointSize) {
            faces.append(face)
        }
        if faces.isEmpty {
            appendSystemFont(named: WPEParityFontLoader.systemFamilyName("systemfont_arial"))
        }
    }

    /// The first face in the chain that maps `scalar`, appending fallback faces until one does or the attempts run out.
    func faceIndex(containing scalar: UInt32) -> Int? {
        if let index = faces.firstIndex(where: { $0.hasCharacter(scalar) }) {
            return index
        }
        while fallbackAttempts < Self.fallbackAttemptLimit {
            let attempt = fallbackAttempts
            fallbackAttempts += 1
            guard let face = fallbackFace(attempt: attempt, for: scalar), !faces.contains(where: { $0 === face })
            else { continue }
            faces.append(face)
            if face.hasCharacter(scalar) {
                return faces.count - 1
            }
        }
        return nil
    }

    private func appendSystemFont(named family: String) {
        let font = CTFontCreateWithName(family as CFString, CGFloat(pointSize * 300 / 72), nil)
        guard let face = loader.face(for: font, pointSize: pointSize) else { return }
        faces.append(face)
        cascadeBase = font
    }

    /// Windows fonts stand in WPE's table; on macOS CoreText's cascade font for the character takes those slots.
    private func fallbackFace(attempt: Int, for scalar: UInt32) -> WPEParityFontFace? {
        if attempt == Self.twemojiAttempt {
            return loader.assetFace(path: Self.twemojiPath, pointSize: pointSize)
        }
        guard let base = primaryCoreTextFont(), let character = Unicode.Scalar(scalar) else { return nil }
        let string = String(character)
        let font = CTFontCreateForString(base, string as CFString, CFRange(location: 0, length: string.utf16.count))
        // LastResort maps every code point to a placeholder; WPE's Windows fonts have no such face.
        guard CTFontCopyPostScriptName(font) as String != "LastResort" else { return nil }
        return loader.face(for: font, pointSize: pointSize)
    }

    private func primaryCoreTextFont() -> CTFont? {
        if let cascadeBase {
            return cascadeBase
        }
        guard let buffer = faces.first?.bytes?.buffer, let base = buffer.baseAddress,
              let descriptor = CTFontManagerCreateFontDescriptorFromData(
                  Data(bytesNoCopy: base, count: buffer.count, deallocator: .none) as CFData
              )
        else { return nil }
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(pointSize * 300 / 72), nil)
        cascadeBase = font
        return font
    }
}

/// Reads font files (scene assets through `WPEParityProgramAssets`, system fonts by URL) and caches bytes and faces.
final class WPEParityFontLoader {
    private static let systemFontPrefix = "systemfont_"

    private let library = WPEParityFreeTypeLibrary()
    private let assets: WPEParityProgramAssets
    /// Scene and assets font bytes; system fonts are read by FreeType from their files.
    private var files: [String: WPEParityFontBytes] = [:]
    private var faces: [String: WPEParityFontFace] = [:]

    init(assets: WPEParityProgramAssets) {
        self.assets = assets
    }

    static func isSystemFont(_ path: String) -> Bool {
        path.hasPrefix(systemFontPrefix)
    }

    /// The old renderer's mapping (WPESystemFont.familyName): `systemfont_arial` → "Arial".
    static func systemFamilyName(_ path: String) -> String {
        path.dropFirst(systemFontPrefix.count)
            .split(separator: "_")
            .map(\.capitalized)
            .joined(separator: " ")
    }

    func assetFace(path: String, pointSize: Float) -> WPEParityFontFace? {
        let source = "asset:" + path
        return face(source: source, faceIndex: 0, pointSize: pointSize, path: nil) {
            bytes(source: source) { assets.data(path) }
        }
    }

    /// The face CoreText draws `font` with: its file, and in a collection the face with the same PostScript name.
    func face(for font: CTFont, pointSize: Float) -> WPEParityFontFace? {
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return nil }
        let index = faceIndex(path: url.path, postScriptName: CTFontCopyPostScriptName(font) as String)
        return face(source: "file:" + url.path, faceIndex: index, pointSize: pointSize, path: url.path) { nil }
    }

    private func face(
        source: String,
        faceIndex: Int,
        pointSize: Float,
        path: String?,
        bytes: () -> WPEParityFontBytes?
    ) -> WPEParityFontFace? {
        let key = "\(source)#\(faceIndex)@\(Int64(pointSize * 64))"
        if let cached = faces[key] {
            return cached
        }
        let loaded = bytes()
        guard let library, loaded != nil || path != nil,
              let face = WPEParityFontFace(
                  library: library,
                  bytes: loaded,
                  path: path,
                  source: source,
                  faceIndex: faceIndex,
                  pointSize: pointSize
              )
        else { return nil }
        faces[key] = face
        return face
    }

    private func bytes(source: String, read: () -> Data?) -> WPEParityFontBytes? {
        if let cached = files[source] {
            return cached
        }
        guard let data = read() else { return nil }
        let bytes = WPEParityFontBytes(data)
        files[source] = bytes
        return bytes
    }

    private func faceIndex(path: String, postScriptName: String) -> Int {
        guard let library else { return 0 }
        var faceCount = 1
        var index = 0
        while index < faceCount {
            guard let face = WPEParityFontFace.open(library, bytes: nil, path: path, index: index) else { return 0 }
            faceCount = face.pointee.num_faces
            let name = FT_Get_Postscript_Name(face).map { String(cString: $0) }
            FT_Done_Face(face)
            if name == postScriptName {
                return index
            }
            index += 1
        }
        return 0
    }
}
