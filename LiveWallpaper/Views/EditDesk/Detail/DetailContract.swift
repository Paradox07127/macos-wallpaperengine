import CoreGraphics
import Foundation
import SwiftUI

// Seam for M3: the half-immersive display detail. Pure geometry and value types only; the
// shell renders them, the host in `HomePage` drives the flight handshake with the stage.

/// GAP_ANALYSIS.md §8.2 layout B in window points (title bar included, like the stage's `stageSize`):
/// the preview on the left, a resident inspector column on the right.
enum DetailGeometry {
    static let topBarHeight: CGFloat = 56
    static let inspectorWidth: CGFloat = 372
    static let sideMargin: CGFloat = 24
    /// Gap between the hero and the still-frame note, and that note's own height.
    static let heroNoteGap: CGFloat = 12
    static let heroNoteHeight: CGFloat = 24
    /// Fixed 16:9, never the display's own ratio.
    static let heroAspect: CGFloat = 16 / 9

    /// Everything left of the inspector and below the top bar.
    static func stageRect(in windowSize: CGSize) -> CGRect {
        CGRect(
            x: 0, y: topBarHeight,
            width: windowSize.width - inspectorWidth,
            height: windowSize.height - topBarHeight
        )
    }

    /// The hero alone; the note row sits `heroNoteGap` below it and the pair is centred as one block.
    static func heroFrame(in windowSize: CGSize) -> CGRect {
        let stage = stageRect(in: windowSize)
        let verticalBudget = stage.height - 2 * sideMargin - (heroNoteGap + heroNoteHeight)
        let width = min(stage.width - 2 * sideMargin, verticalBudget * heroAspect)
        let height = width / heroAspect
        let blockHeight = height + heroNoteGap + heroNoteHeight
        return CGRect(
            x: stage.minX + (stage.width - width) / 2,
            y: stage.minY + (stage.height - blockHeight) / 2,
            width: width, height: height
        )
    }
}

/// What the detail top bar shows for every display, current one included.
struct DetailDisplayTag: Identifiable, Equatable {
    let id: CGDirectDisplayID
    var name: String
    var thumbnail: CGImage?
    var isCurrent: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.thumbnail === rhs.thumbnail && lhs.isCurrent == rhs.isCurrent
    }
}

/// What the still hero's chips and its HUD transport say; the desktop is the live preview, the
/// hero a frame grab, so `isPlaying` is the desktop session's state, never the still's.
struct DetailHeroStatus: Equatable {
    var title: String
    var kindLine: String
    var isPlaying: Bool
    /// nil hides the `▶ {fps} FPS · GPU {x}%` chip.
    var performanceLine: String?
}

/// The shared-element handshake between the CALayer stage and the SwiftUI hero. The host runs it:
/// `await stage.flyTile(...)` → hero becomes visible → `stage.setTileConcealed(display, true)`;
/// on the way back `setTileConcealed(display, false)` → hero hides → `await stage.returnTile(...)`.
enum DetailTransitionPhase: Equatable {
    case idle
    case flyingIn
    case presented
    case flyingOut
}
