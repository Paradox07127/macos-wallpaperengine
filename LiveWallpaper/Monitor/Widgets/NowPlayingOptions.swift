import Foundation
import LiveWallpaperCore
import SwiftUI

// MARK: - Typed view of the Now Playing placement options

/// Everything the user can dial on the Now Playing layer, parsed out of the
/// placement's untyped `options` dictionary.
///
/// Contract, both directions:
/// * `init(_:)` never fails and never traps — a missing key, a wrong case, a
///   string where a number belongs, or NaN all fall back to the default, and
///   numbers are clamped into their published range on the way in.
/// * `applied(to:)` writes back onto the dictionary it is given, so options
///   belonging to other widgets (or to a later version of this one) survive,
///   and drops every key that is back at its default so untouched layers keep
///   an empty dictionary on disk.
struct NowPlayingOptions: Equatable, Sendable {
    typealias Style = NowPlayingWidgetView.Style

    enum AccentSource: String, CaseIterable, Sendable {
        case albumArt, custom
    }

    enum TitleFont: String, CaseIterable, Sendable {
        case serif, rounded, monospaced, system

        var design: Font.Design {
            switch self {
            case .serif: .serif
            case .rounded: .rounded
            case .monospaced: .monospaced
            case .system: .default
            }
        }
    }

    enum Alignment: String, CaseIterable, Sendable {
        case leading, center, trailing

        var horizontal: HorizontalAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var text: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        /// Where the type block parks inside the tile, bottom-anchored (poster).
        var bottomFrame: SwiftUI.Alignment {
            switch self {
            case .leading: .bottomLeading
            case .center: .bottom
            case .trailing: .bottomTrailing
            }
        }

        /// Where the whole row parks inside the tile (vinyl).
        var frame: SwiftUI.Alignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    enum ArtworkShape: String, CaseIterable, Sendable {
        case rounded, circle, square
    }

    /// Persisted key names. `style` predates this struct and keeps its spelling
    /// so already-saved layers keep their look.
    enum Key {
        static let style = "style"
        static let accentSource = "accentSource"
        static let customAccentHex = "accentHex"
        static let opacity = "opacity"
        static let textBrightness = "textBrightness"
        static let titleFont = "titleFont"
        static let alignment = "alignment"
        static let titleScale = "titleScale"
        static let marquee = "marquee"
        static let showArtwork = "showArtwork"
        static let showArtist = "showArtist"
        static let showAlbum = "showAlbum"
        static let showProgress = "showProgress"
        static let showLyrics = "showLyrics"
        static let lyricsLines = "lyricsLines"
        static let showControls = "showControls"
        static let seekOnProgressDrag = "seekOnProgressDrag"
        static let artworkShape = "artworkShape"
        static let artworkShadow = "artworkShadow"
        static let artworkScale = "artworkScale"
        static let audioReactive = "audioReactive"
        static let audioIntensity = "audioIntensity"
        static let effectPulse = "effectPulse"
        static let effectChromatic = "effectChromatic"
        static let effectShake = "effectShake"
        static let effectParticles = "effectParticles"
        static let effectRipple = "effectRipple"
        static let beatSensitivity = "beatSensitivity"
    }

    enum Limits {
        static let opacity: ClosedRange<Double> = 0.2...1.0
        static let textBrightness: ClosedRange<Double> = 0.5...1.0
        static let titleScale: ClosedRange<Double> = 0.7...1.4
        static let artworkShadow: ClosedRange<Double> = 0...1
        static let artworkScale: ClosedRange<Double> = 0.6...1.6
        static let audioIntensity: ClosedRange<Double> = 0.2...2.0
        static let beatSensitivity: ClosedRange<Double> = 0.8...2.5
    }

    enum Defaults {
        static let opacity = 1.0
        static let textBrightness = 1.0
        static let titleScale = 1.0
        /// The poster thumbnail's shipped shadow strength.
        static let artworkShadow = 0.45
        static let artworkScale = 1.0
        static let audioIntensity = 1.0
        /// Onset threshold in standard deviations above the mean flux.
        static let beatSensitivity = 1.5
        static let lyricsLines = 3
    }

    /// The two published row counts; anything else on disk reads as the default.
    static let lyricsLineChoices = [1, 3]

