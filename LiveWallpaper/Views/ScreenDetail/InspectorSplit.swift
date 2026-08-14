import LiveWallpaperCore
import SwiftUI

/// Main column + trailing full-height inspector; widths resolve against live container width.
struct ResizableInspectorSplit<Main: View, Inspector: View>: View {
    /// Keep the (heavy) inspector subtree built even when collapsed.
    let isMounted: Bool
    let isVisible: Bool
    let animationTrigger: AnyHashable
    let reduceMotion: Bool

    @Binding var storedWidth: Double
    @Binding var liveWidth: Double?

    var minWidth: CGFloat = DesignTokens.Inspector.minWidth
    var maxWidth: CGFloat = DesignTokens.Inspector.maxWidth
    /// Minimum main-column width so content never collapses under a wide inspector.
    var mainFloor: CGFloat = 360
    var onClose: (() -> Void)?

    @ViewBuilder var main: () -> Main
    /// Built at full width; container clips to the animated visible width.
    @ViewBuilder var inspector: (CGFloat) -> Inspector

    var body: some View {
        GeometryReader { geo in
            layout(available: geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func layout(available: CGFloat) -> some View {
        let fullWidth = resolvedWidth()
        let shownWidth = isVisible ? fullWidth : 0
        HStack(spacing: 0) {
            main()
                .frame(width: max(0, available - shownWidth))

            if isMounted {
                inspector(fullWidth)
                    .frame(width: shownWidth, alignment: .leading)
                    .clipped()
                    .layoutPriority(1)
                    .allowsHitTesting(isVisible)
                    .accessibilityHidden(!isVisible)
                    .overlay(alignment: .leading) {
                        if isVisible {
                            InspectorResizeHandle(
                                width: fullWidth,
                                minWidth: minWidth,
                                maxWidth: maxWidthCap(available: available),
                                onPreviewWidthChange: { liveWidth = Double(clampLive($0, available: available)) },
                                onCommitWidth: {
                                    storedWidth = Double(clampCommit($0, available: available))
                                    liveWidth = nil
                                },
                                closeThreshold: dragToCloseEnabled ? closeArmWidth : nil,
                                onRequestClose: dragToCloseEnabled ? {
                                    liveWidth = nil
                                    onClose?()
                                } : nil
                            )
                            .offset(x: -InspectorResizeHandle.hitAreaWidth / 2)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction(value: liveWidth) { $0.animation = nil }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0.04),
            value: animationTrigger
        )
    }

    private var dragToCloseEnabled: Bool { onClose != nil }

    /// Release below this width collapses the panel.
    private var closeArmWidth: CGFloat { max(48, minWidth - 56) }

    /// Live drag floor; drag-to-close uses raw cursor travel past this.
    private var dragLowerBound: CGFloat { minWidth }

    private func maxWidthCap(available: CGFloat) -> CGFloat {
        let room = available - mainFloor
        return min(maxWidth, max(minWidth, room))
    }

    private func clampLive(_ candidate: CGFloat, available: CGFloat) -> CGFloat {
        min(max(candidate, dragLowerBound), maxWidthCap(available: available))
    }

    private func clampCommit(_ candidate: CGFloat, available: CGFloat) -> CGFloat {
        min(max(candidate, minWidth), maxWidthCap(available: available))
    }

    private func resolvedWidth() -> CGFloat {
        if let liveWidth {
            return min(max(CGFloat(liveWidth), minWidth), maxWidth)
        }
        return min(max(CGFloat(storedWidth), minWidth), maxWidth)
    }
}
