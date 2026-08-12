#if !LITE_BUILD
import CoreText
import Foundation
import Testing
@testable import LiveWallpaper

/// Stress the `maxRows` clamp with the text shapes a live "now playing" layer
/// actually feeds it. Scene 3151551777 has 16 text objects at
/// `limitrows/maxrows 1/limituseellipsis`, and its song title changes at runtime —
/// so every track change re-enters this path with arbitrary user content.
struct WPETextRowClampStressTests {

    private let font = CTFontCreateWithName("HelveticaNeue" as CFString, 48, nil)

    /// Song titles are user content: emoji (surrogate pairs), combining marks,
    /// CJK, RTL, and strings far longer than the box. A clamp that slices by
    /// UTF-16 offset can land inside a grapheme on any of these.
    private static let titles = [
        "Hello world",
        String(repeating: "A very long English song title ", count: 12),
        "夜に駆ける／YOASOBI ── 命に嫌われている（フルバージョン）",
        "🎵🎶🎧🥁🎸🎹🎺🎻🪕🪗 emoji only title 🎼🎤🎷",
        "Ω̸̢̛͈̥͇͔̈́̽ ç̶̡̛̭̈́ơ̷̪̈m̶̰̈b̴̜̽ḯ̸̬n̷̰̈i̶̪͐n̸̥̈g̷̱̈ ̶̭̈m̴̰̽a̷̜̽r̶̬̈k̸̰̈s̷̪̈",
        "مرحبا بالعالم هذا عنوان أغنية طويل جدا للاختبار",
        "  \n\t  ",
        "",
        "𝄞𝄢𝅘𝅥𝅮 surrogate-pair musical symbols 𝅗𝅥𝅘𝅥𝅯",
        "A",
    ]

    @Test("Row clamp survives arbitrary song titles at maxrows 1 + ellipsis")
    func clampSurvivesArbitraryTitles() {
        // Exactly scene 3151551777's authored settings.
        for title in Self.titles {
            let layout = WPETextLayoutEngine.layout(
                text: title, font: font, maxWidth: 1000, maxRows: 1, ellipsis: true
            )
            #expect((layout?.lineCount ?? 0) <= 1)
        }
        // Narrow box: forces the break inside the first glyph cluster.
        for title in Self.titles {
            let layout = WPETextLayoutEngine.layout(
                text: title, font: font, maxWidth: 8, maxRows: 1, ellipsis: true
            )
            #expect((layout?.lineCount ?? 0) <= 1)
        }
        // maxRows set with NO width cap — the clamp then breaks at an effectively
        // infinite width, which must not wedge or overflow.
        for title in Self.titles {
            let layout = WPETextLayoutEngine.layout(
                text: title, font: font, maxWidth: nil, maxRows: 2, ellipsis: true
            )
            #expect((layout?.lineCount ?? 0) <= 2)
        }
    }

    @Test("Row clamp caps the line count; no clamp keeps wrapping")
    func rowClampCapsLineCount() throws {
        let long = String(repeating: "long title ", count: 20)
        let oneRow = try #require(WPETextLayoutEngine.layout(
            text: long, font: font, maxWidth: 300, maxRows: 1, ellipsis: true
        ))
        #expect(oneRow.lineCount == 1)
        let fourRows = try #require(WPETextLayoutEngine.layout(
            text: long, font: font, maxWidth: 300, maxRows: 4, ellipsis: true
        ))
        #expect(fourRows.lineCount == 4)
        let unclamped = try #require(WPETextLayoutEngine.layout(
            text: long, font: font, maxWidth: 300
        ))
        #expect(unclamped.lineCount > 4)
    }
}
#endif
