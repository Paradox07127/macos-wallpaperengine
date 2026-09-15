import SwiftUI
import AppKit

public enum DesignTokens {
    public enum Colors {
        public static let pageBackground = Color(nsColor: .windowBackgroundColor)

        /// One step off the page in both appearances. Not `controlBackgroundColor`: it resolves
        /// to exactly `windowBackgroundColor`, so cards would match the page behind them.
        public static let surfaceRaised = Color(nsColor: NSColor(name: "surfaceRaised") { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor.windowBackgroundColor
            return base.blended(withFraction: isDark ? 0.06 : 0.04, of: isDark ? .white : .black) ?? base
        })

        public static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)

        public static let textPrimary = Color(nsColor: .labelColor)
        public static let textSecondary = Color(nsColor: .secondaryLabelColor)
        public static let textTertiary = Color(nsColor: .tertiaryLabelColor)

        public static let separator = Color(nsColor: .separatorColor)
        public static let accent = Color(nsColor: .controlAccentColor)

        /// Fixed RGB, not adaptive, on purpose: system green is too light to clear WCAG AA
        /// for white glyphs over bright artwork.
        public static let badgeActive = Color(red: 0.08, green: 0.35, blue: 0.15)

        /// Fixed white for content layered over user media: it must contrast the media,
        /// not the app theme, so it can't be an adaptive token.
        public static let overlayForeground = Color.white

        /// Fixed white for content on a solid accent fill: it contrasts the brand fill
        /// itself, independent of light/dark.
        public static let onAccentFill = Color.white

        /// Named separately from `Status.caution`: same hue, but this carries no
        /// "needs attention" meaning.
        public static let rating = Color.yellow

        public enum Status {
            public static let active = Color(nsColor: .systemGreen)
            /// Actionable, non-alarming — an update being available is news, not a fault.
            public static let info = Color(nsColor: .systemBlue)
            public static let warning = Color(nsColor: .systemOrange)
            public static let caution = Color(nsColor: .systemYellow)
            public static let danger = Color(nsColor: .systemRed)
        }

        /// One hue per guided library page. System colours, not fixed RGB —
        /// they already carry light/dark and Increase Contrast variants.
        public enum LibraryTint {
            public static let aerials = Color(nsColor: .systemTeal)
            public static let systemWallpaper = Color(nsColor: .systemIndigo)
            public static let bookmarks = Color(nsColor: .systemOrange)
            public static let schemes = Color(nsColor: .systemPurple)
        }

        /// Deliberately softer than `Status.*`: paired with a thin ring, the always-busy
        /// gauges would read harshly otherwise.
        public enum Gauge {
            public static let low = Color(red: 0.24, green: 0.72, blue: 0.40)
            public static let medium = Color(red: 0.95, green: 0.60, blue: 0.16)
            public static let high = Color(red: 0.90, green: 0.33, blue: 0.31)
        }

        public static let boardEditAccent = Color(red: 0.82, green: 0.63, blue: 0.30)
        /// Kept separate from `boardEditAccent`: deliberately darker, where the lighter
        /// amber washed out.
        public static let boardEditBorder = Color(red: 0.62, green: 0.50, blue: 0.28)

        /// Always dark regardless of system appearance: a semantic surface token would
        /// flip it to white over a light wallpaper.
        public enum BoardChrome {
            public static let surface = Color(white: 0.14)
            /// The card body, a touch darker so a card over the bar reads as behind it.
            public static let panel = Color(white: 0.12)
            public static let selected = Color(white: 0.30)
            public static let well = Color.black.opacity(0.30)
            /// One hairline value for every border in the chrome.
            public static let hairline = Color.white.opacity(0.12)
        }

        /// Fixed values tuned against the panel's own black background — systematically
        /// lighter than `Status.*` so they stay legible there.
        public enum Log {
            public static let error = Color(red: 1.0, green: 0.45, blue: 0.42)
            public static let warning = Color(red: 1.0, green: 0.72, blue: 0.36)
            public static let miss = Color(red: 0.98, green: 0.86, blue: 0.45)
            public static let success = Color(red: 0.56, green: 0.92, blue: 0.64)
            /// Default/unmatched log lines — plain white rather than a hue, so it
            /// doesn't compete with the four semantic colors above.
            public static let neutral = Color.white.opacity(0.85)
        }

