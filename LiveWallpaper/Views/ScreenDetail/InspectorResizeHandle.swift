import AppKit
import LiveWallpaperCore
import SwiftUI

/// Discrete width stepping for the keyboard and VoiceOver. Clamps at `minWidth`
/// instead of reusing the drag's close threshold: a drag arms the close visibly
/// before release, a keypress would commit it unseen.
enum InspectorResizeStep {
    static let defaultStep: CGFloat = 24

    enum Direction {
        case wider
        case narrower
    }

    static func stepped(
        from current: CGFloat,
        _ direction: Direction,
        step: CGFloat = defaultStep,
        minWidth: CGFloat,
        maxWidth: CGFloat
    ) -> CGFloat {
        let candidate = direction == .wider ? current + step : current - step
        return min(max(candidate, minWidth), maxWidth)
    }
}

/// Vertical handle on the inspector's leading edge for click-drag width resizing.
struct InspectorResizeHandle: View {
    static let hitAreaWidth: CGFloat = 28

    let width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let onPreviewWidthChange: (CGFloat) -> Void
    let onCommitWidth: (CGFloat) -> Void
    /// When non-nil, dragging until the raw candidate width drops below this value arms a close: releasing there fires `onRequestClose` instead of committing a width.
    var closeThreshold: CGFloat?
    var onRequestClose: (() -> Void)?

    private let handleWidth: CGFloat = 6
    private let handleHeight: CGFloat = 52
    private let hairlineHeightRatio: CGFloat = 0.7

    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var isClosingArmed = false
    @FocusState private var isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Split out of `body`: as one expression the chain crossed the project's
    /// 300ms type-check budget once the keyboard and VoiceOver modifiers landed.
    var body: some View {
        handle
            .gesture(resizeGesture)
            .onHover { hovering in
                guard isHovering != hovering else { return }
                isHovering = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
            .focusable()
            .focused($isFocused)
            // The focusable view is the full-height hit strip, not the little
            // pill, so the system ring draws a tall blue frame down the window
            // edge. The handle shows focus itself instead (see `isActive`).
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { adjust(.wider); return .handled }
            .onKeyPress(.rightArrow) { adjust(.narrower); return .handled }
            .help(Text("Drag to resize properties panel"))
            .accessibilityLabel(Text("Resize properties panel"))
            .accessibilityHint(Text("Drag horizontally to change the properties panel width"))
            .accessibilityValue(Text("\(Int(width.rounded())) points wide"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: adjust(.wider)
                case .decrement: adjust(.narrower)
                @unknown default: break
                }
            }
    }

    private var handle: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 1, height: handleHeight * hairlineHeightRatio)
                .opacity(isActive ? 0 : 1)

            // Armed keeps an opaque accent fill over the glass so the "release
            // to close" state stays unmistakable; `stroked: false` because the
            // two-state stroke below already draws the edge on the same shape.
            Capsule()
                .fill(isClosingArmed ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isClosingArmed ? Color.accentColor.opacity(0.9) : Color.primary.opacity(DesignTokens.Opacity.quietStroke),
                            lineWidth: 0.75
                        )
                )
                .adaptiveGlassSurface(.capsule, interactive: true, stroked: false)
                .frame(width: handleWidth, height: isClosingArmed ? handleHeight + 18 : handleHeight)
                .shadow(
                    color: isClosingArmed ? Color.accentColor.opacity(0.45) : Color.black.opacity(0.08),
                    radius: isClosingArmed ? 7 : 5, x: 0, y: 2
                )
                .opacity(isActive ? 0.95 : 0)
                .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.16)), value: isClosingArmed)
        }
        .frame(width: Self.hitAreaWidth)
        .frame(maxHeight: .infinity)
        .animation(DesignTokens.motion(reduceMotion, .easeOut(duration: 0.16)), value: isActive)
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStartWidth ?? width
                if dragStartWidth == nil {
                    dragStartWidth = start
                }
                isDragging = true
                let rawCandidate = rawCandidate(start: start, translationWidth: value.translation.width)
                setClosingArmed(armed(for: rawCandidate))
                onPreviewWidthChange(clamped(rawCandidate))
            }
            .onEnded { value in
                let start = dragStartWidth ?? width
                let rawCandidate = rawCandidate(start: start, translationWidth: value.translation.width)
                if armed(for: rawCandidate), let onRequestClose {
                    onRequestClose()
                } else {
                    onCommitWidth(clamped(rawCandidate))
                }
                dragStartWidth = nil
                isDragging = false
                isClosingArmed = false
            }
    }

    /// No drag session to preview against, so a step previews and commits in one
    /// go. Silently does nothing at the bounds rather than committing a no-op.
    private func adjust(_ direction: InspectorResizeStep.Direction) {
        let next = InspectorResizeStep.stepped(
            from: width,
            direction,
            minWidth: minWidth,
            maxWidth: maxWidth
        )
        guard next != width else { return }
        onPreviewWidthChange(next)
        onCommitWidth(next)
    }

    /// Focus counts: with the system ring suppressed, the handle appearing is
    /// the only thing that tells a keyboard user the arrow keys will resize.
    private var isActive: Bool {
        isHovering || isDragging || isFocused
    }

    /// Only ever true when the parent wired up drag-to-close.
    private func armed(for candidate: CGFloat) -> Bool {
        guard let closeThreshold, onRequestClose != nil else { return false }
        return candidate < closeThreshold
    }

    private func setClosingArmed(_ value: Bool) {
        guard isClosingArmed != value else { return }
        isClosingArmed = value
    }

    private func rawCandidate(start: CGFloat, translationWidth: CGFloat) -> CGFloat {
        start - translationWidth
    }

    private func clamped(_ candidate: CGFloat) -> CGFloat {
        min(max(candidate, minWidth), maxWidth)
    }
}
