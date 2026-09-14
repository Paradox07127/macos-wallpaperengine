import CoreGraphics
import LiveWallpaperCore
import SwiftUI

// MARK: - Chrome scale

/// Cancels the inspector board shrink so edit chrome stays hittable, and reports the grown box to layout.
struct MonitorChromeScale: ViewModifier {
    @Environment(\.monitorRenderScale) private var renderScale
    /// The chrome's own size, before the boost. Measured rather than assumed so
    /// the grown box the placement clamps see is the box that gets drawn.
    @State private var intrinsic: CGSize?

    func body(content: Content) -> some View {
        let boost = MonitorChromeScale.boost(forRenderScale: renderScale)
        if boost > 1 {
            content
                .modifier(MonitorPanelSizeReader(size: $intrinsic))
                .scaleEffect(boost, anchor: .topLeading)
                .frame(
                    width: intrinsic.map { $0.width * boost },
                    height: intrinsic.map { $0.height * boost },
                    alignment: .topLeading
                )
        } else {
            content
        }
    }

    /// Inverse of the board shrink, capped so a near-zero scale cannot ask for a box larger than the board.
    nonisolated static func boost(forRenderScale renderScale: CGFloat) -> CGFloat {
        guard renderScale.isFinite, renderScale > 0, renderScale < 1 else { return 1 }
        return min(1 / renderScale, maxBoost)
    }

    nonisolated static let maxBoost: CGFloat = 12
}

extension View {
    func monitorChromeScaled() -> some View {
        modifier(MonitorChromeScale())
    }
}

// MARK: - Chrome metrics

struct MonitorBoardChromeMetrics {
    let boardSize: CGSize
    let boost: CGFloat

    init(boardSize: CGSize, renderScale: CGFloat) {
        self.boardSize = boardSize
        boost = MonitorChromeScale.boost(forRenderScale: renderScale)
    }

    /// The board as chrome sees it: the room a panel actually has, in the points
    /// it lays itself out in.
    var chromeSpace: CGSize {
        CGSize(width: boardSize.width / boost, height: boardSize.height / boost)
    }

    /// A chrome-point length as the board measures it — panels are still placed
    /// in board points, so gaps and margins have to travel the other way.
    func board(_ chromePoints: CGFloat) -> CGFloat {
        chromePoints * boost
    }

    /// Clear of the menu bar on the desktop; proportional on a short board.
    var toolbarTopInset: CGFloat {
        boardSize.height >= 500 ? min(max(boardSize.height * 0.035, 44), 60) : boardSize.height * 0.055
    }

    var catalogWidth: CGFloat {
        min(760, chromeSpace.width * 0.86)
    }

    /// ≤55% of the board; 64 reserves the catalog's header and padding above the
    /// bottom margin. `anchorMaxY` is a board coordinate, the result a chrome one.
    func catalogScrollCap(anchorMaxY: CGFloat) -> CGFloat {
        let below = (boardSize.height - anchorMaxY - board(16)) / boost - 64
        return max(min(chromeSpace.height * 0.55, below), 80)
    }

    var settingsCardMaxHeight: CGFloat {
        chromeSpace.height - 16
    }

    /// Pre-measure estimate: gear+trash (~68) + ~30pt per size segment.
    func controlBarEstimate(for kind: MonitorWidgetKind) -> CGSize {
        let count = kind.allowedSizes.count
        return CGSize(
            width: board(68 + (count > 1 ? CGFloat(count) * 30 + 16 : 0)),
            height: board(36)
        )
    }

    /// Expand the Add Widget frame from toolbar points about the toolbar's board origin; that form is right at every boost.
    func catalogAnchor(toolbarFrame: CGRect, addButtonFrame: CGRect) -> CGRect {
        guard toolbarFrame != .zero, addButtonFrame != .zero else {
            return CGRect(
                x: boardSize.width / 2 - board(40),
                y: toolbarTopInset,
                width: board(80),
                height: board(30)
            )
        }
        return CGRect(
            x: toolbarFrame.minX + addButtonFrame.minX * boost,
            y: toolbarFrame.minY + addButtonFrame.minY * boost,
            width: addButtonFrame.width * boost,
            height: addButtonFrame.height * boost
        )
    }
}