    var style: Style = .poster
    var accentSource: AccentSource = .albumArt
    /// Canonical `#RRGGBB`; nil when unset or unparseable.
    var customAccentHex: String?
    var opacity = Defaults.opacity
    var textBrightness = Defaults.textBrightness
    /// nil means "whatever this style already used" — see `defaultTitleFont(for:)`.
    var titleFont: TitleFont?
    /// nil means "whatever this style already used" — see `defaultAlignment(for:)`.
    var alignment: Alignment?
    var titleScale = Defaults.titleScale
    var marquee = false
    var showArtwork = true
    var showArtist = true
    var showAlbum = true
    var showProgress = true
    /// Off by default: it is a new feature and the only one that reaches the
    /// network, so an untouched layer stays offline.
    var showLyrics = false
    /// Rows the large tile shows (1 or 3); medium always shows one.
    var lyricsLines = Defaults.lyricsLines
    /// Transport buttons. On by default because they only appear under the
    /// pointer — an untouched layer still looks like nothing but type.
    var showControls = true
    var seekOnProgressDrag = true
    var artworkShape: ArtworkShape = .rounded
    var artworkShadow = Defaults.artworkShadow
    var artworkScale = Defaults.artworkScale
    /// Master switch for everything the audio layer draws.
    var audioReactive = true
    /// One multiplier over every effect's amplitude; each stays clamped.
    var audioIntensity = Defaults.audioIntensity
    var effectPulse = true
    var effectChromatic = false
    var effectShake = false
    var effectParticles = true
    var effectRipple = false
    var beatSensitivity = Defaults.beatSensitivity

    init() {}

    init(_ options: [String: MonitorWidgetOptionValue]) {
        style = Self.enumValue(options, Key.style) ?? .poster
        accentSource = Self.enumValue(options, Key.accentSource) ?? .albumArt
        customAccentHex = options[Key.customAccentHex]?.stringValue.flatMap(Self.canonicalHex)
        opacity = Self.number(options, Key.opacity, default: Defaults.opacity, in: Limits.opacity)
        textBrightness = Self.number(
            options, Key.textBrightness, default: Defaults.textBrightness, in: Limits.textBrightness
        )
        titleFont = Self.enumValue(options, Key.titleFont)
        alignment = Self.enumValue(options, Key.alignment)
        titleScale = Self.number(options, Key.titleScale, default: Defaults.titleScale, in: Limits.titleScale)
        marquee = options[Key.marquee]?.boolValue ?? false
        showArtwork = options[Key.showArtwork]?.boolValue ?? true
        showArtist = options[Key.showArtist]?.boolValue ?? true
        showAlbum = options[Key.showAlbum]?.boolValue ?? true
        showProgress = options[Key.showProgress]?.boolValue ?? true
        showLyrics = options[Key.showLyrics]?.boolValue ?? false
        lyricsLines = Self.lyricsLineCount(options[Key.lyricsLines]?.numberValue)
        showControls = options[Key.showControls]?.boolValue ?? true
        seekOnProgressDrag = options[Key.seekOnProgressDrag]?.boolValue ?? true
        artworkShape = Self.enumValue(options, Key.artworkShape) ?? .rounded
        artworkShadow = Self.number(
            options, Key.artworkShadow, default: Defaults.artworkShadow, in: Limits.artworkShadow
        )
        artworkScale = Self.number(
            options, Key.artworkScale, default: Defaults.artworkScale, in: Limits.artworkScale
        )
        audioReactive = options[Key.audioReactive]?.boolValue ?? true
        audioIntensity = Self.number(
            options, Key.audioIntensity, default: Defaults.audioIntensity, in: Limits.audioIntensity
        )
        effectPulse = options[Key.effectPulse]?.boolValue ?? true
        effectChromatic = options[Key.effectChromatic]?.boolValue ?? false
        effectShake = options[Key.effectShake]?.boolValue ?? false
        effectParticles = options[Key.effectParticles]?.boolValue ?? true
        effectRipple = options[Key.effectRipple]?.boolValue ?? false
        beatSensitivity = Self.number(
            options, Key.beatSensitivity, default: Defaults.beatSensitivity, in: Limits.beatSensitivity
        )
    }

    // MARK: Style-dependent defaults

    /// Aurora has always been centered and poster/vinyl leading; giving the
    /// option one flat default would silently restyle whichever ones disagree.
    static func defaultAlignment(for style: Style) -> Alignment {
        switch style {
        case .poster, .vinyl: .leading
        case .aurora: .center
        }
    }

    /// Same reasoning as `defaultAlignment(for:)` — poster ships serif, the
    /// other two ship rounded.
    static func defaultTitleFont(for style: Style) -> TitleFont {
        switch style {
        case .poster: .serif
        case .vinyl, .aurora: .rounded
        }
    }

    var resolvedAlignment: Alignment { alignment ?? Self.defaultAlignment(for: style) }
    var resolvedTitleFont: TitleFont { titleFont ?? Self.defaultTitleFont(for: style) }

    // MARK: Write back

