import AppKit
import LiveWallpaperCore
import QuartzCore

@MainActor
final class DisplayShellLayer {
    let layer = CALayer()
    let content = CALayer()
    /// Holds the cover and whatever `crossfade` puts on top of it, and nothing else: the hover
    /// zoom is written here, so the two images stay framed alike while text and controls hold still.
    let coverGroup = CALayer()
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
    private let empty = CALayer()
    private let emptySymbol = CALayer()
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
    /// Seconds into a rejected drop's shake; nil while the display is still.
    private var shakeElapsed: TimeInterval?
    var frame: CGRect {
        layer.frame
    }

    var hasAnimation: Bool {
        coverFade != nil || playback.opacity != playbackTarget || highlight.opacity != dropTarget
            || abs(hoverMix - CGFloat(playbackTarget)) > 0.001 || shakeElapsed != nil
    }

    init() {
        for child in [shell, stand, base, content, notch, badge, dot, name, status, highlight] {
            layer.addSublayer(child)
        }
        content.masksToBounds = true
        content.cornerRadius = DesignTokens.EditDesk.Corner.content
        content.cornerCurve = .continuous
        for child in [coverGroup, gradient, title, meta, playback, veil, stateGroup, empty] {
            content.addSublayer(child)
        }
        coverGroup.addSublayer(cover)
        empty.addSublayer(emptySymbol)
        emptySymbol.contentsGravity = .resizeAspect
        stateGroup.addSublayer(stateLabel)
        stateGroup.addSublayer(stateSymbol)
        cover.contentsGravity = .resizeAspectFill
        cover.masksToBounds = true
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        for button in buttons {
            playback.addSublayer(button)
            button.contentsGravity = .center
        }
        playback.borderWidth = 1
        playback.opacity = 0
        highlight.opacity = 0
        highlight.borderWidth = 2
        highlight.addSublayer(hint)
        StageLayerStyle.text(badge, size: 12, mono: true)
        StageLayerStyle.text(title, size: 17, weight: .semibold)
        StageLayerStyle.text(meta, size: 12, mono: true)
        StageLayerStyle.text(name, size: 15, weight: .semibold)
        StageLayerStyle.text(status, size: 13, mono: true)
        StageLayerStyle.text(stateLabel, size: 12, mono: true)
        StageLayerStyle.text(hint, size: 17, weight: .bold)
        // The name is the one line that may not shrink, so it loses its middle rather than its end.
        name.truncationMode = .middle
        title.truncationMode = .end
        hint.alignmentMode = .center
        badge.alignmentMode = .center
        badge.cornerRadius = DesignTokens.EditDesk.Corner.badge
        badge.borderWidth = 1
        badge.masksToBounds = true
        shell.lineWidth = 1
    }

