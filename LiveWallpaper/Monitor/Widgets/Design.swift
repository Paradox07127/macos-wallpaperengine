import SwiftUI

enum Design {
    // MARK: - Colour space

    static func oklch(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> Color {
        let (r, g, b) = linearSRGB(l: l, c: c, h: h)
        return Color(.sRGBLinear, red: r, green: g, blue: b, opacity: alpha)
    }

    static func linearSRGB(l: Double, c: Double, h: Double) -> (Double, Double, Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let bb = c * sin(hr)

        let lp = l + 0.3963377774 * a + 0.2158037573 * bb
        let mp = l - 0.1055613458 * a - 0.0638541728 * bb
        let sp = l - 0.0894841775 * a - 1.2914855480 * bb
        let lc = lp * lp * lp
        let mc = mp * mp * mp
        let sc = sp * sp * sp

        let r =  4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let b = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc
        return (clampUnit(r), clampUnit(g), clampUnit(b))
    }

    private static func clampUnit(_ x: Double) -> Double { min(1, max(0, x)) }

    // MARK: - Neutrals (warm graphite — not blue-black)

    static let bg0 = oklch(0.15, 0.011, 74)
    static let bg1 = oklch(0.185, 0.012, 74)
    static let bg2 = oklch(0.225, 0.014, 74)

    static let hairline = oklch(0.34, 0.016, 74)      // --line
    static let hairlineHi = oklch(0.46, 0.02, 74)     // --line-hi

    static let inkPrimary = oklch(0.93, 0.012, 84)    // --ink
    static let inkMuted = oklch(0.78, 0.015, 78) // --ink-dim
    static let inkFaint = oklch(0.70, 0.014, 76) // --ink-faint

    static let track = oklch(0.30, 0.01, 74)          // --track
    static let track2 = oklch(0.285, 0.01, 74)        // --track-2

    // MARK: - Signal colours (the only saturated hues — reserved for state)

    static let signalAmber = oklch(0.80, 0.128, 78)   // --run  : running / load
    static let signalCoral = oklch(0.705, 0.165, 34)  // --need : needs you / critical
    static let signalSage = oklch(0.76, 0.10, 158)    // --done : completed / healthy
    static let signalIdle = oklch(0.56, 0.010, 76)    // --idle : idle / neutral
    static let signalSteel = oklch(0.68, 0.05, 235)   // --cool : secondary metric

    static let loadSteel = oklch(0.62, 0.045, 250)

    /// Peak marker — the swatch and tick that mark a window's high-water mark, board-wide.
    static let peakMarker = oklch(0.72, 0.09, 60)

    // MARK: - Panel material

    static let panelFillTop = oklch(0.212, 0.013, 74, alpha: 0.72)
    static let panelFillBottom = oklch(0.176, 0.012, 74, alpha: 0.60)
    static let panelStroke = oklch(0.40, 0.018, 74, alpha: 0.55)      // --panel-line
    static let panelTopHighlight = Color.white.opacity(0.055)          // --panel-hi
    static let boardWash = oklch(0.135, 0.010, 74)

    // MARK: - Load band mapping

    /// The board's one 0…1 utilisation standard so a reading cannot be hot in one element and fine in another.
    /// Three bands only: colour answers fine/climbing/hot; magnitude is in the wedges and digits.
    enum Load {
        /// Climbing — worth a glance, not worth acting on.
        static let elevated: Double = 0.60
        /// Hot — sustained work at this level is what a user would want to see.
        static let hot: Double = 0.85
    }

    /// Wedge/bar colour for a live metric: steel at rest, so the instrument
    /// still reads as "measuring something" rather than "nothing to report".
    static func loadBandColor(_ fraction: Double) -> Color {
        if fraction > Load.hot {
            return signalCoral
        }
        if fraction >= Load.elevated {
            return signalAmber
        }
        return loadSteel
    }

    /// State-dot colour: same bands, but resting is the neutral idle grey —
    /// a dot is an alert affordance, and a lit one at idle would be noise.
    static func loadDotColor(_ fraction: Double) -> Color {
        if fraction > Load.hot {
            return signalCoral
        }
        if fraction >= Load.elevated {
            return signalAmber
        }
        return signalIdle
    }

    static func temperatureColor(_ celsius: Double) -> Color {
        let t = min(1, max(0, (celsius - 34) / (70 - 34)))
        let l: Double, c: Double, h: Double
        if t < 0.5 {
            let k = t / 0.5
            l = 0.74 - 0.02 * k; c = 0.09 + 0.03 * k; h = 158 - 80 * k
        } else {
            let j = (t - 0.5) / 0.5
            l = 0.72 - 0.02 * j; c = 0.12 + 0.045 * j; h = 78 - 48 * j
        }
        return oklch(l, c, h)
    }

    // MARK: - Typography

    static func heroFont(size: CGFloat) -> Font {
        .system(size: max(size, 10), weight: .semibold, design: .default)
    }

    static func subFont(size: CGFloat) -> Font {
        .system(size: max(size, 10), weight: .semibold, design: .default)
    }

    static func labelFont(size: CGFloat) -> Font {
        .system(size: max(size, 10), weight: .semibold, design: .default)
    }

    static func captionFont(size: CGFloat) -> Font {
        .system(size: max(size, 11), weight: .regular, design: .default)
    }

    static func microFont(size: CGFloat) -> Font {
        .system(size: max(size, 10), weight: .semibold, design: .default)
    }

    static func labelTracking(size: CGFloat) -> CGFloat { size * 0.12 }

    // MARK: - Type scale

    struct TypeScale {
        let hero: CGFloat
        let sub: CGFloat
        let label: CGFloat
        let caption: CGFloat

        init(cellHeight: CGFloat) {
            hero = min(46, max(24, cellHeight * 0.36))
            sub = hero * 0.52
            label = min(12, max(10, cellHeight * 0.10))
            caption = min(13, max(11, cellHeight * 0.11))
        }
    }

    // MARK: - Metrics

    static let contentInsetH: CGFloat = 16
    static let contentInsetV: CGFloat = 11

    static let hairlineWidth: CGFloat = 1

    static let cornerRadiusMin: CGFloat = 9  // chips / session cards

    /// Legend/peak swatch: a square with just enough radius to stop the corners
    /// reading as sharp at 5–6 pt.
    static let swatchCornerRadius: CGFloat = 1

    /// Header state dot, in points. Fixed rather than scaled: it is an alert
    /// affordance with a legibility floor, not type.
    static let stateDotSize: CGFloat = 6

    /// The "%" (or other unit) beside a hero number is drawn at this fraction of
    /// the digits' size, everywhere on the board.
    static let heroUnitRatio: CGFloat = 0.4

    /// Three-digit hero readings shrink by this much to clear the arc-gauge centre box.
    static let threeDigitHeroShrink: CGFloat = 0.68

    static func heroSize(base: CGFloat, digits: Int) -> CGFloat {
        digits >= 3 ? base * threeDigitHeroShrink : base
    }

    /// The board's one "no reading" glyph. An em dash — the en dash and the
    /// ASCII hyphen read as different widths next to each other.
    static let noData = "—"
}

// MARK: - Annotation chip (shared board-wide aesthetic)

extension View {
    func monitorChip(_ scale: Design.TypeScale) -> some View {
        self
            .padding(.horizontal, scale.label * 0.5)
            .padding(.vertical, scale.label * 0.24)
            .background(
                Capsule(style: .continuous)
                    .fill(Design.bg2.opacity(0.55))
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Design.hairlineHi.opacity(0.5), lineWidth: 1))
            )
    }
}
