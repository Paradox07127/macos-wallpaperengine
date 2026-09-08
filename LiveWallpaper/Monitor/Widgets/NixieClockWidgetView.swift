import LiveWallpaperCore
import SwiftUI

/// The board owns time and suspension. This ornament adds no timer, sampler,
/// window, card background, or compositing surface over the wallpaper.
struct NixieClockWidgetView: View {
    let context: MonitorWidgetContext

    var body: some View {
        GeometryReader { geometry in
            let size = Self.fittedSize(in: geometry.size)
            ZStack(alignment: .top) {
                Image(decorative: "NixieAssembly")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                HStack(spacing: 0) {
                    ForEach(Array(Self.digits(at: context.now).enumerated()), id: \.offset) { index, digit in
                        Image(decorative: "NixieDigit\(digit)")
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Nixie Clock"))
        .accessibilityValue(Text(context.now, style: .time))
    }

    private static let tubeWidth: CGFloat = 200
    private static let tubeHeight: CGFloat = 420
    // The assembly render shares the digit camera and adds 40 points below it for the plinth.
    private static let designHeight: CGFloat = 460
    private static let pairGap: CGFloat = 28
    private static let designWidth = tubeWidth * 6 + pairGap * 2

    static func fittedSize(in bounds: CGSize) -> CGSize {
        let scale = max(0, min(bounds.width / designWidth, bounds.height / designHeight))
        return CGSize(width: designWidth * scale, height: designHeight * scale)
    }

    static func digits(at date: Date, calendar: Calendar = .current) -> [Int] {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return [parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0]
            .flatMap { [$0 / 10, $0 % 10] }
    }
}
