import LiveWallpaperCore
import SwiftUI

struct InspectorSplit<Main: View, Inspector: View>: View {
    let isMounted: Bool
    let isVisible: Bool
    let animationTrigger: AnyHashable
    let reduceMotion: Bool

    @Binding var storedWidth: Double
    @Binding var liveWidth: Double?

    var minWidth: CGFloat = DesignTokens.Inspector.minWidth
    var maxWidth: CGFloat = DesignTokens.Inspector.maxWidth
    var mainFloor: CGFloat = 360
    var onClose: (() -> Void)?

    @ViewBuilder var main: () -> Main
    @ViewBuilder var inspector: (CGFloat) -> Inspector

    var body: some View {
        GeometryReader { geo in
            layout(available: geo.size.width)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func layout(available: CGFloat) -> some View {
        let fullWidth = resolvedWidth(available: available)
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
                    .environment(\.inspectorContentIsVisible, isVisible)
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

    private func resolvedWidth(available: CGFloat) -> CGFloat {
        if let liveWidth {
            return min(max(CGFloat(liveWidth), minWidth), maxWidthCap(available: available))
        }
        return min(max(CGFloat(storedWidth), minWidth), maxWidthCap(available: available))
    }
}
