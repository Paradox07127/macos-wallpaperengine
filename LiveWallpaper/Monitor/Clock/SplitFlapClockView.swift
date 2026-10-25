import LiveWallpaperCore
import SwiftUI

struct SplitFlapClockView: View {
    var configuration: ClockOverlayConfiguration = .default
    let now: Date
    var animatesFlaps = true

    var body: some View {
        GeometryReader { geometry in
            let size = NixieClockView.fittedSize(in: geometry.size)
            let scale = size.width / Self.designWidth
            let sprites = Self.spriteNames(at: now, uses24HourTime: configuration.uses24HourTime,
                                           padsHour: configuration.padsHour, animates: animatesFlaps)
            ZStack(alignment: .topLeading) {
                Image(decorative: "SplitFlapAssembly")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                ForEach(Array(sprites.enumerated()), id: \.offset) { index, sprite in
                    Image(decorative: sprite)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: Self.windowWidth * scale, height: Self.windowHeight * scale)
                        .offset(x: Self.windowLeft[index] * scale, y: Self.windowTop * scale)
                }
            }
            .frame(width: size.width, height: size.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .opacity(configuration.normalized.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Split-Flap Clock"))
        .accessibilityValue(Text(now, style: .time))
    }

    // Design-canvas points; the sprites are rendered at 2 px per point.
    private nonisolated static let designWidth: CGFloat = 1256
    private nonisolated static let windowWidth: CGFloat = 162
    private nonisolated static let windowHeight: CGFloat = 268.5
    private nonisolated static let windowTop: CGFloat = 93
    private nonisolated static let windowLeft: [CGFloat] = [56, 234, 458, 636, 860, 1038]

    /// Faces the flap reveals on its way from `from` to `to`, ending with `to`; -1 is the blank flap.
    nonisolated static func flipPath(from: Int, to: Int) -> [Int] {
        var path: [Int] = []
        var face = from
        while face != to {
            face = face == -1 ? 0 : face == 9 ? (to == -1 ? -1 : 0) : face + 1
            path.append(face)
        }
        return path
    }

    /// `elapsed` is seconds since the current whole second.
    nonisolated static func frameSlot(_ elapsed: TimeInterval) -> Int {
        // At epoch-scale timestamps `s + k / 60` loses ~1e-7 s to Double rounding and can read back just under slot k;
        // the margin must exceed that, or the slot floors to k - 1 and the schedule repeats one entry forever.
        Int((elapsed * 60 + 1e-3).rounded(.down))
    }

    nonisolated static func settledSlot(steps n: Int) -> Int {
        n == 0 ? 0 : 5 * n + 13
    }

    nonisolated static func spriteName(from: Int, path: [Int], slot: Int) -> String {
        let n = path.count
        guard let last = path.last, slot > 0 else {
            return stillName(from)
        }
        if slot >= settledSlot(steps: n) {
            return stillName(last)
        }
        // Chained steps cut at frame 9 (before the flap lands) to the next step's frame 5; 9 steps settle at slot 58.
        let step = slot <= 9 ? 0 : min((slot - 5) / 5, n - 1)
        let frame = slot - 5 * step
        let start = step == 0 ? from : path[step - 1]
        return "SplitFlapFlip\(code(start))\(code(path[step]))-" + String(format: "%02d", frame)
    }

    nonisolated static func spriteNames(
        at date: Date, calendar: Calendar = .current, uses24HourTime: Bool, padsHour: Bool, animates: Bool
    ) -> [String] {
        let second = floor(date.timeIntervalSince1970)
        let current = NixieClockView.digits(at: Date(timeIntervalSince1970: second), calendar: calendar,
                                            uses24HourTime: uses24HourTime, padsHour: padsHour)
        guard animates else { return current.map(stillName) }
        let previous = NixieClockView.digits(at: Date(timeIntervalSince1970: second - 1), calendar: calendar,
                                             uses24HourTime: uses24HourTime, padsHour: padsHour)
        let slot = frameSlot(date.timeIntervalSince1970 - second)
        return zip(previous, current).map { spriteName(from: $0, path: flipPath(from: $0, to: $1), slot: slot) }
    }

    nonisolated static func lastAnimatedSlot(
        at date: Date, calendar: Calendar = .current, uses24HourTime: Bool, padsHour: Bool
    ) -> Int {
        let second = floor(date.timeIntervalSince1970)
        let current = NixieClockView.digits(at: Date(timeIntervalSince1970: second), calendar: calendar,
                                            uses24HourTime: uses24HourTime, padsHour: padsHour)
        let previous = NixieClockView.digits(at: Date(timeIntervalSince1970: second - 1), calendar: calendar,
                                             uses24HourTime: uses24HourTime, padsHour: padsHour)
        return zip(previous, current).map { settledSlot(steps: flipPath(from: $0, to: $1).count) }.max() ?? 0
    }

    private nonisolated static func stillName(_ digit: Int) -> String {
        digit < 0 ? "SplitFlapDigitBlank" : "SplitFlapDigit\(digit)"
    }

    private nonisolated static func code(_ digit: Int) -> String {
        digit < 0 ? "B" : String(digit)
    }
}
