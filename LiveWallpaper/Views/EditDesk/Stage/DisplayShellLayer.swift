import AppKit
import LiveWallpaperCore
import QuartzCore

@MainActor
final class DisplayShellLayer {
    let layer = CALayer()
    let content = CALayer()
    let cover = CALayer()
    private let shell = CAShapeLayer()
    private let stand = CALayer()
    private let base = CALayer()
    private let notch = CAShapeLayer()
    private let badge = CATextLayer()
    private let gradient = CAGradientLayer()
    private let title = CATextLayer()
    private let meta = CATextLayer()
    private let name = CATextLayer()
    private let status = CATextLayer()
    private let dot = CAShapeLayer()
    private let veil = CALayer()
    private let stateGroup = CALayer()
    private let stateLabel = CATextLayer()
    private var stateWidth: CGFloat = 0
    private let stateSymbol = CALayer()
    private let playback = CALayer()
    private let buttons = [CALayer(), CALayer(), CALayer()]
    private let highlight = CALayer()
    private let hint = CATextLayer()
    /// Read by the palette test: the stage keeps resolved CGColors, so an appearance flip that
    /// does not reach this one leaves the whole layer tree painted for the old appearance.
    private(set) var normalStroke: CGColor?
    private var hotStroke: CGColor?
    private(set) var display: StageDisplay?
    private var layoutRect: CGRect?
    private var layoutBuiltin: Bool?
    private var coverFade: (layer: CALayer, elapsed: TimeInterval, duration: TimeInterval)?
    private var playbackElapsed: TimeInterval = 0
    private var playbackFrom: Float = 0
    private var playbackTarget: Float = 0
    private var hoverMix: CGFloat = 0
    private var hoverFrom: CGFloat = 0
    private var hoverElapsed: TimeInterval = 0
    private var dropElapsed: TimeInterval = 0
    private var dropFrom: Float = 0
    private var dropTarget: Float = 0
    var frame: CGRect {
        layer.frame
    }

    var hasAnimation: Bool {
        coverFade != nil || playback.opacity != playbackTarget || highlight.opacity != dropTarget
            || abs(hoverMix - CGFloat(playbackTarget)) > 0.001
    }

    init() {
        for child in [shell, stand, base, content, notch, badge, dot, name, status, highlight] {
            layer.addSublayer(child)
        }
        content.masksToBounds = true
        content.cornerRadius = DesignTokens.EditDesk.Corner.content
        for child in [cover, gradient, title, meta, playback, veil, stateGroup] {
            content.addSublayer(child)
        }
        stateGroup.addSublayer(stateLabel)
        stateGroup.addSublayer(stateSymbol)
        stateGroup.cornerRadius = DesignTokens.EditDesk.Corner.capsule
        cover.contentsGravity = .resizeAspectFill
        cover.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        for (index, button) in buttons.enumerated() {
            playback.addSublayer(button)
            button.cornerRadius = DesignTokens.EditDesk.Corner.playbackControl
            button.borderWidth = 1
            button.contentsGravity = .center
            button.frame = CGRect(x: index * 30, y: 0, width: 26, height: 26)
        }
        playback.opacity = 0
        highlight.opacity = 0
        highlight.borderWidth = 2
        highlight.addSublayer(hint)
        StageLayerStyle.text(badge, size: 11, mono: true)
        StageLayerStyle.text(title, size: 15, weight: .semibold)
        StageLayerStyle.text(meta, size: 11, mono: true)
        StageLayerStyle.text(name, size: 14, weight: .semibold)
        StageLayerStyle.text(status, size: 12, mono: true)
        StageLayerStyle.text(stateLabel, size: 11, mono: true)
        StageLayerStyle.text(hint, size: 15, weight: .bold)
        hint.alignmentMode = .center
        badge.alignmentMode = .center
        badge.cornerRadius = DesignTokens.EditDesk.Corner.badge
        badge.borderWidth = 1
        badge.masksToBounds = true
        shell.lineWidth = 1
    }