    func applied(to options: [String: MonitorWidgetOptionValue]) -> [String: MonitorWidgetOptionValue] {
        var next = options

        func put(_ key: String, _ value: MonitorWidgetOptionValue?) {
            if let value { next[key] = value } else { next.removeValue(forKey: key) }
        }
        func putNumber(_ key: String, _ value: Double, default def: Double, in range: ClosedRange<Double>) {
            let clamped = Self.clamp(value, default: def, in: range)
            put(key, clamped == def ? nil : .number(clamped))
        }

        put(Key.style, style == .poster ? nil : .string(style.rawValue))
        put(Key.accentSource, accentSource == .albumArt ? nil : .string(accentSource.rawValue))
        put(
            Key.customAccentHex,
            customAccentHex.flatMap(Self.canonicalHex).map(MonitorWidgetOptionValue.string)
        )
        putNumber(Key.opacity, opacity, default: Defaults.opacity, in: Limits.opacity)
        putNumber(
            Key.textBrightness, textBrightness, default: Defaults.textBrightness, in: Limits.textBrightness
        )
        put(
            Key.titleFont,
            titleFont.flatMap { value -> MonitorWidgetOptionValue? in
                value == Self.defaultTitleFont(for: style) ? nil : .string(value.rawValue)
            }
        )
        put(
            Key.alignment,
            alignment.flatMap { value -> MonitorWidgetOptionValue? in
                value == Self.defaultAlignment(for: style) ? nil : .string(value.rawValue)
            }
        )
        putNumber(Key.titleScale, titleScale, default: Defaults.titleScale, in: Limits.titleScale)
        put(Key.marquee, marquee ? .bool(true) : nil)
        put(Key.showArtwork, showArtwork ? nil : .bool(false))
        put(Key.showArtist, showArtist ? nil : .bool(false))
        put(Key.showAlbum, showAlbum ? nil : .bool(false))
        put(Key.showProgress, showProgress ? nil : .bool(false))
        put(Key.showLyrics, showLyrics ? .bool(true) : nil)
        let lines = Self.lyricsLineCount(Double(lyricsLines))
        put(Key.lyricsLines, lines == Defaults.lyricsLines ? nil : .number(Double(lines)))
        put(Key.showControls, showControls ? nil : .bool(false))
        put(Key.seekOnProgressDrag, seekOnProgressDrag ? nil : .bool(false))
        put(Key.artworkShape, artworkShape == .rounded ? nil : .string(artworkShape.rawValue))
        putNumber(
            Key.artworkShadow, artworkShadow, default: Defaults.artworkShadow, in: Limits.artworkShadow
        )
        putNumber(Key.artworkScale, artworkScale, default: Defaults.artworkScale, in: Limits.artworkScale)
        put(Key.audioReactive, audioReactive ? nil : .bool(false))
        putNumber(
            Key.audioIntensity, audioIntensity, default: Defaults.audioIntensity, in: Limits.audioIntensity
        )
        put(Key.effectPulse, effectPulse ? nil : .bool(false))
        put(Key.effectChromatic, effectChromatic ? .bool(true) : nil)
        put(Key.effectShake, effectShake ? .bool(true) : nil)
        put(Key.effectParticles, effectParticles ? nil : .bool(false))
        put(Key.effectRipple, effectRipple ? .bool(true) : nil)
        putNumber(
            Key.beatSensitivity, beatSensitivity,
            default: Defaults.beatSensitivity, in: Limits.beatSensitivity
        )

        return next
    }

    // MARK: Parsing helpers

    private static func enumValue<T: RawRepresentable>(
        _ options: [String: MonitorWidgetOptionValue], _ key: String
    ) -> T? where T.RawValue == String {
        options[key]?.stringValue.flatMap(T.init(rawValue:))
    }

    private static func number(
        _ options: [String: MonitorWidgetOptionValue],
        _ key: String,
        default def: Double,
        in range: ClosedRange<Double>
    ) -> Double {
        guard let raw = options[key]?.numberValue else { return def }
        return clamp(raw, default: def, in: range)
    }

    /// Snaps to one of the published choices; a NaN, a 2, or a missing key all
    /// read as the default rather than drawing an unsupported row count.
    private static func lyricsLineCount(_ raw: Double?) -> Int {
        guard let raw, raw.isFinite else { return Defaults.lyricsLines }
        let value = Int(raw.rounded())
        return lyricsLineChoices.contains(value) ? value : Defaults.lyricsLines
    }

    private static func clamp(_ value: Double, default def: Double, in range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return def }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Accent color

extension NowPlayingOptions {
    /// `#RRGGBB` or `RRGGBB`, any case. Anything else is not a color.
    static func accentColor(fromHex hex: String) -> NowPlayingAccentColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6,
              text.allSatisfy(\.isHexDigit),
              let value = UInt32(text, radix: 16)
        else { return nil }
        return NowPlayingAccentColor(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func canonicalHex(_ hex: String) -> String? {
        accentColor(fromHex: hex).map(hexString(for:))
    }

    static func hexString(for color: NowPlayingAccentColor) -> String {
        func byte(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", byte(color.red), byte(color.green), byte(color.blue))
    }

    /// A parseable custom color wins; otherwise the cover's dominant color;
    /// nil leaves the caller on its own fallback tint (`Design.signalAmber`).
    static func resolvedAccent(
        options: NowPlayingOptions, artwork: NowPlayingAccentColor?
    ) -> NowPlayingAccentColor? {
        if options.accentSource == .custom,
           let hex = options.customAccentHex,
           let custom = accentColor(fromHex: hex) {
            return custom
        }
        return artwork
    }
}
