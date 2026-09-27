import CoreGraphics
import Foundation
import LiveWallpaperCore
import SwiftUI

/// The detail modal's box arithmetic, kept out of the view so the numbers are testable headlessly.
/// Sizes are window points: the host passes the stage's own `bounds.size`, title bar included.
enum ModalGeometry {
    static let maximumSize = CGSize(width: 920, height: 680)
    /// Window height the panel leaves free, split above and below it when centred.
    static let verticalAllowance: CGFloat = 100
    /// Clear of the 56pt top bar; a short window pays in height, never in this floor.
    static let minimumTop: CGFloat = 72

    static func panelFrame(in windowSize: CGSize) -> CGRect {
        let width = max(1, min(maximumSize.width, windowSize.width - 2 * arrowGutter))
        let height = max(1, min(maximumSize.height, windowSize.height - verticalAllowance))
        return CGRect(
            x: (windowSize.width - width) / 2, y: max(minimumTop, (windowSize.height - height) / 2),
            width: width, height: height
        )
    }

    // MARK: Beside the panel

    /// Between each ← → button and the side of the panel it sits by.
    static let arrowGap: CGFloat = 16
    /// An arrow with a gap either side: 60pt, all a 1040pt window leaves beside the 920pt panel.
    static var arrowGutter: CGFloat {
        2 * arrowGap + iconButtonSize
    }

    /// ← and → on the scrim, level with the panel's middle.
    static func arrowFrames(beside panel: CGRect) -> (previous: CGRect, next: CGRect) {
        let y = panel.midY - iconButtonSize / 2
        return (
            CGRect(x: panel.minX - arrowGap - iconButtonSize, y: y, width: iconButtonSize, height: iconButtonSize),
            CGRect(x: panel.maxX + arrowGap, y: y, width: iconButtonSize, height: iconButtonSize)
        )
    }

    // MARK: Inside the panel

    static let horizontalPadding: CGFloat = 24
    static let topPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 20
    /// Between the title row and the body, and between the body and the bottom buttons.
    static let sectionGap: CGFloat = 16
    /// The slot a large glass icon button takes: the title row's floor and each ← → beside the panel.
    static let iconButtonSize = DesignTokens.iconButtonDiameter(.large)
    /// Where the panel closure's content starts under a one-line title.
    static var contentTop: CGFloat {
        topPadding + iconButtonSize + sectionGap
    }

    /// 4:3 holds a square Workshop preview at 255×255 and a 16:9 video at 340×191, neither cropped.
    static let previewSize = CGSize(width: 340, height: 255)
    /// Device pixels per source pixel at most: 2× shows a 1× picture at its usual size on a Retina display.
    static let maximumPreviewMagnification: CGFloat = 2
    /// The preview's column narrows no further: a typical Workshop Stats row stays one line in English and Chinese.
    static let leadingColumnFloor: CGFloat = 304
    static let columnSpacing: CGFloat = 24
    static let sidebarSpacing: CGFloat = 20
    /// The transfer line over the bottom buttons: wide enough for a status and `42% · 40 MB / 95.5 MB · 12 MB/s`.
    static let statusWidth: CGFloat = 560

    /// One primary and at most two secondary apply buttons, or three plain ones when no display leads;
    /// the rest go in the Other Displays menu.
    static let secondaryButtonLimit = 2

    struct ApplyButtons {
        var primary: ModalDisplayTarget?
        var secondary: [ModalDisplayTarget]
        var overflow: [ModalDisplayTarget]

        var overflowCount: Int {
            overflow.count
        }
    }

    /// A preview as drawn: `size` in points; `isLowResolution` when fitting the box would enlarge it past the cap.
    struct PreviewFit: Equatable {
        var size: CGSize
        var isLowResolution: Bool
    }

    /// The whole picture fitted into `previewSize`, held to `maximumPreviewMagnification`. `pixels` is the image's
    /// own size, `scale` the backing scale of the screen it is drawn on.
    static func previewFit(pixels: CGSize, scale: CGFloat) -> PreviewFit {
        let fit = min(previewSize.width / pixels.width, previewSize.height / pixels.height)
        let cap = maximumPreviewMagnification / scale
        let points = min(fit, cap)
        return PreviewFit(size: CGSize(width: pixels.width * points, height: pixels.height * points), isLowResolution: fit > cap)
    }

    /// The left column: as wide as the preview's box, and no narrower than the fact rows need.
    static func leadingColumnWidth(preview: CGSize) -> CGFloat {
        max(preview.width, leadingColumnFloor)
    }

    static func applyButtons(targets: [ModalDisplayTarget]) -> ApplyButtons {
        let primary = targets.first(where: \.isPrimary)
        let rest = targets.filter { $0.id != primary?.id }
        let plainCount = primary == nil ? secondaryButtonLimit + 1 : secondaryButtonLimit
        return ApplyButtons(
            primary: primary,
            secondary: Array(rest.prefix(plainCount)),
            overflow: Array(rest.dropFirst(plainCount))
        )
    }
}

/// ⌘1…⌘9 → display. `shortcutIndex` is the host's left-to-right order, 1-based.
enum ModalKeyMap {
    static func target(forShortcut index: Int, in targets: [ModalDisplayTarget]) -> ModalDisplayTarget? {
        targets.first { $0.shortcutIndex == index }
    }
}