    func update(display: StageDisplay, dropHint: String) {
        if self.display?.cover !== display.cover, coverFade == nil {
            cover.contents = display.cover
        }
        self.display = display
        layoutRect = nil
        let colors = DesignTokens.EditDesk.Colors.self
        normalStroke = NSColor(colors.strokeShell).cgColor
        hotStroke = NSColor(colors.strokeHotShell).cgColor
        shell.strokeColor = normalStroke
        shell.fillColor = NSColor(colors.fillShell).cgColor
        shell.shadowColor = NSColor(DesignTokens.EditDesk.Shadow.shell.color).cgColor
        shell.shadowRadius = DesignTokens.EditDesk.Shadow.shell.radius
        shell.shadowOffset = CGSize(width: 0, height: DesignTokens.EditDesk.Shadow.shell.y)
        // An empty display is a dashed outline, not an object, so it has nothing to cast.
        shell.shadowOpacity = display.state == .empty ? 0 : 1
        stand.backgroundColor = NSColor(colors.strokeShell).withAlphaComponent(0.28).cgColor
        base.backgroundColor = stand.backgroundColor
        notch.fillColor = NSColor(colors.background).cgColor
        badge.string = display.badgeText
        badge.backgroundColor = NSColor(colors.background).cgColor
        badge.borderColor = NSColor(colors.strokeBadge).cgColor
        badge.foregroundColor = NSColor(colors.textCapsule).cgColor
        title.string = display.name
        title.foregroundColor = StageLayerStyle.white
        meta.string = display.statusText
        meta.foregroundColor = NSColor(cgColor: StageLayerStyle.white)?.withAlphaComponent(0.7).cgColor
        name.string = display.name
        name.foregroundColor = NSColor(colors.textPrimary).cgColor
        status.string = display.statusText
        status.foregroundColor = NSColor(colors.textSecondary).cgColor
        dot.fillColor = NSColor(colors.success).cgColor
        gradient.colors = [StageLayerStyle.clear, NSColor(colors.gradientStageBottom).cgColor]
        veil.backgroundColor = NSColor(colors.gradientCardBottom).cgColor
        highlight.backgroundColor = NSColor(colors.dropHighlight).cgColor
        highlight.borderColor = NSColor(colors.success).cgColor
        highlight.shadowColor = NSColor(colors.dropHighlightGlow).cgColor
        highlight.shadowRadius = 40
        highlight.shadowOpacity = 1
        hint.string = dropHint
        hint.foregroundColor = StageLayerStyle.white
        for (index, symbol) in ["backward.fill", "pause.fill", "forward.fill"].enumerated() {
            let button = buttons[index]
            button.backgroundColor = index == 1 ? StageLayerStyle.white : NSColor(colors.playbackControlFill).cgColor
            button.borderColor = NSColor(colors.strokeBadge).withAlphaComponent(0.2).cgColor
            let tint = NSColor(cgColor: index == 1 ? StageLayerStyle.black : StageLayerStyle.white) ?? NSColor(colors.textPrimary)
            button.contents = StageLayerStyle.symbol(symbol, tint: tint)
        }
        veil.isHidden = true
        stateGroup.backgroundColor = NSColor(colors.background).cgColor
        stateGroup.isHidden = true
        stateLabel.isHidden = true
        stateSymbol.isHidden = true
        playback.isHidden = display.state == .empty
        cover.isHidden = display.state == .empty
        gradient.isHidden = display.state == .empty
        title.isHidden = display.state == .empty
        meta.isHidden = display.state == .empty
        shell.lineDashPattern = display.state == .empty ? [5, 4] : nil
        switch display.state {
        case let .failed(chip):
            stateGroup.isHidden = false
            stateLabel.isHidden = false
            stateSymbol.isHidden = false
            stateLabel.string = chip.text
            stateLabel.foregroundColor = chip.tint
            stateSymbol.contents = StageLayerStyle.symbol(chip.symbol, tint: NSColor(cgColor: chip.tint) ?? NSColor(colors.danger))
        case let .paused(reasonText):
            veil.isHidden = false
            stateGroup.isHidden = false
            stateLabel.isHidden = false
            stateSymbol.isHidden = false
            stateLabel.string = reasonText
            stateLabel.foregroundColor = NSColor(colors.textCapsule).cgColor
            stateSymbol.contents = StageLayerStyle.symbol("pause.fill", tint: NSColor(colors.textCapsule))
        case .ok, .empty:
            break
        }
        stateWidth = StageLayerStyle.width(stateLabel.string as? String ?? "", size: 11, mono: true) + 36
    }

