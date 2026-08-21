import XCTest
@testable import LiveWallpaper
import LiveWallpaperCore

final class NowPlayingOptionsTests: XCTestCase {
    private typealias Options = NowPlayingOptions
    private typealias Key = NowPlayingOptions.Key

    // MARK: Defaults

    func testEmptyDictionaryIsAllDefaults() {
        let options = Options([:])
        XCTAssertEqual(options, Options())
        XCTAssertEqual(options.style, .poster)
        XCTAssertEqual(options.accentSource, .albumArt)
        XCTAssertNil(options.customAccentHex)
        XCTAssertEqual(options.opacity, 1.0)
        XCTAssertEqual(options.textBrightness, 1.0)
        XCTAssertNil(options.titleFont)
        XCTAssertNil(options.alignment)
        XCTAssertEqual(options.titleScale, 1.0)
        XCTAssertFalse(options.marquee)
        XCTAssertTrue(options.showArtwork)
        XCTAssertTrue(options.showArtist)
        XCTAssertTrue(options.showAlbum)
        XCTAssertTrue(options.showProgress)
        XCTAssertFalse(options.showLyrics)
        XCTAssertEqual(options.lyricsLines, 3)
        XCTAssertTrue(options.showControls)
        XCTAssertTrue(options.seekOnProgressDrag)
        XCTAssertEqual(options.artworkShape, .rounded)
        XCTAssertEqual(options.artworkShadow, 0.45)
        XCTAssertEqual(options.artworkScale, 1.0)
        XCTAssertTrue(options.audioReactive)
        XCTAssertEqual(options.audioIntensity, 1.0)
        XCTAssertTrue(options.effectPulse)
        XCTAssertFalse(options.effectChromatic)
        XCTAssertFalse(options.effectShake)
        XCTAssertTrue(options.effectParticles)
        XCTAssertFalse(options.effectRipple)
        XCTAssertEqual(options.beatSensitivity, 1.5)
    }

    func testDefaultsWriteNoKeysAtAll() {
        XCTAssertTrue(Options().applied(to: [:]).isEmpty)
    }

    /// Every key must disappear again when its field goes back to the default,
    /// so an untouched layer keeps an empty dictionary on disk.
    func testEveryFieldDropsItsKeyWhenReturnedToDefault() {
        var options = Options()
        options.style = .vinyl
        options.accentSource = .custom
        options.customAccentHex = "#123456"
        options.opacity = 0.4
        options.textBrightness = 0.6
        options.titleFont = .monospaced
        options.alignment = .trailing
        options.titleScale = 1.3
        options.marquee = true
        options.showArtwork = false
        options.showArtist = false
        options.showAlbum = false
        options.showProgress = false
        options.showLyrics = true
        options.lyricsLines = 1
        options.showControls = false
        options.seekOnProgressDrag = false
        options.artworkShape = .circle
        options.artworkShadow = 0.2
        options.artworkScale = 1.5
        options.audioReactive = false
        options.audioIntensity = 1.8
        options.effectPulse = false
        options.effectChromatic = true
        options.effectShake = true
        options.effectParticles = false
        options.effectRipple = true
        options.beatSensitivity = 2.2

        let written = options.applied(to: [:])
        XCTAssertEqual(written.count, 28, "a field stopped persisting: \(written.keys.sorted())")

        XCTAssertTrue(Options().applied(to: written).isEmpty)
    }

    // MARK: Round trip

    func testEveryFieldRoundTrips() {
        var options = Options()
        options.style = .aurora
        options.accentSource = .custom
        options.customAccentHex = "#FF8800"
        options.opacity = 0.35
        options.textBrightness = 0.75
        options.titleFont = .monospaced
        options.alignment = .trailing
        options.titleScale = 1.25
        options.marquee = true
        options.showArtwork = false
        options.showArtist = false
        options.showAlbum = false
        options.showProgress = false
        options.showLyrics = true
        options.lyricsLines = 1
        options.showControls = false
        options.seekOnProgressDrag = false
        options.artworkShape = .square
        options.artworkShadow = 0.8
        options.artworkScale = 0.75
        options.audioReactive = false
        options.audioIntensity = 0.45
        options.effectPulse = false
        options.effectChromatic = true
        options.effectShake = true
        options.effectParticles = false
        options.effectRipple = true
        options.beatSensitivity = 0.9

        XCTAssertEqual(Options(options.applied(to: [:])), options)
    }

    func testAudioFieldsClampAndFallBack() {
        let low = Options([
            Key.audioIntensity: .number(0),
            Key.beatSensitivity: .number(-4),
        ])
        XCTAssertEqual(low.audioIntensity, 0.2)
        XCTAssertEqual(low.beatSensitivity, 0.8)

        let high = Options([
            Key.audioIntensity: .number(50),
            Key.beatSensitivity: .number(9),
        ])
        XCTAssertEqual(high.audioIntensity, 2.0)
        XCTAssertEqual(high.beatSensitivity, 2.5)

        let hostile = Options([
            Key.audioIntensity: .number(.nan),
            Key.beatSensitivity: .string("very sensitive"),
            Key.effectRipple: .number(1),
        ])
        XCTAssertEqual(hostile.audioIntensity, 1.0)
        XCTAssertEqual(hostile.beatSensitivity, 1.5)
        XCTAssertFalse(hostile.effectRipple)
    }

