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

    static func panelFrame(in windowSize: CGSize) -> CGRect {
        let width = min(designSize.width, windowSize.width - 2 * sideMargin)
        let fitsAtDesignTop = designTop + designSize.height <= windowSize.height
        let top = fitsAtDesignTop
            ? designTop
            : max(edgeMargin, (windowSize.height - designSize.height) / 2)
        let height = min(designSize.height, windowSize.height - top - edgeMargin)
        return CGRect(x: (windowSize.width - width) / 2, y: top, width: width, height: height)
    }

    static func previewSize(inPanel panel: CGRect) -> CGSize {
        CGSize(
            width: panel.width - 2 * previewMargin,
            height: panel.height - previewMargin - bottomBarHeight
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