    func update(display: StageDisplay, dropHint: String, increasedContrast: Bool) {
        if self.display?.cover !== display.cover, coverFade == nil {
            cover.contents = display.cover
        }
        self.display = display
        layoutRect = nil
        let colors = DesignTokens.EditDesk.Colors.self
        let shellStroke = if display.state == .empty {
            increasedContrast ? colors.strokeEmptyShellIncreased : colors.strokeEmptyShell
        } else {
            increasedContrast ? colors.strokeShellIncreased : colors.strokeShell
        }
        normalStroke = NSColor(shellStroke).cgColor
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
        title.string = display.wallpaperTitle
        title.foregroundColor = StageLayerStyle.white
        meta.string = display.wallpaperKind
        meta.foregroundColor = NSColor(cgColor: StageLayerStyle.white)?.withAlphaComponent(0.7).cgColor
        name.string = display.name
        name.foregroundColor = NSColor(colors.textPrimary).cgColor
        status.string = display.statusText
        status.foregroundColor = NSColor(increasedContrast ? colors.textCapsule : colors.textSecondary).cgColor
        dot.fillColor = Self.statusDotColor(for: display.state)
        gradient.colors = [StageLayerStyle.clear, NSColor(colors.gradientStageBottom).cgColor]
        veil.backgroundColor = NSColor(colors.gradientCardBottom).cgColor
        highlight.backgroundColor = NSColor(colors.dropHighlight).cgColor
        highlight.borderColor = NSColor(colors.success).cgColor
        highlight.shadowColor = NSColor(colors.dropHighlightGlow).cgColor
        highlight.shadowRadius = 40
        highlight.shadowOpacity = 1
        hint.string = dropHint
        hint.foregroundColor = StageLayerStyle.white
        playback.backgroundColor = NSColor(colors.playbackControlFill).cgColor
        playback.borderColor = NSColor(colors.strokeBadge).withAlphaComponent(0.2).cgColor
        for (index, glyph) in ["backward.fill", display.playbackGlyph, "forward.fill"].enumerated() {
            let button = buttons[index]
            button.backgroundColor = index == 1 ? StageLayerStyle.white : nil
            let tint = NSColor(cgColor: index == 1 ? StageLayerStyle.black : StageLayerStyle.white) ?? NSColor(colors.textPrimary)
            button.contents = StageLayerStyle.symbol(glyph, tint: tint)
            button.isHidden = true
        }
        for item in transport {
            item.layer.isHidden = false
            item.layer.opacity = item.enabled ? 1 : Float(DesignTokens.Opacity.dimmedContent)
        }
        empty.backgroundColor = NSColor(colors.fillEmptyScreen).cgColor
        emptySymbol.contents = StageLayerStyle.symbol(
            "photo", tint: NSColor(colors.emptyScreenPlaceholder),
            pointSize: StageGeometry.emptyScreenSymbolMaxSide
        )
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
        case let .paused(text), let .preparing(text), let .off(text):
            veil.isHidden = false
            stateGroup.isHidden = false
            stateLabel.isHidden = false
            stateSymbol.isHidden = false
            stateLabel.string = text
            stateLabel.foregroundColor = NSColor(colors.textCapsule).cgColor
            let glyph = switch display.state {
            case .preparing: "hourglass"
            case .off: "power"
            default: "pause.fill"
            }
            stateSymbol.contents = StageLayerStyle.symbol(glyph, tint: NSColor(colors.textCapsule))
        case .ok, .empty:
            break
        }
        stateWidth = StageLayerStyle.width(stateLabel.string as? String ?? "", size: 12, mono: true) + 36
    }

    /// The name row's dot: green only while the wallpaper runs.
    static func statusDotColor(for state: StageDisplay.State) -> CGColor {
        let colors = DesignTokens.EditDesk.Colors.self
        return switch state {
        case .ok: NSColor(colors.success).cgColor
        case .paused: NSColor(colors.warning).cgColor
        case let .failed(chip): chip.tint
        case .preparing: NSColor(colors.textSecondary).cgColor
        case .off, .empty: NSColor(colors.textTertiary).cgColor
        }
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
            width: StageLayerStyle.width(display?.badgeText ?? "", size: 12, mono: true) + 14,
            height: StageGeometry.badgeHeight
        )
        // SCREENS S1: the name row sits 8pt under the stand + base (external) or the keyboard line (MacBook).
        let nameY = layer.bounds.height
            + (isBuiltin ? StageGeometry.builtinStandDrop : StageGeometry.externalStandDrop)
            + StageGeometry.nameRowGap
        let nameRow = StageGeometry.nameRowLayout(
            shellWidth: layer.bounds.width, top: nameY,
            nameWidth: StageLayerStyle.width(display?.name ?? "", size: 15, weight: .semibold),
            statusWidth: StageLayerStyle.width(display?.statusText ?? "", size: 13, mono: true)
        )
        dot.path = CGPath(ellipseIn: nameRow.dot, transform: nil)
        name.frame = nameRow.name
        status.frame = nameRow.status
        highlight.frame = layer.bounds
        highlight.cornerRadius = top
        highlight.shadowPath = shell.path
        hint.frame = CGRect(x: 8, y: layer.bounds.midY - 10, width: layer.bounds.width - 16, height: 20)
    }

    func layoutContent() {
        let size = content.bounds.size
        // `bounds` + `position`, never `frame`: `frame` is derived, so assigning it while the hover
        // zoom is on the transform would back out the scale.
        coverGroup.bounds = CGRect(origin: .zero, size: size)
        coverGroup.position = CGPoint(x: size.width / 2, y: size.height / 2)
        cover.frame = coverGroup.bounds
        coverFade?.layer.frame = coverGroup.bounds
        gradient.frame = CGRect(x: 0, y: size.height - 78, width: size.width, height: 78)
        let controls = StageGeometry.playbackLayout(
            content: size, showsPlaylistControls: display?.showsPlaylistControls ?? false
        )
        // Both lines stop short of the transport rather than running under it: it fades in over
        // them on hover, and its width changes with the playlist controls.
        let lineWidth = max(0, controls.container.minX - 18)
        title.frame = CGRect(x: 10, y: size.height - 49, width: lineWidth, height: 22)
        meta.frame = CGRect(x: 10, y: size.height - 25, width: lineWidth, height: 17)
        playback.frame = controls.container
        // Half the height and no more: Core Animation does not clamp a larger radius and draws a lens or nothing.
        playback.cornerRadius = playback.bounds.height / 2
        for (index, item) in transport.enumerated() {
            item.layer.frame = controls.buttons[index]
        }
        buttons[1].cornerRadius = buttons[1].bounds.height / 2
        veil.frame = content.bounds
        let width = min(stateWidth, max(0, size.width - 20))
        let trailing = switch display?.state {
        case .paused?, .preparing?, .off?: true
        default: false
        }
        stateGroup.frame = CGRect(x: trailing ? size.width - width - 10 : 10, y: 8, width: width, height: 24)
        stateGroup.cornerRadius = stateGroup.bounds.height / 2
        stateLabel.frame = CGRect(x: 27, y: 4, width: max(0, width - 34), height: 17)
        stateSymbol.frame = CGRect(x: 8, y: 6, width: 13, height: 13)
        empty.frame = content.bounds
        empty.isHidden = display?.state != .empty
        let symbolSide = min(44, min(size.width, size.height) * 0.25)
        emptySymbol.frame = CGRect(x: (size.width - symbolSide) / 2, y: (size.height - symbolSide) / 2,
                                   width: symbolSide, height: symbolSide)
    }

    func restoreContent() {
        content.removeFromSuperlayer()
        layer.insertSublayer(content, below: notch)
        content.removeAnimation(forKey: "opacity")
        content.opacity = 1
        content.cornerRadius = DesignTokens.EditDesk.Corner.content
        let rect = layoutRect
        layoutRect = nil
        if let rect, let isBuiltin = layoutBuiltin {
            place(content: rect, isBuiltin: isBuiltin)
        }
    }

    func setHovered(_ hovered: Bool, reduceMotion: Bool = false) {
        let target: Float = hovered ? 1 : 0
        guard target != playbackTarget || (reduceMotion && (playback.opacity != target || hoverMix != CGFloat(target))) else { return }
        playbackFrom = playback.opacity
        playbackTarget = target
        playbackElapsed = hovered ? 0 : -0.3
        hoverFrom = hoverMix
        hoverElapsed = 0
        if reduceMotion {
            playback.opacity = target
            StageLayerStyle.fadeOpacity(playback, resumingFrom: playbackFrom)
            playbackFrom = target
            playbackElapsed = 0.2
            hoverMix = CGFloat(target)
            hoverFrom = hoverMix
            hoverElapsed = 0.22
            coverGroup.transform = CATransform3DIdentity
            shell.strokeColor = dropTarget > 0 || hoverMix > 0.5 ? hotStroke : normalStroke
        }
    }

    func setDropTarget(_ targeted: Bool, reduceMotion: Bool = false) {
        let target: Float = targeted ? 1 : 0
        guard target != dropTarget || (reduceMotion && highlight.opacity != target) else { return }
        dropFrom = highlight.opacity
        dropTarget = target
        dropElapsed = 0
        if reduceMotion {
            highlight.opacity = target
            StageLayerStyle.fadeOpacity(highlight, resumingFrom: dropFrom)
            dropFrom = target
            dropElapsed = 0.18
            shell.strokeColor = dropTarget > 0 || hoverMix > 0.5 ? hotStroke : normalStroke
        }
    }

    /// Moves `sublayerTransform`, never the frame, so layout and hit testing keep the rest position.
    func shake(reduceMotion: Bool) {
        guard !reduceMotion else {
            stopShake()
            StageLayerStyle.pulseOpacity(layer)
            return
        }
        shakeElapsed = 0
    }

    private func stopShake() {
        shakeElapsed = nil
        layer.sublayerTransform = CATransform3DIdentity
    }

    /// The transport as drawn: one entry per visible button, in drawing order. Layout, the hit test
    /// and the dimmed state all read this, so a button that is not drawn keeps no hot spot and a
    /// button the orchestrator would refuse cannot be pressed.
    private var transport: [(layer: CALayer, action: StagePlaybackAction, enabled: Bool)] {
        let toggle = (buttons[1], StagePlaybackAction.toggle, display?.canTogglePlayback == true)
        guard display?.showsPlaylistControls == true else { return [toggle] }
        let canChange = display?.canChangePlaylistEntry == true
        return [(buttons[0], .previous, canChange), toggle, (buttons[2], .next, canChange)]
    }

    func playbackAction(at point: CGPoint) -> StagePlaybackAction? {
        guard !playback.isHidden, playback.opacity > 0 else { return nil }
        let local = CGPoint(x: point.x - content.frame.minX - playback.frame.minX, y: point.y - content.frame.minY - playback.frame.minY)
        return transport.first { $0.enabled && $0.layer.frame.contains(local) }?.action
    }

    func crossfade(to image: CGImage, duration: TimeInterval, reduceMotion: Bool = false) {
        if let fade = coverFade {
            cover.contents = fade.layer.contents
            fade.layer.removeFromSuperlayer()
        }
        if reduceMotion {
            cover.contents = image
            coverFade = nil
            StageLayerStyle.fadeOpacity(cover, from: 0)
            return
        }
        guard duration > 0 else {
            cover.contents = image
            coverFade = nil
            return
        }
        let next = CALayer()
        next.contents = image
        next.contentsGravity = .resizeAspectFill
        next.frame = coverGroup.bounds
        next.opacity = 0
        coverGroup.insertSublayer(next, above: cover)
        coverFade = (next, 0, duration)
    }

    func step(dt: TimeInterval, reduceMotion: Bool) {
        if reduceMotion {
            setHovered(playbackTarget > 0, reduceMotion: true)
            setDropTarget(dropTarget > 0, reduceMotion: true)
            if let fade = coverFade {
                cover.contents = fade.layer.contents
                fade.layer.removeFromSuperlayer()
                coverFade = nil
                StageLayerStyle.fadeOpacity(cover, from: 0)
            }
            // A shake caught by Reduce Motion stops here; left running, `hasAnimation` never clears.
            if shakeElapsed != nil {
                stopShake()
            }
            return
        }
        if let elapsed = shakeElapsed {
            if elapsed + dt >= 0.3 {
                stopShake()
            } else {
                shakeElapsed = elapsed + dt
                // The rejected card's curve: 6pt, three cycles in 0.3s.
                layer.sublayerTransform = CATransform3DMakeTranslation(6 * sin((elapsed + dt) / 0.3 * 6 * .pi), 0, 0)
            }
        }
        playbackElapsed += dt
        let playbackDuration = reduceMotion ? 0.15 : 0.2
        let playbackMix = Float(min(1, max(0, playbackElapsed / playbackDuration)))
        // `hasAnimation` compares for equality, so the last step lands on the target exactly.
        playback.opacity = playbackMix >= 1 ? playbackTarget : playbackFrom + (playbackTarget - playbackFrom) * playbackMix
        hoverElapsed += dt
        let hoverStep = CGFloat(min(1, max(0, hoverElapsed / (reduceMotion ? 0.15 : 0.22))))
        hoverMix = hoverStep >= 1 ? CGFloat(playbackTarget) : hoverFrom + (CGFloat(playbackTarget) - hoverFrom) * hoverStep
        // Clamped: a mix below 0 would shrink the cover and uncover the content layer's corners.
        let zoom = 1 + 0.04 * min(max(hoverMix, 0), 1)
        coverGroup.transform = CATransform3DMakeScale(zoom, zoom, 1)
        dropElapsed += dt
        let dropMix = min(1, dropElapsed / (reduceMotion ? 0.15 : 0.18))
        let eased = Float(reduceMotion ? dropMix : 1 - pow(1 - dropMix, 3))
        highlight.opacity = dropMix >= 1 ? dropTarget : dropFrom + (dropTarget - dropFrom) * eased
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
