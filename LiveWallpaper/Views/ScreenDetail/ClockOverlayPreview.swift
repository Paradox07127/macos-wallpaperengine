import LiveWallpaperCore
import SwiftUI

struct ClockOverlayPreview: View {
    let screen: Screen
    let screenManager: ScreenManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOrigin: CGPoint?
    @State private var dragTranslation = CGSize.zero
    @State private var resizeStart: CGRect?
    @State private var resizeWidth: CGFloat?

    private var clock: ClockOverlayConfiguration {
        screenManager.monitorOverlay(for: screen).clock
    }

    private static let canvasSpace = "ClockPreviewCanvas"

    var body: some View {
        Group {
            if clock.enabled {
                GeometryReader { proxy in
                    clockContent(canvas: proxy.size)
                }
                .coordinateSpace(name: Self.canvasSpace)
            } else {
                OverlayOffNotice(text: "Clock is off for this display")
            }
        }
        .onChange(of: screen.id) { _, _ in clearGesture() }
        .onChange(of: clock) { _, _ in clearGesture() }
    }

    private func clockContent(canvas: CGSize) -> some View {
        let reference = max(screen.frame.width, 1)
        let safeArea = MonitorSafeAreaInsets.of(screen.nsScreen)
        var displayed = clock
        if let resizeWidth {
            displayed.width = resizeWidth
        }
        let resting = ClockOverlayLayout.renderRect(configuration: displayed, canvas: canvas,
                                                    referenceWidth: reference, safeArea: safeArea)
        let origin = dragOrigin ?? resting.origin
        let dragging = ClockOverlayLayout.placing(displayed,
                                                  origin: CGPoint(x: origin.x + dragTranslation.width,
                                                                  y: origin.y + dragTranslation.height),
                                                  canvas: canvas, referenceWidth: reference, safeArea: safeArea)
        let rect = ClockOverlayLayout.renderRect(configuration: dragging, canvas: canvas,
                                                 referenceWidth: reference, safeArea: safeArea)
        return TimelineView(ClockOverlaySchedule(suspended: dragOrigin != nil || resizeStart != nil,
                                                 blinking: clock.blinksSeparators && !reduceMotion)) { timeline in
            NixieClockView(configuration: clock, now: timeline.date, animatesSeparators: !reduceMotion)
                .allowsHitTesting(false)
        }
        .frame(width: rect.width, height: rect.height)
        .overlay { Color.clear.contentShape(Rectangle()) }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.canvasSpace))
            .onChanged { value in
                guard resizeStart == nil else { return }
                if dragOrigin == nil {
                    dragOrigin = resting.origin
                }
                dragTranslation = value.translation
            }
            .onEnded { value in
                guard let start = dragOrigin else { return }
                let next = ClockOverlayLayout.placing(clock,
                                                      origin: CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height),
                                                      canvas: canvas, referenceWidth: reference, safeArea: safeArea)
                clearGesture()
                screenManager.setClockOverlay(next, for: screen)
            })
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
                .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(DesignTokens.Typography.captionEmphasized)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.canvasSpace))
                    .onChanged { value in
                        if resizeStart == nil {
                            resizeStart = resting
                            dragOrigin = nil
                            dragTranslation = .zero
                        }
                        guard let start = resizeStart else { return }
                        let ratio = ClockOverlayConfiguration.aspectRatio
                        let change = (value.translation.width + value.translation.height / ratio) / (1 + 1 / (ratio * ratio))
                        resizeWidth = (start.width + change) * reference / max(canvas.width, 1)
                    }
                    .onEnded { _ in
                        var next = clock
                        next.width = resizeWidth ?? clock.width
                        next = ClockOverlayLayout.placing(next, origin: resizeStart?.origin ?? resting.origin,
                                                          canvas: canvas, referenceWidth: reference, safeArea: safeArea)
                        clearGesture()
                        screenManager.setClockOverlay(next, for: screen)
                    })
                .accessibilityLabel(Text("Resize Clock"))
                .accessibilityAdjustableAction { direction in
                    var next = clock
                    next.width += direction == .increment ? 20 : -20
                    screenManager.setClockOverlay(next, for: screen)
                }
        }
        .accessibilityLabel(Text("Drag to move the Clock layer"))
        .position(x: rect.midX, y: rect.midY)
    }

    private func clearGesture() {
        dragOrigin = nil
        dragTranslation = .zero
        resizeStart = nil
        resizeWidth = nil
    }
}
