import CoreGraphics
import Foundation

/// SCREENS.md S4's box arithmetic, kept out of the view so the numbers are testable headlessly.
/// Sizes are window points: the host passes the stage's own `bounds.size`, title bar included.
enum ModalGeometry {
    static let designSize = CGSize(width: 880, height: 560)
    /// The panel hangs from 150 rather than centring, as long as the window is tall enough.
    static let designTop: CGFloat = 150
    static let sideMargin: CGFloat = 24
    static let edgeMargin: CGFloat = 16
    static let previewMargin: CGFloat = 12
    static let bottomBarHeight: CGFloat = 152
    static let headerHeight: CGFloat = 36
    /// R-24 ⑤: both hosts hang the float strip over this panel, so a window too short for `designTop`
    /// stops 12pt under the strip instead of centring into it.
    static var floatClearance: CGFloat {
        FloatLayerGeometry.panelTop + FloatLayerGeometry.panelHeight + 12
    }

    static func panelFrame(in windowSize: CGSize) -> CGRect {
        let width = min(designSize.width, windowSize.width - 2 * sideMargin)
        let fitsAtDesignTop = designTop + designSize.height <= windowSize.height
        let top = fitsAtDesignTop
            ? designTop
            : max(floatClearance, (windowSize.height - designSize.height) / 2)
        let height = min(designSize.height, windowSize.height - top - edgeMargin)
        return CGRect(x: (windowSize.width - width) / 2, y: top, width: width, height: height)
    }

    static func previewSize(inPanel panel: CGRect) -> CGSize {
        CGSize(
            width: panel.width - 2 * previewMargin,
            height: panel.height - headerHeight - previewMargin - bottomBarHeight
        )
    }

    /// SCREENS.md S4 gives the bottom bar one primary and at most two secondary apply buttons;
    /// anything past that only reachable through the "…" menu's own apply submenu.
    static let secondaryButtonLimit = 2

    struct ApplyButtons {
        var primary: ModalDisplayTarget?
        var secondary: [ModalDisplayTarget]
        var overflowCount: Int
    }

    static func applyButtons(targets: [ModalDisplayTarget]) -> ApplyButtons {
        let primary = targets.first(where: \.isPrimary)
        let rest = targets.filter { $0.id != primary?.id }
        return ApplyButtons(
            primary: primary,
            secondary: Array(rest.prefix(secondaryButtonLimit)),
            overflowCount: max(0, rest.count - secondaryButtonLimit)
        )
    }
}

/// ⌘1…⌘9 → display. `shortcutIndex` is the host's left-to-right order, 1-based.
enum ModalKeyMap {
    static func target(forShortcut index: Int, in targets: [ModalDisplayTarget]) -> ModalDisplayTarget? {
        targets.first { $0.shortcutIndex == index }
    }
}

/// Compact preview leaves room for description, metadata and presets at the minimum window size.
enum LibraryDetailGeometry {
    static func panelFrame(in window: CGSize) -> CGRect {
        let size = CGSize(width: min(920, max(1, window.width - 48)), height: min(620, max(1, window.height - 100)))
        return CGRect(x: (window.width - size.width) / 2, y: max(72, (window.height - size.height) / 2), width: size.width, height: size.height)
    }

    static func previewSize(in panel: CGRect) -> CGSize {
        let width = min(360, (panel.width - 72) * 0.44)
        return CGSize(width: width, height: width * 9 / 16)
    }
}