    func place(content rect: CGRect, isBuiltin: Bool) {
        guard layoutRect != rect || layoutBuiltin != isBuiltin else { return }
        layoutRect = rect
        layoutBuiltin = isBuiltin
        layer.frame = StageGeometry.shellRect(content: rect, isBuiltin: isBuiltin)
        let local = rect.offsetBy(dx: -layer.frame.minX, dy: -layer.frame.minY)
        content.frame = local
        layoutContent()
        let top = isBuiltin ? DesignTokens.EditDesk.Corner.shellBuiltinTop : DesignTokens.EditDesk.Corner.shell
        let bottom = isBuiltin ? DesignTokens.EditDesk.Corner.shellBuiltinBottom : DesignTokens.EditDesk.Corner.shell
        shell.frame = layer.bounds
        shell.path = StageLayerStyle.roundedPath(shell.bounds, top: top, bottom: bottom)
        shell.shadowPath = shell.path
        stand.isHidden = isBuiltin
        stand.frame = CGRect(x: layer.bounds.midX - 1, y: layer.bounds.maxY, width: 2, height: 22)
        // Clamped to the shell: a wider base would reach into the neighbouring display's gap.
        let baseWidth = min(isBuiltin ? 400 : 120, layer.bounds.width)
        base.frame = CGRect(
            x: layer.bounds.midX - baseWidth / 2, y: layer.bounds.maxY + (isBuiltin ? 2 : 22),
            width: baseWidth, height: 1
        )
        notch.isHidden = !isBuiltin
        notch.frame = CGRect(x: layer.bounds.midX - 30, y: local.minY, width: 60, height: 8)
        notch.path = StageLayerStyle.roundedPath(notch.bounds, top: 0, bottom: DesignTokens.EditDesk.Corner.notch)
        badge.frame = CGRect(
            x: 10, y: -StageGeometry.badgeOverhang,
            width: StageLayerStyle.width(display?.badgeText ?? "", size: 11, mono: true) + 14,
            height: StageGeometry.badgeHeight
        )
        // SCREENS S1: the name row sits 8pt under the stand + base (external) or the keyboard line (MacBook).
        let nameY = layer.bounds.height
            + (isBuiltin ? StageGeometry.builtinStandDrop : StageGeometry.externalStandDrop)
            + StageGeometry.nameRowGap
        dot.path = CGPath(ellipseIn: CGRect(x: 0, y: nameY + 6, width: 7, height: 7), transform: nil)
        let nameWidth = StageLayerStyle.width(display?.name ?? "", size: 14)
        name.frame = CGRect(x: 15, y: nameY, width: nameWidth + 8, height: StageGeometry.nameRowHeight)
        status.frame = CGRect(
            x: name.frame.maxX + 8, y: nameY + 2,
            width: max(0, local.width - name.frame.maxX - 8), height: 16
        )
        highlight.frame = layer.bounds
        highlight.cornerRadius = top
        highlight.shadowPath = shell.path
        hint.frame = CGRect(x: 8, y: layer.bounds.midY - 10, width: layer.bounds.width - 16, height: 20)
    }

