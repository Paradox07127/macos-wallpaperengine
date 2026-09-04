#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

/// Scene faces reach CoreText through descriptors, never through the process
/// font catalogue. Registration used to be permanent — nothing in the app ever
/// called `CTFontManagerUnregister*` — so every face any scene touched stayed
/// pinned for the life of the process across wallpaper swaps and reloads.
struct WPETextFontRegistrationTests {
    private static let fontRelativePath = "fonts/scene-face.ttf"

    /// A staging root holding one scene face, the way a session hands the
    /// renderer its assets. Each root is a distinct URL with identical bytes —
    /// that is what a package-backed provider produces per session.
    private struct StagedFace {
        let root: URL
        let fontURL: URL

        func resolver() -> WPEMultiRootResourceResolver {
            WPEMultiRootResourceResolver(primaryRootURL: root, dependencyMounts: [])
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static func systemFaceSource() throws -> URL {
        let candidates = [
            "/System/Library/Fonts/Menlo.ttc",
            "/System/Library/Fonts/Monaco.ttf",
            "/System/Library/Fonts/Geneva.ttf",
            "/System/Library/Fonts/HelveticaNeue.ttc"
        ].map { URL(fileURLWithPath: $0) }
        return try #require(
            candidates.first { FileManager.default.fileExists(atPath: $0.path) },
            "no system face available to stage"
        )
    }

    private static func stageFace() throws -> StagedFace {
        let source = try systemFaceSource()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPEFontReg-\(UUID().uuidString)", isDirectory: true)
        let fontURL = root.appendingPathComponent(fontRelativePath)
        try FileManager.default.createDirectory(
            at: fontURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: fontURL)
        return StagedFace(root: root, fontURL: fontURL)
    }

    /// Glyph ids + advance of a real CoreText line. Dropped glyphs show up as
    /// `.notdef` (0) or as a substituted run, both of which this catches.
    private static func typeset(_ font: CTFont, _ text: String = "Loomscreen 0123") -> (glyphs: [CGGlyph], width: Double) {
        let attributed = NSAttributedString(
            string: text,
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var glyphs: [CGGlyph] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var buffer = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &buffer)
            glyphs.append(contentsOf: buffer)
        }
        return (glyphs, CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private static func sourceURL(of font: CTFont) -> URL? {
        CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL
    }

    @Test("Resolving a scene face leaves the process font catalogue untouched")
    func resolvingSceneFaceRegistersNothing() throws {
        let staged = try Self.stageFace()
        defer { staged.remove() }
        #expect(CTFontManagerGetScopeForURL(staged.fontURL as CFURL) == .none)

        let fonts = WPETextFontResolver(resolver: staged.resolver())
        let font = fonts.font(path: Self.fontRelativePath, size: 48)

        // Without this the scope assertion would also pass for a silent
        // fallback to HelveticaNeue, which registers nothing either.
        #expect(Self.sourceURL(of: font)?.path == staged.fontURL.path)
        #expect(!Self.typeset(font).glyphs.contains(0))
        #expect(CTFontManagerGetScopeForURL(staged.fontURL as CFURL) == .none)
    }

    @Test("One screen tearing down keeps the other screen's identical face typesetting")
    func perScreenTeardownDoesNotDropGlyphsElsewhere() throws {
        let screenA = try Self.stageFace()
        let screenB = try Self.stageFace()
        defer { screenB.remove() }
        let bytesA = try Data(contentsOf: screenA.fontURL)
        let bytesB = try Data(contentsOf: screenB.fontURL)
        #expect(screenA.fontURL.path != screenB.fontURL.path)
        #expect(bytesA == bytesB, "the two screens must stage the SAME face at different URLs")

        var fontsA: WPETextFontResolver? = WPETextFontResolver(resolver: screenA.resolver())
        let fontsB = WPETextFontResolver(resolver: screenB.resolver())
        let renderedA = Self.typeset(try #require(fontsA).font(path: Self.fontRelativePath, size: 48))
        let baselineB = Self.typeset(fontsB.font(path: Self.fontRelativePath, size: 48))
        #expect(renderedA.glyphs == baselineB.glyphs)
        #expect(!baselineB.glyphs.isEmpty)

        // Screen A tears down: resolver released and its staged bytes deleted.
        fontsA = nil
        screenA.remove()
        #expect(!FileManager.default.fileExists(atPath: screenA.fontURL.path))

        // Screen B keeps rendering, from its cached descriptor and from a
        // freshly built one.
        let afterTeardown = Self.typeset(fontsB.font(path: Self.fontRelativePath, size: 48))
        let freshResolver = WPETextFontResolver(resolver: screenB.resolver())
        let freshFont = freshResolver.font(path: Self.fontRelativePath, size: 48)
        #expect(afterTeardown.glyphs == baselineB.glyphs)
        #expect(afterTeardown.width == baselineB.width)
        #expect(Self.typeset(freshFont).glyphs == baselineB.glyphs)
        #expect(Self.sourceURL(of: freshFont)?.path == screenB.fontURL.path)
        #expect(CTFontManagerGetScopeForURL(screenB.fontURL as CFURL) == .none)
    }
}
#endif
