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
        precondition(clamped.isFinite, "Font size must resolve to a finite value")
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
    private enum FallbackSlot {
        case system(String, excluding: [ClosedRange<UInt32>] = [])
        case asset(String)
    }

    private static let twemojiPath = "fonts/TwemojiMozilla.ttf"
    /// Apple Symbols maps the ideographic space and full-width forms; Windows draws them from msyh, the next slot.
    private static let fullWidthForms: [ClosedRange<UInt32>] = [0x3000 ... 0x3000, 0xFF00 ... 0xFFEF]
    /// WPE's table 0x140484c40 with macOS stand-ins: arial, seguiemj, arialuni, segoeui, fonts/TwemojiMozilla.ttf,
    /// seguisym, msyh, Malgun. nil = no stand-in; the slot is still spent.
    private static let fallbackSlots: [FallbackSlot?] = [
        .system("Arial"), .asset(twemojiPath), nil, .system("Helvetica Neue"),
        .asset(twemojiPath), .system("Apple Symbols", excluding: fullWidthForms), .system("PingFang SC"),
        .system("Apple SD Gothic Neo"),
    ]

    public private(set) var faces: [WPEParityFontFace] = []
    public let pointSize: Float
    private let loader: WPEParityFontLoader
    /// Slots of `fallbackSlots` already spent; WPE counts them per chain, not per character.
    private var fallbackAttempts = 0
    /// Scalars a stand-in face must not take, by index in `faces`; kept per chain because faces are shared.
    private var excludedScalars: [Int: [ClosedRange<UInt32>]] = [:]

    init(loader: WPEParityFontLoader, fontPath: String, pointSize: Float) {
        self.loader = loader
        self.pointSize = pointSize
        if let families = WPEParityFontLoader.systemFontFamilies[fontPath] {
            appendSystemFont(families)
        } else if let face = loader.assetFace(path: fontPath, pointSize: pointSize) {
            faces.append(face)
        }
        if faces.isEmpty {
            appendSystemFont(["Arial"])
        }
    }

    /// The first face in the chain that maps `scalar`, appending fallback faces until one does or the attempts run out.
    func faceIndex(containing scalar: UInt32) -> Int? {
        if let index = faces.indices.first(where: { maps($0, scalar) }) {
            return index
        }
        while fallbackAttempts < Self.fallbackSlots.count {
            let slot = Self.fallbackSlots[fallbackAttempts]
            fallbackAttempts += 1
            guard let face = slot.flatMap(fallbackFace), !faces.contains(where: { $0 === face }) else { continue }
            faces.append(face)
            if case let .system(_, excluding)? = slot, !excluding.isEmpty {
                excludedScalars[faces.count - 1] = excluding
            }
            if maps(faces.count - 1, scalar) {
                return faces.count - 1
            }
        }
        return nil
    }

    private func maps(_ index: Int, _ scalar: UInt32) -> Bool {
        faces[index].hasCharacter(scalar) && !(excludedScalars[index] ?? []).contains { $0.contains(scalar) }
    }

    private func appendSystemFont(_ families: [String]) {
        for family in families {
            if let face = loader.systemFace(family: family, pointSize: pointSize) {
                faces.append(face)
                return
            }
        }
    }

    private func fallbackFace(_ slot: FallbackSlot) -> WPEParityFontFace? {
        switch slot {
        case let .system(family, _): loader.systemFace(family: family, pointSize: pointSize)
        case let .asset(path): loader.assetFace(path: path, pointSize: pointSize)
        }
    }
}

/// Reads font files (scene assets through `WPEParityProgramAssets`, system fonts by URL) and caches bytes and faces.
final class WPEParityFontLoader {
    /// WPE's eight system fonts by exact name (140256f20.c:129-198), as macOS families in preference order.
    /// Other `systemfont_*` strings are asset paths (1401b0410.c:248-255).
    static let systemFontFamilies: [String: [String]] = [
        "systemfont_arial": ["Arial"],
        "systemfont_calibri": ["Calibri", "Helvetica Neue"],
        "systemfont_cambria": ["Cambria", "Georgia"],
        "systemfont_comicsans": ["Comic Sans MS"],
        "systemfont_consolas": ["Consolas", "Menlo"],
        "systemfont_sansserif": ["Microsoft Sans Serif"],
        "systemfont_segoe": ["Segoe UI", "Helvetica Neue"],
        "systemfont_verdana": ["Verdana"],
    ]

    private let library = WPEParityFreeTypeLibrary()
    private let assets: WPEParityProgramAssets
    /// Scene and assets font bytes; system fonts are read by FreeType from their files.
    private var files: [String: WPEParityFontBytes] = [:]
    private var faces: [String: WPEParityFontFace] = [:]

    init(assets: WPEParityProgramAssets) {
        self.assets = assets
    }

    /// nil when `family` is not installed: CoreText then substitutes another family, which WPE never does.
    func systemFace(family: String, pointSize: Float) -> WPEParityFontFace? {
        // A family descriptor, not CTFontCreateWithName: by name "PingFang SC" resolves to the reserved
        // PingFangUI.ttc, from which no face loads here, instead of PingFang.ttc.
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, CGFloat(pointSize * 300 / 72), nil)
        guard CTFontCopyFamilyName(font) as String == family else { return nil }
        return face(for: font, pointSize: pointSize)
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
