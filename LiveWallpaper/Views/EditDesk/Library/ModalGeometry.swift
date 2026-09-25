import CoreGraphics
import Foundation

/// The detail modal's box arithmetic, kept out of the view so the numbers are testable headlessly.
/// Sizes are window points: the host passes the stage's own `bounds.size`, title bar included.
enum ModalGeometry {
    static let maximumSize = CGSize(width: 920, height: 680)
    static let sideMargin: CGFloat = 24
    /// Window height the panel leaves free, split above and below it when centred.
    static let verticalAllowance: CGFloat = 100
    /// Clear of the 56pt top bar; a short window pays in height, never in this floor.
    static let minimumTop: CGFloat = 72

    static func panelFrame(in windowSize: CGSize) -> CGRect {
        let width = max(1, min(maximumSize.width, windowSize.width - 2 * sideMargin))
        let height = max(1, min(maximumSize.height, windowSize.height - verticalAllowance))
        return CGRect(
            x: (windowSize.width - width) / 2, y: max(minimumTop, (windowSize.height - height) / 2),
            width: width, height: height
        )
    }

    // MARK: Inside the panel

    static let horizontalPadding: CGFloat = 24
    static let topPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 20
    /// Between the title row and the body, and between the body and the bottom buttons.
    static let sectionGap: CGFloat = 16
    /// The slot a large glass icon button takes: the title row's floor and each ← → beside the preview.
    static let iconButtonSize: CGFloat = 28
    /// Where the panel closure's content starts under a one-line title.
    static var contentTop: CGFloat {
        topPadding + iconButtonSize + sectionGap
    }

    /// 4:3 holds a square Workshop preview at 255×255 and a 16:9 video at 340×191, neither cropped.
    static let previewSize = CGSize(width: 340, height: 255)
    /// Between each ← → button and the preview it flanks.
    static let arrowGap: CGFloat = 8
    static let columnSpacing: CGFloat = 24
    static let sidebarSpacing: CGFloat = 20
    /// The transfer line over the bottom buttons: wide enough for a status and `42% · 40 MB / 95.5 MB · 12 MB/s`.
    static let statusWidth: CGFloat = 560

    /// One primary and at most two secondary apply buttons; the rest go in the Other Displays menu.
    static let secondaryButtonLimit = 2

    struct ApplyButtons {
        var primary: ModalDisplayTarget?
        var secondary: [ModalDisplayTarget]
        var overflow: [ModalDisplayTarget]

        var overflowCount: Int {
            overflow.count
        }
    }

    static func applyButtons(targets: [ModalDisplayTarget]) -> ApplyButtons {
        let primary = targets.first(where: \.isPrimary)
        let rest = targets.filter { $0.id != primary?.id }
        return ApplyButtons(
            primary: primary,
            secondary: Array(rest.prefix(secondaryButtonLimit)),
            overflow: Array(rest.dropFirst(secondaryButtonLimit))
        )
    }
}

/// ⌘1…⌘9 → display. `shortcutIndex` is the host's left-to-right order, 1-based.
enum ModalKeyMap {
    static func target(forShortcut index: Int, in targets: [ModalDisplayTarget]) -> ModalDisplayTarget? {
        targets.first { $0.shortcutIndex == index }
    }
}