        /// Bookmark tint per wallpaper content kind (`BookmarkPresentation`).
        public enum ContentType {
            public static let video = Color.blue
            public static let html = Color.green
            public static let scene = Color.orange
        }
    }

    /// Never inline `.font(.system(size:))` on text; standalone SF Symbol glyph sizing
    /// is the documented exemption (DESIGN.md hard rule 1).
    public enum Typography {
        public static let badge = Font.system(.caption2).weight(.semibold)

        public static let caption = Font.caption
        public static let captionEmphasized = Font.caption.weight(.semibold)

        public static let body = Font.body
        public static let bodyEmphasized = Font.body.weight(.semibold)

        /// A step above `bodyEmphasized` (also 13pt semibold) so hierarchy stays legible.
        public static let sectionTitle = Font.title3.weight(.semibold)

        public static let pageTitle = Font.title2

        public static let hero = Font.largeTitle

        public static let metric = Font.caption.monospacedDigit()

        public static let metricEmphasized = Font.system(.callout, design: .monospaced)
            .weight(.semibold)
            .monospacedDigit()

        public static let code = Font.system(.body, design: .monospaced)

        public static let codeCaption = Font.system(.caption, design: .monospaced)
    }

    public enum LibraryGrid {
        public static let minimumColumnWidth: CGFloat = 184
        public static let maximumColumnWidth: CGFloat = 220

        /// Tile shape, which decides the ladder: `.wide` is 16:9, `.square` is Workshop.
        public enum Aspect {
            case square
            case wide
        }

        public static func columnWidths(
            for size: LibraryTileSize,
            aspect: Aspect
        ) -> (min: CGFloat, max: CGFloat) {
            switch aspect {
            case .square:
                switch size {
                case .small: (128, 152)
                case .medium: (minimumColumnWidth, maximumColumnWidth)
                case .large: (248, 300)
                }
            case .wide:
                switch size {
                case .small: (240, 288)
                case .medium: (320, 384)
                case .large: (432, 520)
                }
            }
        }

        /// Off the spacing scale on purpose: the tiles read as a mosaic, where `lg`
        /// opened the rows wider than the columns look.
        public static let spacing: CGFloat = 14

        /// Equal to the filter bar's, so a card's leading edge lands under the search field.
        public static let horizontalPadding: CGFloat = LibraryFilterBar.horizontalPadding
        public static let verticalPadding: CGFloat = Spacing.cardInset

        public static func columns(for size: LibraryTileSize, aspect: Aspect) -> [GridItem] {
            let widths = columnWidths(for: size, aspect: aspect)
            return [GridItem(.adaptive(minimum: widths.min, maximum: widths.max), spacing: spacing)]
        }
    }

    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        /// Content inset for cards, tiles and floating chrome. Sits between `md` and `lg`
        /// deliberately; don't fold it into either.
        public static let cardInset: CGFloat = 14
    }

    public enum Corner {
        public static let sm: CGFloat = 6
        public static let md: CGFloat = 10
        public static let lg: CGFloat = 14
        public static let xl: CGFloat = 18
        /// Radius for preview containers (screen previews, hero media, drop targets).
        public static let preview: CGFloat = 16
        /// Inspector panel cards.
        public static let panel: CGFloat = 12
    }

    /// Only interaction-state alpha routes through these; decorative strokes, shadows
    /// and media scrims stay literal by design.
    public enum Opacity {
        public static let hoverFill: Double = 0.05
        public static let dragFill: Double = 0.08
        /// Active / playing / conflict background; also the unselected stroke.
        public static let activeFill: Double = 0.10
        public static let selectedFill: Double = 0.12
        public static let quietStroke: Double = 0.28
        public static let strongStroke: Double = 0.55
        public static let alertStroke: Double = 0.75
        public static let emphasisStroke: Double = 0.85
        public static let dimmedContent: Double = 0.45
        public static let disabledContent: Double = 0.55
        /// Dimmed glyph in its off state; empty-slot strokes.
        public static let dimmedIcon: Double = 0.70
    }

    /// Page-top status bars (storage breakdown, Workshop setup).
    public enum StatusBar {
        public static let height: CGFloat = 6
        public static let corner: CGFloat = 3
    }

    public enum Inspector {
        public static let minWidth: CGFloat = 268
        public static let idealWidth: CGFloat = 292
        public static let maxWidth: CGFloat = 480
        public static let defaultWidth: CGFloat = idealWidth
        public static let horizontalPadding: CGFloat = Spacing.md
        /// Shared geometry for inspector "label … [slider][value]" rows. `Typography.metric`
        /// is already monospaced, so call sites don't add `.monospacedDigit()`.
        public static let sliderWidth: CGFloat = 96
        public static let sliderValueWidth: CGFloat = 40
        public static let sliderValueSpacing: CGFloat = Spacing.xs
        /// Horizontal padding floor when the inspector is dragged to its min width.
        /// Vertical padding stays constant — only horizontal compresses with width.
        public static let minHorizontalPadding: CGFloat = 9
        /// Linear interpolation: padding == horizontalPadding when width == maxWidth,
        /// floors at `minHorizontalPadding` when the user drags toward `minWidth`.
        public static func horizontalPadding(for width: CGFloat) -> CGFloat {
            let target = width * (horizontalPadding / maxWidth)
            return min(max(target, minHorizontalPadding), horizontalPadding)
        }
    }

    public enum Sidebar {
        public static let width: CGFloat = 180
        public static let maxWidth: CGFloat = width * 1.2
        public static let sectionHeaderBottomPadding: CGFloat = 0
        /// Negative on purpose: macOS has no public `listSectionSpacing`, so the section
        /// gap is clawed back on the header itself.
        public static let sectionHeaderTopPadding: CGFloat = -7
    }

    public enum DetailHeader {
        public static let horizontalPadding: CGFloat = Spacing.xl
        public static let verticalPadding: CGFloat = Spacing.cardInset
        public static let contentSpacing: CGFloat = Spacing.cardInset
        public static let iconSize: CGFloat = 40
        public static let iconSymbolSize: CGFloat = 20
        public static let textSpacing: CGFloat = Spacing.xxs
        public static let metadataSpacing: CGFloat = Spacing.sm
    }

    /// Horizontal padding matches `DetailHeader` so the search capsule lines up with
    /// the header brand icon; vertical padding stays tighter.
    public enum LibraryFilterBar {
        public static let horizontalPadding: CGFloat = Spacing.xl
        public static let verticalPadding: CGFloat = 10
        public static let contentSpacing: CGFloat = 10
        // Also reused by the narrow detail inspector, so they must stay legible at minimum width.
        public static let searchMinWidth: CGFloat = 132
        public static let searchIdealWidth: CGFloat = 168
        public static let searchMaxWidth: CGFloat = 216
    }

    public enum LibraryStatusBar {
        public static let horizontalPadding: CGFloat = Spacing.xl
        public static let verticalPadding: CGFloat = 6
    }

    /// Without these floors macOS 26 `NavigationSplitView` squeezes the detail column
    /// and drops the sidebar's upper sections out of view.
    public enum LibraryPage {
        /// Main-column floor (360) plus a fully expanded inspector (`Inspector.maxWidth`,
        /// 480); `SettingsWindowLayoutTests` pins the relationship.
        public static let minWidth: CGFloat = 840
        public static let minHeight: CGFloat = 540
    }

    public enum GuidedLibrary {
        public static let outerPadding: CGFloat = 40
        public static let topSpacerHeight: CGFloat = Spacing.xl
        public static let iconSize: CGFloat = 48
        public static let featureWidth: CGFloat = 380
        public static let messageWidth: CGFloat = 360
    }

    public enum Settings {
        public static let formHorizontalMargin: CGFloat = 18
        public static let formVerticalMargin: CGFloat = Spacing.md
        /// Longer throw than `Inspector.sliderWidth` on purpose: this window has no 268pt
        /// panel floor, and these tracks are dragged for a value rather than nudged.
        public static let sliderWidth: CGFloat = 240
    }

    public enum Card {
        public static let strokeOpacity: Double = 0.06
        public static let strokeWidth: CGFloat = 0.5
        public static let shadowRadius: CGFloat = 12
        public static let shadowOpacity: Double = 0.18
        public static let shadowYOffset: CGFloat = 4
        public static let selectedShadowOpacity: Double = 0.22

        /// A faint always-on shadow so hover interpolates smoothly instead of popping from flat.
        public static let restShadowRadius: CGFloat = 3
        public static let restShadowOpacity: Double = 0.05
        public static let restShadowYOffset: CGFloat = 1
    }

    /// Window-level fades run through `NSAnimationContext`, so they need a duration +
    /// `CAMediaTimingFunction`, not a SwiftUI `Animation`.
    public enum Motion {
        /// Enter is deliberately twice the exit duration; the asymmetry is the point.
        public static let enterDuration: TimeInterval = 0.4
        public static let exitDuration: TimeInterval = 0.2

        /// Deliberately longer than `exitDuration`, which is tuned for widget-sized
        /// elements and reads as a jump at full screen.
        public static let wallpaperCrossfadeDuration: TimeInterval = 0.4

        public static var enterTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(name: .easeOut)
        }

        public static var exitTiming: CAMediaTimingFunction {
            CAMediaTimingFunction(name: .easeIn)
        }
    }

    /// nil when Reduce Motion is on, so the change applies instantly.
    public static func motion(_ reduceMotion: Bool, _ animation: Animation) -> Animation? {
        reduceMotion ? nil : animation
    }
}