    func testAppliedKeepsForeignKeys() {
        let existing: [String: MonitorWidgetOptionValue] = [
            "maxRows": .number(3),
            "columns": .stringList(["a", "b"]),
        ]
        var options = Options()
        options.opacity = 0.5

        let written = options.applied(to: existing)
        XCTAssertEqual(written["maxRows"]?.numberValue, 3)
        XCTAssertEqual(written["columns"], .stringList(["a", "b"]))
        XCTAssertEqual(written[Key.opacity]?.numberValue, 0.5)
    }

    // MARK: Hostile input

    func testOutOfRangeNumbersAreClamped() {
        let low = Options([
            Key.opacity: .number(-5),
            Key.textBrightness: .number(0),
            Key.titleScale: .number(0.1),
            Key.artworkShadow: .number(-1),
            Key.artworkScale: .number(0),
        ])
        XCTAssertEqual(low.opacity, 0.2)
        XCTAssertEqual(low.textBrightness, 0.5)
        XCTAssertEqual(low.titleScale, 0.7)
        XCTAssertEqual(low.artworkShadow, 0)
        XCTAssertEqual(low.artworkScale, 0.6)

        let high = Options([
            Key.opacity: .number(99),
            Key.textBrightness: .number(4),
            Key.titleScale: .number(1_000),
            Key.artworkShadow: .number(7),
            Key.artworkScale: .number(12),
        ])
        XCTAssertEqual(high.opacity, 1.0)
        XCTAssertEqual(high.textBrightness, 1.0)
        XCTAssertEqual(high.titleScale, 1.4)
        XCTAssertEqual(high.artworkShadow, 1.0)
        XCTAssertEqual(high.artworkScale, 1.6)
    }

    /// Programmatic writes are clamped on the way out too, so nothing
    /// out-of-range ever reaches the file. A value that clamps onto the
    /// default still drops its key — the two rules compose.
    func testAppliedClampsOutOfRangeFields() {
        var options = Options()
        options.opacity = -3
        options.artworkScale = 9
        options.titleScale = 5
        let written = options.applied(to: [:])
        XCTAssertEqual(written[Key.opacity]?.numberValue, 0.2)
        XCTAssertEqual(written[Key.artworkScale]?.numberValue, 1.6)
        XCTAssertEqual(written[Key.titleScale]?.numberValue, 1.4)

        var toDefault = Options()
        toDefault.opacity = 4  // clamps to 1.0, which is the default
        XCTAssertNil(toDefault.applied(to: [:])[Key.opacity])
    }

    func testNonFiniteNumbersFallBackToDefaults() {
        let options = Options([
            Key.opacity: .number(.nan),
            Key.titleScale: .number(.infinity),
            Key.artworkScale: .number(-.infinity),
        ])
        XCTAssertEqual(options.opacity, 1.0)
        XCTAssertEqual(options.titleScale, 1.0)
        XCTAssertEqual(options.artworkScale, 1.0)
    }

    func testWrongValueTypesFallBackToDefaults() {
        let options = Options([
            Key.style: .number(3),
            Key.opacity: .string("very transparent"),
            Key.marquee: .string("yes"),
            Key.showArtwork: .number(0),
            Key.titleScale: .stringList(["1.2"]),
            Key.artworkShape: .bool(true),
            Key.alignment: .number(1),
        ])
        XCTAssertEqual(options.style, .poster)
        XCTAssertEqual(options.opacity, 1.0)
        XCTAssertFalse(options.marquee)
        XCTAssertTrue(options.showArtwork)
        XCTAssertEqual(options.titleScale, 1.0)
        XCTAssertEqual(options.artworkShape, .rounded)
        XCTAssertNil(options.alignment)
    }

    func testUnknownEnumCasesFallBackToDefaults() {
        let options = Options([
            Key.style: .string("hologram"),
            Key.accentSource: .string("mood"),
            Key.titleFont: .string("comic"),
            Key.alignment: .string("justified"),
            Key.artworkShape: .string("hexagon"),
        ])
        XCTAssertEqual(options.style, .poster)
        XCTAssertEqual(options.accentSource, .albumArt)
        XCTAssertNil(options.titleFont)
        XCTAssertNil(options.alignment)
        XCTAssertEqual(options.artworkShape, .rounded)
    }