    func layoutContent() {
        let size = content.bounds.size
        cover.frame = content.bounds
        coverFade?.layer.frame = content.bounds
        gradient.frame = CGRect(x: 0, y: size.height - 78, width: size.width, height: 78)
        title.frame = CGRect(x: 10, y: size.height - 44, width: size.width - 20, height: 19)
        meta.frame = CGRect(x: 10, y: size.height - 23, width: size.width - 110, height: 15)
        playback.frame = CGRect(x: size.width - 96, y: size.height - 35, width: 86, height: 26)
        veil.frame = content.bounds
        let width = min(stateWidth, max(0, size.width - 20))
        let paused = if case .paused = display?.state {
            true
        } else {
            false
        }
        stateGroup.frame = CGRect(x: paused ? size.width - width - 10 : 10, y: 8, width: width, height: 22)
        stateLabel.frame = CGRect(x: 27, y: 3, width: max(0, width - 34), height: 16)
        stateSymbol.frame = CGRect(x: 8, y: 5, width: 13, height: 13)
    }

    func restoreContent() {
        content.removeFromSuperlayer()
        layer.insertSublayer(content, below: notch)
        content.cornerRadius = DesignTokens.EditDesk.Corner.content
        layoutRect = nil
    }

    func setHovered(_ hovered: Bool) {
        let target: Float = hovered ? 1 : 0
        guard target != playbackTarget else { return }
        playbackFrom = playback.opacity
        playbackTarget = target
        playbackElapsed = hovered ? 0 : -0.3
        hoverFrom = hoverMix
        hoverElapsed = 0
    }

    func setDropTarget(_ targeted: Bool) {
        let target: Float = targeted ? 1 : 0
        guard target != dropTarget else { return }
        dropFrom = highlight.opacity
        dropTarget = target
        dropElapsed = 0
    }

    func playbackAction(at point: CGPoint) -> StagePlaybackAction? {
        guard !playback.isHidden, playback.opacity > 0 else { return nil }
        let local = CGPoint(x: point.x - content.frame.minX - playback.frame.minX, y: point.y - content.frame.minY - playback.frame.minY)
        guard let index = buttons.firstIndex(where: { $0.frame.contains(local) }) else { return nil }
        return [StagePlaybackAction.previous, .toggle, .next][index]
    }

    func crossfade(to image: CGImage, duration: TimeInterval) {
        if let fade = coverFade {
            cover.contents = fade.layer.contents
            fade.layer.removeFromSuperlayer()
        }
        guard duration > 0 else {
            cover.contents = image
            coverFade = nil
            return
        }
        let next = CALayer()
        next.contents = image
        next.contentsGravity = .resizeAspectFill
        next.frame = content.bounds
        next.opacity = 0
        content.insertSublayer(next, above: cover)
        coverFade = (next, 0, duration)
    }

    func step(dt: TimeInterval, reduceMotion: Bool) {
        playbackElapsed += dt
        let playbackDuration = reduceMotion ? 0.15 : 0.2
        let playbackMix = Float(min(1, max(0, playbackElapsed / playbackDuration)))
        playback.opacity = playbackFrom + (playbackTarget - playbackFrom) * playbackMix
        hoverElapsed += dt
        let hoverStep = CGFloat(min(1, max(0, hoverElapsed / (reduceMotion ? 0.15 : 0.22))))
        hoverMix = hoverStep >= 1 ? CGFloat(playbackTarget) : hoverFrom + (CGFloat(playbackTarget) - hoverFrom) * hoverStep
        // Hover reads as a lift, not a zoom: scaling a display would distort the wallpaper in it.
        layer.transform = CATransform3DMakeTranslation(0, reduceMotion ? 0 : -3 * hoverMix, 0)
        dropElapsed += dt
        let dropMix = min(1, dropElapsed / (reduceMotion ? 0.15 : 0.18))
        let eased = Float(reduceMotion ? dropMix : 1 - pow(1 - dropMix, 3))
        highlight.opacity = dropFrom + (dropTarget - dropFrom) * eased
        shell.strokeColor = highlight.opacity > 0 || hoverMix > 0.5 ? hotStroke : normalStroke
        if var fade = coverFade {
            fade.elapsed += dt
            fade.layer.opacity = Float(min(1, fade.elapsed / fade.duration))
            if fade.elapsed >= fade.duration {
                cover.contents = fade.layer.contents
                fade.layer.removeFromSuperlayer()
                coverFade = nil
            } else {
                coverFade = fade
            }
        }
    }
}
