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
    static func stageRect(in windowSize: CGSize, inspectorWidth: CGFloat = Self.inspectorWidth) -> CGRect {
        CGRect(
            x: 0, y: topBarHeight,
            width: windowSize.width - inspectorWidth,
            height: windowSize.height - topBarHeight
        )
    }

    static func overlayFrame(in windowSize: CGSize, logicalSize: CGSize, topInset: CGFloat = 0) -> CGRect {
        guard topInset > 0 else {
            return OverlayGeometry.aspectFit(logicalSize: logicalSize, in: heroFrame(in: windowSize))
        }
        let stage = stageRect(in: windowSize)
        let available = CGRect(
            x: stage.minX + sideMargin, y: stage.minY + topInset + sideMargin,
            width: max(1, stage.width - 2 * sideMargin),
            height: max(1, stage.height - topInset - 2 * sideMargin)
        )
        return OverlayGeometry.aspectFit(logicalSize: logicalSize, in: available)
    }

    /// The hero alone; the note row sits `heroNoteGap` below it and the pair is centred as one block.
    static func heroFrame(in windowSize: CGSize, inspectorWidth: CGFloat = Self.inspectorWidth) -> CGRect {
        let stage = stageRect(in: windowSize, inspectorWidth: inspectorWidth)
        let verticalBudget = max(1, stage.height - 2 * sideMargin)
        let width = max(1, min(stage.width - 2 * sideMargin, verticalBudget * heroAspect))
        let height = width / heroAspect
        let blockHeight = height
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

/// What the wallpaper column shows: an inspected attempt takes the whole column, the two failure
/// notices sit above the empty setup or the hero.
enum DetailPreviewState: Equatable {
    case empty, preparing, prepareFailed, lastAttemptFailed, runtimeError, hero

    /// `attempt` is the display's load attempt whether or not it is inspected; `applying` is an apply
    /// from the Edit Desk still waiting on this display.
    static func resolve(
        hasConfiguration: Bool, attempt: WallpaperLoadAttempt?, hasRuntimeError: Bool, applying: Bool = false
    ) -> Self {
        if let attempt, attempt.isInspecting {
            return attempt.phase == .failed ? .prepareFailed : .preparing
        }
        if applying {
            return .preparing
        }
        if attempt?.phase == .failed {
            return .lastAttemptFailed
        }
        if hasRuntimeError {
            return .runtimeError
        }
        return hasConfiguration ? .hero : .empty
    }

    var showsAttempt: Bool {
        self == .preparing || self == .prepareFailed
    }

    /// Whether a runtime error, when the display has one, gets its banner. It is independent of a failed
    /// attempt, so it also stands under that notice; only an attempt's page, which fills the column, hides it.
    var showsRuntimeError: Bool {
        !showsAttempt
    }
}

/// What the still hero's chips and its HUD transport say; the desktop is the live preview, the
/// hero a frame grab, so the transport follows the desktop session, never the still.
struct DetailHeroStatus: Equatable {
    var title: String
    var kindLine: String
    /// The user's play intent, which a policy pause leaves set; nil when no player is running.
    var intendsToPlay: Bool?
    /// Why a policy holds the desktop session stopped; nil while none does.
    var pauseReason: String?
    /// nil hides the `▶ {fps} FPS · GPU {x}%` chip.
    var performanceLine: String?
    var canNavigatePlaylist = false
}
