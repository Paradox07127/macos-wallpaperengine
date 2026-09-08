import LiveWallpaperCore
import SwiftUI

struct NixieClockView: View {
    var configuration: ClockOverlayConfiguration = .default
    let now: Date
    var animatesSeparators = true

    var body: some View {
        GeometryReader { geometry in
            let size = Self.fittedSize(in: geometry.size)
            ZStack(alignment: .top) {
                Image(decorative: Self.separatorsLit(at: now, blinking: configuration.blinksSeparators && animatesSeparators)
                    ? "NixieAssembly" : "NixieAssemblyOff")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                HStack(spacing: 0) {
                    ForEach(Array(Self.digits(at: now, uses24HourTime: configuration.uses24HourTime, padsHour: configuration.padsHour).enumerated()), id: \.offset) { index, digit in
                        Image(decorative: digit < 0 ? "NixieDigitOff" : "NixieDigit\(digit)")
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: size.width / Self.designWidth * Self.tubeWidth)
                        if index == 1 || index == 3 {
                            Color.clear.frame(width: size.width / Self.designWidth * Self.pairGap)
                        }
                    }
                }
                .frame(height: size.width / Self.designWidth * Self.tubeHeight)
            }
            .frame(width: size.width, height: size.height)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .opacity(configuration.normalized.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Nixie Clock"))
        .accessibilityValue(Text(now, style: .time))
    }

    private static let tubeWidth: CGFloat = 200
    private static let tubeHeight: CGFloat = 420
    // The assembly render shares the digit camera and adds 40 points below it for the plinth.
    private static let designHeight: CGFloat = 460
    private static let pairGap: CGFloat = 28
    private static let designWidth = tubeWidth * 6 + pairGap * 2

    nonisolated static func fittedSize(in bounds: CGSize) -> CGSize {
        let scale = max(0, min(bounds.width / designWidth, bounds.height / designHeight))
        return CGSize(width: designWidth * scale, height: designHeight * scale)
    }

    nonisolated static func digits(
        at date: Date, calendar: Calendar = .current, uses24HourTime: Bool = true, padsHour: Bool = true
    ) -> [Int] {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let hour = uses24HourTime ? (parts.hour ?? 0) : ((parts.hour ?? 0) + 11) % 12 + 1
        var result = [hour, parts.minute ?? 0, parts.second ?? 0].flatMap { [$0 / 10, $0 % 10] }
        if !padsHour, hour < 10 {
            result[0] = -1
        }
        return result
    }

    nonisolated static func separatorsLit(at date: Date, blinking: Bool) -> Bool {
        !blinking || date.timeIntervalSince1970 - floor(date.timeIntervalSince1970) < 0.5
    }
}
