import AppKit
import LiveWallpaperCore
import SwiftUI

@MainActor
final class ClockHostView: NSView {
    private let model: ClockOverlayModel
    private let hostingView: NSHostingView<ClockOverlayRoot>

    init(frame: NSRect, configuration: ClockOverlayConfiguration, safeArea: MonitorSafeAreaInsets) {
        model = ClockOverlayModel(configuration: configuration, safeArea: safeArea)
        hostingView = NSHostingView(rootView: ClockOverlayRoot(model: model))
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(configuration: ClockOverlayConfiguration, safeArea: MonitorSafeAreaInsets) {
        model.configuration = configuration
        model.safeArea = safeArea
    }

    func setSuspended(_ suspended: Bool) {
        model.suspended = suspended
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class ClockOverlayModel: ObservableObject {
    @Published var configuration: ClockOverlayConfiguration
    @Published var safeArea: MonitorSafeAreaInsets
    @Published var suspended = true

    init(configuration: ClockOverlayConfiguration, safeArea: MonitorSafeAreaInsets) {
        self.configuration = configuration
        self.safeArea = safeArea
    }
}

struct ClockOverlaySchedule: TimelineSchedule {
    let suspended: Bool
    let blinking: Bool

    func entries(from startDate: Date, mode _: TimelineScheduleMode) -> AnyIterator<Date> {
        let interval = blinking ? 0.5 : 1.0
        var next: Date? = startDate
        return AnyIterator {
            guard let current = next else { return nil }
            next = suspended ? nil : Date(timeIntervalSince1970:
                (floor(current.timeIntervalSince1970 / interval) + 1) * interval)
            return current
        }
    }
}

struct ClockOverlayRoot: View {
    @ObservedObject var model: ClockOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(ClockOverlaySchedule(suspended: model.suspended,
                                          blinking: model.configuration.blinksSeparators && !reduceMotion)) { timeline in
            GeometryReader { proxy in
                let rect = ClockOverlayLayout.renderRect(configuration: model.configuration,
                                                         canvas: proxy.size, safeArea: model.safeArea)
                NixieClockView(configuration: model.configuration, now: timeline.date,
                               animatesSeparators: !reduceMotion && !model.suspended)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
        .background(Color.clear)
        .appLanguageScoped(defaults: .appScoped())
    }
}