    /// Only 1 and 3 are drawable; anything else on disk must read as the
    /// default rather than reaching the view as an unsupported row count.
    func testLyricsLinesSnapToAPublishedChoice() {
        XCTAssertEqual(Options([Key.lyricsLines: .number(1)]).lyricsLines, 1)
        XCTAssertEqual(Options([Key.lyricsLines: .number(3)]).lyricsLines, 3)
        XCTAssertEqual(Options([Key.lyricsLines: .number(2)]).lyricsLines, 3)
        XCTAssertEqual(Options([Key.lyricsLines: .number(0)]).lyricsLines, 3)
        XCTAssertEqual(Options([Key.lyricsLines: .number(.nan)]).lyricsLines, 3)
        XCTAssertEqual(Options([Key.lyricsLines: .string("three")]).lyricsLines, 3)

        var written = Options()
        written.lyricsLines = 2
        XCTAssertNil(written.applied(to: [:])[Key.lyricsLines])
    }

    // MARK: Style-dependent defaults

    func testDefaultAlignmentPerStyle() {
        XCTAssertEqual(Options.defaultAlignment(for: .poster), .leading)
        XCTAssertEqual(Options.defaultAlignment(for: .vinyl), .leading)
        XCTAssertEqual(Options.defaultAlignment(for: .aurora), .center)
    }

    func testDefaultTitleFontPerStyle() {
        XCTAssertEqual(Options.defaultTitleFont(for: .poster), .serif)
        XCTAssertEqual(Options.defaultTitleFont(for: .vinyl), .rounded)
        XCTAssertEqual(Options.defaultTitleFont(for: .aurora), .rounded)
    }

    /// Picking the value a style already uses stores nothing, so a later style
    /// change is still free to follow its own default.
    func testStyleDefaultChoicesDropTheirKeys() {
        var aurora = Options()
        aurora.style = .aurora
        aurora.alignment = .center
        aurora.titleFont = .rounded
        let written = aurora.applied(to: [:])
        XCTAssertNil(written[Key.alignment])
        XCTAssertNil(written[Key.titleFont])
        XCTAssertEqual(Options(written).resolvedAlignment, .center)

        var poster = Options()
        poster.alignment = .center
        XCTAssertEqual(poster.applied(to: [:])[Key.alignment]?.stringValue, "center")
    }

    // MARK: Hex parsing

    func testHexParsing() {
        let expected = NowPlayingAccentColor(red: 1, green: 136.0 / 255, blue: 0)
        XCTAssertEqual(Options.accentColor(fromHex: "#FF8800"), expected)
        XCTAssertEqual(Options.accentColor(fromHex: "ff8800"), expected)
        XCTAssertEqual(Options.accentColor(fromHex: "  #Ff8800 "), expected)

        XCTAssertNil(Options.accentColor(fromHex: ""))
        XCTAssertNil(Options.accentColor(fromHex: "#"))
        XCTAssertNil(Options.accentColor(fromHex: "#FF88"))
        XCTAssertNil(Options.accentColor(fromHex: "#FF88000"))
        XCTAssertNil(Options.accentColor(fromHex: "zzzzzz"))
        XCTAssertNil(Options.accentColor(fromHex: "#-F8800"))
        XCTAssertNil(Options.accentColor(fromHex: "rebeccapurple"))
    }

    func testHexIsCanonicalizedOnParseAndUnparseableHexIsDropped() {
        XCTAssertEqual(Options([Key.customAccentHex: .string("ff8800")]).customAccentHex, "#FF8800")
        XCTAssertNil(Options([Key.customAccentHex: .string("nope")]).customAccentHex)

        var options = Options()
        options.customAccentHex = "not a color"
        XCTAssertNil(options.applied(to: [:])[Key.customAccentHex])
    }

    func testHexStringRoundTripsThroughEveryChannel() throws {
        let color = NowPlayingAccentColor(red: 0.1, green: 0.5, blue: 0.9)
        let parsed = try XCTUnwrap(Options.accentColor(fromHex: Options.hexString(for: color)))
        XCTAssertEqual(parsed.red, color.red, accuracy: 1.0 / 255)
        XCTAssertEqual(parsed.green, color.green, accuracy: 1.0 / 255)
        XCTAssertEqual(parsed.blue, color.blue, accuracy: 1.0 / 255)
    }

    // MARK: Accent fallback chain

    func testAccentPrefersACustomColorOnlyWhenAskedAndParseable() {
        let cover = NowPlayingAccentColor(red: 0.2, green: 0.4, blue: 0.6)
        let custom = NowPlayingAccentColor(red: 1, green: 136.0 / 255, blue: 0)

        var options = Options()
        options.accentSource = .custom
        options.customAccentHex = "#FF8800"
        XCTAssertEqual(Options.resolvedAccent(options: options, artwork: cover), custom)
        XCTAssertEqual(Options.resolvedAccent(options: options, artwork: nil), custom)

        // Source says album art: the stored custom color is remembered, not used.
        options.accentSource = .albumArt
        XCTAssertEqual(Options.resolvedAccent(options: options, artwork: cover), cover)

        // Custom asked for but unusable → cover, then nothing (caller's own tint).
        options.accentSource = .custom
        options.customAccentHex = "garbage"
        XCTAssertEqual(Options.resolvedAccent(options: options, artwork: cover), cover)
        XCTAssertNil(Options.resolvedAccent(options: options, artwork: nil))
    }
}
