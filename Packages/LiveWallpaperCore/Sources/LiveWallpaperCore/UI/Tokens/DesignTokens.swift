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

        /// Fixed-size, not text-style based: Edit Desk metadata is laid out at
        /// literal design px, not Dynamic Type (SCREENS.md tokens).
        public static let microMono = Font.system(size: 10, design: .monospaced)
    }

    public enum LibraryGrid {
        /// Tile shape, which decides the ladder: `.wide` is 16:9, `.square` is Workshop.
        public enum Aspect {
            case square
            case wide
        }

        /// Fixed on purpose: tiles never stretch with the window, so a card keeps its place
        /// while the page widens and the slack stays on the trailing edge.
        public static func columnWidth(for size: LibraryTileSize, aspect: Aspect) -> CGFloat {
            switch aspect {
            case .square:
                switch size {
                case .small: 152
                case .medium: 220
                case .large: 300
                }
            case .wide:
                switch size {
                case .small: 288
                case .medium: 384
                case .large: 520
                }
            }
        }

        /// The Edit Desk Workshop grid's column, kept out of the `LibraryTileSize` ladder because
        /// that ladder is a persisted global preference while this page is fixed at six columns
        /// (1280 − 2×18 inset fits 6×194 + 5×14; 1040 fits four).
        public static let workshopBrowseColumnWidth: CGFloat = 194

        /// Off the spacing scale on purpose: the tiles read as a mosaic, where `lg`
        /// opened the rows wider than the columns look.
        public static let spacing: CGFloat = 14

        /// Equal to the filter bar's, so a card's leading edge lands under the search field.
        public static let horizontalPadding: CGFloat = LibraryFilterBar.horizontalPadding
        public static let verticalPadding: CGFloat = Spacing.cardInset

        public static func tileFrame(
            index: Int, size: LibraryTileSize, aspect: Aspect, fitting width: CGFloat, tileAspectRatio: CGFloat
        ) -> CGRect {
            let count = columns(for: size, aspect: aspect, fitting: width).count
            let tileWidth = columnWidth(for: size, aspect: aspect)
            let tileHeight = tileWidth / tileAspectRatio
            return CGRect(
                x: CGFloat(index % count) * (tileWidth + spacing),
                y: CGFloat(index / count) * (tileHeight + spacing),
                width: tileWidth, height: tileHeight
            )
        }

        /// As many fixed columns as `width` holds, never fewer than one.
        /// `columnWidth` overrides the `size`/`aspect` ladder for pages pinned to one preset.
        public static func columns(
            for size: LibraryTileSize, aspect: Aspect, fitting width: CGFloat, columnWidth: CGFloat? = nil
        ) -> [GridItem] {
            let column = columnWidth ?? self.columnWidth(for: size, aspect: aspect)
            let count = max(1, Int(((width + spacing) / (column + spacing)).rounded(.down)))
            return Array(repeating: GridItem(.fixed(column), spacing: spacing), count: count)
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
        /// Measured off a live macOS sheet: 22pt, continuous. Containers that stand in
        /// for a sheet match it, so the two families read as the same surface.
        public static let sheet: CGFloat = 22
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
        public static let width: CGFloat = 220
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
        /// The widest row this window builds: icon tile + a wrapping subtitle column
        /// + `sliderWidth`. Past this the subtitles run to an unreadable measure.
        public static let maxContentWidth: CGFloat = 740
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

    /// Edit Desk is forced dark, so these are fixed values; only the three Increase Contrast
    /// overrides (GAP_ANALYSIS.md §6) resolve through `NSColor(name:)` like `Colors.surfaceRaised`.
    public enum EditDesk {
        // MARK: Colors

        public enum Colors {
            /// Every Edit Desk chrome colour resolves per appearance, so the whole surface follows
            /// General → Appearance. Anything drawn *over* a wallpaper thumbnail is fixed instead
            /// (see `StageLayerStyle`) — the media underneath does not change with the theme.
            static func adaptive(
                _ name: String,
                light: NSColor, dark: NSColor,
                lightContrast: NSColor? = nil, darkContrast: NSColor? = nil
            ) -> Color {
                Color(nsColor: NSColor(name: NSColor.Name("editDesk" + name)) { appearance in
                    let match = appearance.bestMatch(from: [
                        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
                    ])
                    switch match {
                    case .accessibilityHighContrastAqua: return lightContrast ?? light
                    case .accessibilityHighContrastDarkAqua: return darkContrast ?? dark
                    case .darkAqua: return dark
                    default: return light
                    }
                })
            }

            private static func ink(_ name: String, _ alpha: CGFloat, contrast: CGFloat? = nil) -> Color {
                adaptive(
                    name,
                    light: .black.withAlphaComponent(alpha * 1.1), dark: .white.withAlphaComponent(alpha),
                    lightContrast: .black.withAlphaComponent((contrast ?? alpha) * 1.1),
                    darkContrast: .white.withAlphaComponent(contrast ?? alpha)
                )
            }

            private static func grey(_ value: CGFloat) -> NSColor {
                NSColor(red: value / 255, green: value / 255, blue: value / 255, alpha: 1)
            }

            public static let background = adaptive(
                "Background",
                light: NSColor(red: 244 / 255, green: 244 / 255, blue: 247 / 255, alpha: 1),
                dark: NSColor(red: 18 / 255, green: 18 / 255, blue: 21 / 255, alpha: 1)
            )
            public static let panel = adaptive(
                "Panel",
                light: NSColor(red: 1, green: 1, blue: 1, alpha: 0.95),
                dark: NSColor(red: 28 / 255, green: 28 / 255, blue: 34 / 255, alpha: 0.95)
            )
            public static let console = adaptive(
                "Console",
                light: NSColor(red: 250 / 255, green: 250 / 255, blue: 252 / 255, alpha: 0.92),
                dark: NSColor(red: 18 / 255, green: 18 / 255, blue: 22 / 255, alpha: 0.92)
            )

            public static let textPrimary = adaptive("TextPrimary", light: grey(28), dark: grey(232))
            /// Increase Contrast resolves to the same value as `textCapsule` (GAP_ANALYSIS.md §6).
            public static let textSecondary = adaptive(
                "TextSecondary", light: grey(99), dark: grey(154),
                lightContrast: grey(60), darkContrast: grey(200)
            )
            public static let textTertiary = adaptive("TextTertiary", light: grey(122), dark: grey(138))
            public static let textCapsule = adaptive("TextCapsule", light: grey(60), dark: grey(200))

            public static let success = adaptive(
                "Success",
                light: NSColor(red: 30 / 255, green: 160 / 255, blue: 78 / 255, alpha: 1),
                dark: NSColor(red: 74 / 255, green: 222 / 255, blue: 128 / 255, alpha: 1)
            )
            public static let warning = adaptive(
                "Warning",
                light: NSColor(red: 176 / 255, green: 118 / 255, blue: 12 / 255, alpha: 1),
                dark: NSColor(red: 245 / 255, green: 181 / 255, blue: 68 / 255, alpha: 1)
            )
            public static let sceneGroupLayers = adaptive(
                "SceneGroupLayers",
                light: NSColor(red: 37 / 255, green: 99 / 255, blue: 235 / 255, alpha: 1),
                dark: NSColor(red: 96 / 255, green: 165 / 255, blue: 250 / 255, alpha: 1)
            )
            public static let sceneGroupEffects = adaptive(
                "SceneGroupEffects",
                light: NSColor(red: 147 / 255, green: 51 / 255, blue: 234 / 255, alpha: 1),
                dark: NSColor(red: 192 / 255, green: 132 / 255, blue: 252 / 255, alpha: 1)
            )
            public static let sceneGroupColors = adaptive(
                "SceneGroupColors",
                light: NSColor(red: 176 / 255, green: 118 / 255, blue: 12 / 255, alpha: 1),
                dark: NSColor(red: 245 / 255, green: 181 / 255, blue: 68 / 255, alpha: 1)
            )
            public static let danger = adaptive(
                "Danger",
                light: NSColor(red: 200 / 255, green: 54 / 255, blue: 54 / 255, alpha: 1),
                dark: NSColor(red: 1, green: 128 / 255, blue: 128 / 255, alpha: 1)
            )
            public static let link = adaptive(
                "Link",
                light: NSColor(red: 36 / 255, green: 84 / 255, blue: 214 / 255, alpha: 1),
                dark: NSColor(red: 154 / 255, green: 180 / 255, blue: 1, alpha: 1)
            )

            /// Increase Contrast raises this to .35 (GAP_ANALYSIS.md §6).
            public static let strokeRegular = ink("StrokeRegular", 0.10, contrast: 0.35)
            /// Increase Contrast raises this to .65 (GAP_ANALYSIS.md §6).
            public static let strokeShell = ink("StrokeShell", 0.32, contrast: 0.65)
            public static let strokePanel = ink("StrokePanel", 0.14)
            public static let strokeBadge = ink("StrokeBadge", 0.25)
            public static let strokeSelectedChip = ink("StrokeSelectedChip", 0.40)
            public static let strokeHotShell = ink("StrokeHotShell", 0.80)
            /// Pairs with `Shadow.shelfCard`'s 1px ring (SCREENS.md S2).
            public static let strokeShelfCardRing = ink("StrokeShelfCardRing", 0.12)

            public static let fillShell = ink("FillShell", 0.02)
            public static let fillNavPill = ink("FillNavPill", 0.06)
            public static let fillSelectedChip = ink("FillSelectedChip", 0.14)
            public static let fillSelectedNavItem = ink("FillSelectedNavItem", 0.16)

            public static let dropHighlight = success.opacity(0.22)
            public static let dropHighlightGlow = success.opacity(0.45)
            /// Over a wallpaper thumbnail, so it stays a dark scrim in both appearances.
            public static let playbackControlFill = Color.black.opacity(0.55)
            public static let gradientStageBottom = Color.black.opacity(0.7)
            public static let gradientCardBottom = Color.black.opacity(0.5)
            /// Separates the shelf from the stage; a hard black band is too heavy on a light canvas.
            public static let shelfScrim = adaptive(
                "ShelfScrim",
                light: .black.withAlphaComponent(0.10), dark: .black.withAlphaComponent(0.35)
            )
            public static let dotGrid = ink("DotGrid", 0.06)

            /// S4 scrim: the design's near-black `.62` blacks out a light canvas, so light halves it.
            public static let modalScrim = adaptive(
                "ModalScrim",
                light: .black.withAlphaComponent(0.32),
                dark: NSColor(red: 8 / 255, green: 8 / 255, blue: 10 / 255, alpha: 0.62)
            )
            public static let modalPanel = adaptive(
                "ModalPanel",
                light: NSColor(red: 1, green: 1, blue: 1, alpha: 0.98),
                dark: NSColor(red: 22 / 255, green: 22 / 255, blue: 26 / 255, alpha: 0.98)
            )
            /// Chips over the modal preview and float thumbnails (`bg .6`); fixed like every on-media colour.
            public static let mediaChipFill = Color.black.opacity(0.6)
            /// Tag chips over the modal preview (`rgba(0,0,0,.55)`).
            public static let tagChipFill = Color.black.opacity(0.55)
            public static let fillSecondaryButton = ink("FillSecondaryButton", 0.10)
            public static let fillTertiaryButton = ink("FillTertiaryButton", 0.06)
            public static let fillFloatButton = ink("FillFloatButton", 0.08)
            /// S4 primary button: white on black in dark, inverted in light.
            public static let primaryButtonFill = adaptive("PrimaryButtonFill", light: .black, dark: .white)
            public static let primaryButtonText = adaptive("PrimaryButtonText", light: .white, dark: .black)
        }

        // MARK: Corner

        public enum Corner {
            public static let content: CGFloat = 3
            public static let badge: CGFloat = 3
            public static let shelfCard: CGFloat = 6
            public static let playbackControl: CGFloat = 6
            public static let gridCard: CGFloat = 8
            public static let shell: CGFloat = 8
            /// MacBook shell only: top corners; `shellBuiltinBottom` for the bottom pair
            /// (`radius 9 9 3 3` in SCREENS.md S1).
            public static let shellBuiltinTop: CGFloat = 9
            public static let shellBuiltinBottom: CGFloat = 3
            /// MacBook notch: bottom corners only (`radius 0 0 5 5` in SCREENS.md S1).
            public static let notch: CGFloat = 5
            public static let panel: CGFloat = 10
            public static let panelLarge: CGFloat = 12
            public static let statusExpanded: CGFloat = 14
            public static let modal: CGFloat = 18
            public static let floatPanel: CGFloat = 16
            public static let button: CGFloat = 9
            public static let chip: CGFloat = 5
            public static let capsule: CGFloat = 99
        }

        // MARK: Shadow

        public struct Shadow: Sendable {
            public let color: Color
            public let radius: CGFloat
            public let y: CGFloat

            public static let shell = Shadow(color: .black.opacity(0.22), radius: 14, y: 5)
            public static let modal = Shadow(color: .black.opacity(0.7), radius: 70, y: 30)
            public static let hoverCard = Shadow(color: .black.opacity(0.4), radius: 28, y: 14)
            public static let shelfCard = Shadow(color: .black.opacity(0.3), radius: 14, y: 6)
            public static let floatPanel = Shadow(color: .black.opacity(0.5), radius: 50, y: 20)
        }

        // MARK: Spacing

        public enum Spacing {
            public static let s8: CGFloat = 8
            public static let s12: CGFloat = 12
            public static let s14: CGFloat = 14
            public static let gridGap: CGFloat = 12
            public static let workshopGridGap: CGFloat = 14
            public static let gutter: CGFloat = 24
            public static let topBar: CGFloat = 56
        }

        // MARK: Typography

        public enum Typography {
            public static let badgeMono = Font.system(size: 9, design: .monospaced)
            public static let metaMono = Font.system(size: 10, design: .monospaced)
            public static let chip = Font.system(size: 11)
            public static let body = Font.system(size: 12)
            public static let cardTitle = Font.system(size: 11, weight: .semibold)
            public static let stageTitle = Font.system(size: 13, weight: .semibold)
            public static let modalTitle = Font.system(size: 22, weight: .bold)
            public static let navItem = Font.system(size: 12)
            public static let libraryModalTitle = Font.system(size: 20, weight: .bold)
            public static let button = Font.system(size: 13, weight: .bold)
            public static let floatName = Font.system(size: 10, weight: .semibold)
            public static let dropLabel = Font.system(size: 11, weight: .bold)
        }
    }
}
