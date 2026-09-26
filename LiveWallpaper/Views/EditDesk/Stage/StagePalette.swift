import AppKit
import LiveWallpaperCore
import SwiftUI

/// Every token colour the stage's layers draw, resolved under the window's appearance: updates reach
/// the layers outside drawing callbacks too, where resolving a token would use the thread's appearance.
struct StagePalette {
    let shellStroke: CGColor
    let emptyShellStroke: CGColor
    let strokeHotShell: CGColor
    let fillShell: CGColor
    let shellShadow: CGColor
    let stand: CGColor
    let background: CGColor
    let strokeBadge: CGColor
    let textCapsule: CGColor
    let textPrimary: CGColor
    let textSecondary: CGColor
    let textTertiary: CGColor
    let status: CGColor
    let gradientStageBottom: CGColor
    let gradientCardBottom: CGColor
    let dropHighlight: CGColor
    let dropHighlightGlow: CGColor
    let success: CGColor
    let warning: CGColor
    let failureFatal: CGColor
    let failureBlocked: CGColor
    let failureNeedsParts: CGColor
    let playbackControlFill: CGColor
    let playbackStroke: CGColor
    let fillEmptyScreen: CGColor
    let emptyScreenPlaceholder: CGColor
    let surfaceRaised: CGColor
    let cardRimRing: CGColor
    let cardRimHighlight: CGColor
    let cardRimShade: CGColor
    let spine: CGColor
    let folderTab: CGColor
    let gridStroke: CGColor
    let shelfCardShadow: CGColor
    let shelfCardHoverShadow: CGColor
    let shelfCardEdgeShadow: CGColor
    let mediaChipFill: CGColor
    let nowPlayingGlyph: CGColor
    let hoverCardShadow: CGColor
    let focusRing: CGColor

    init(appearance: NSAppearance, increasedContrast: Bool) {
        func resolve(_ color: Color, alpha: CGFloat? = nil) -> CGColor {
            var resolved = CGColor(gray: 0, alpha: 0)
            appearance.performAsCurrentDrawingAppearance {
                let nsColor = NSColor(color)
                resolved = (alpha.map(nsColor.withAlphaComponent) ?? nsColor).cgColor
            }
            return resolved
        }
        let colors = DesignTokens.EditDesk.Colors.self
        let shadows = DesignTokens.EditDesk.Shadow.self
        shellStroke = resolve(increasedContrast ? colors.strokeShellIncreased : colors.strokeShell)
        emptyShellStroke = resolve(increasedContrast ? colors.strokeEmptyShellIncreased : colors.strokeEmptyShell)
        strokeHotShell = resolve(colors.strokeHotShell)
        fillShell = resolve(colors.fillShell)
        shellShadow = resolve(shadows.shell.color)
        stand = resolve(colors.strokeShell, alpha: 0.28)
        background = resolve(colors.background)
        strokeBadge = resolve(colors.strokeBadge)
        textCapsule = resolve(colors.textCapsule)
        textPrimary = resolve(colors.textPrimary)
        textSecondary = resolve(colors.textSecondary)
        textTertiary = resolve(colors.textTertiary)
        status = increasedContrast ? textCapsule : textSecondary
        gradientStageBottom = resolve(colors.gradientStageBottom)
        gradientCardBottom = resolve(colors.gradientCardBottom)
        dropHighlight = resolve(colors.dropHighlight)
        dropHighlightGlow = resolve(colors.dropHighlightGlow)
        success = resolve(colors.success)
        warning = resolve(colors.warning)
        failureFatal = resolve(WallpaperFailureClass.fatal.tint)
        failureBlocked = resolve(WallpaperFailureClass.blocked.tint)
        failureNeedsParts = resolve(WallpaperFailureClass.needsParts.tint)
        playbackControlFill = resolve(colors.playbackControlFill)
        playbackStroke = resolve(colors.strokeBadge, alpha: 0.2)
        fillEmptyScreen = resolve(colors.fillEmptyScreen)
        emptyScreenPlaceholder = resolve(colors.emptyScreenPlaceholder)
        surfaceRaised = resolve(DesignTokens.Colors.surfaceRaised)
        cardRimRing = resolve(increasedContrast ? colors.cardRimRingIncreased : colors.cardRimRing)
        cardRimHighlight = resolve(colors.cardRimHighlight)
        cardRimShade = resolve(colors.cardRimShade)
        spine = resolve(colors.strokeHotShell, alpha: 0.55)
        folderTab = resolve(colors.strokeHotShell, alpha: 0.2)
        gridStroke = resolve(Color.primary.opacity(DesignTokens.Card.strokeOpacity))
        shelfCardShadow = resolve(shadows.shelfCard.color)
        shelfCardHoverShadow = resolve(shadows.shelfCardHover.color)
        shelfCardEdgeShadow = resolve(shadows.shelfCardEdge.color)
        mediaChipFill = resolve(colors.mediaChipFill)
        nowPlayingGlyph = resolve(colors.nowPlayingGlyph)
        hoverCardShadow = resolve(shadows.hoverCard.color)
        focusRing = resolve(Color(nsColor: .keyboardFocusIndicatorColor))
    }

    func tint(for failure: WallpaperFailureClass) -> CGColor {
        switch failure {
        case .fatal: failureFatal
        case .blocked: failureBlocked
        case .needsParts: failureNeedsParts
        }
    }
}
