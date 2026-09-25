import AppKit
import LiveWallpaperCore
import QuartzCore
import SwiftUI

@MainActor
final class ShelfCardLayer {
    let layer = CALayer()
    let face = CALayer()
    /// Casts the tight contact shadow through the face's own path; no content of its own.
    let edgeShadow = CALayer()
    let thumbnail = CALayer()
    private let gradient = CAGradientLayer()
    let spine = CAGradientLayer()
    let sheen = CAGradientLayer()
    let rimTop = CALayer()
    let rimBottom = CALayer()
    let badge = CATextLayer()
    private let outline = CALayer()
    private let shade = CALayer()
    private let tab = CALayer()
    /// Built for the first card set on a display. It sits above the thumbnail, not inside it, so the
    /// wave never re-composites the rounded clip.
    private(set) var capsule: CALayer?
    private var capsuleText: CATextLayer?
    private(set) var waveBars: [CALayer] = []
    private var capsuleWidth: CGFloat = 0
    /// The capsule shown names a display that is drawing the wallpaper.
    private var isLive = false
    private var isWaving = false
    /// `GalleryTileChrome`'s stroke at full strength; the card fades it in as it lands in the grid.
    private var gridStroke: CGColor?
    /// The shadow tokens' shared hue at full alpha; their two alphas ride `shadowOpacity` instead,
    /// which is what lets the hover darken the shadow continuously.
    private var shadowTint: CGColor?
    private var restShadowAlpha: CGFloat = 0
    private var hotShadowAlpha: CGFloat = 0
    private(set) var card: StageCard?
    private(set) var hitShape = StageGeometry.CardShape(rect: .zero)
    var hitRect: CGRect {
        hitShape.boundingBox
    }

    var lift = StageSpring(value: 0, target: 0, parameters: StageSpring.hover)
    var hover = StageSpring(value: 0, target: 0, parameters: StageSpring.hover)
    var gridProgress = StageSpring(value: 0, target: 0, parameters: StageSpring.snap)
    var staggerRemaining: TimeInterval = 0
    var shakeElapsed: TimeInterval?
    var frame: CGRect {
        layer.frame
    }

    private static let rowShadowPath = RoundedRectangle(
        cornerRadius: DesignTokens.EditDesk.Corner.shelfCard, style: .continuous
    ).path(in: CGRect(origin: .zero, size: StageGeometry.cardSize)).cgPath
    /// Contact shadow cast onto the card behind. SCREENS S2 only gives the wide float shadow,
    /// which on a single plane leaves the overlap looking pasted on.
    private static let contactShadowOffset: CGFloat = 9
    private var badgeWidth: CGFloat = 0
    private var shadowSize = CGSize.zero

    init() {
        layer.addSublayer(face)
        face.anchorPoint = CGPoint(x: 0, y: 0.5)
        face.addSublayer(edgeShadow)
        face.addSublayer(thumbnail)
        thumbnail.masksToBounds = true
        thumbnail.contentsGravity = .resizeAspectFill
        thumbnail.borderWidth = 1
        for sublayer in [gradient, spine, sheen, rimTop, rimBottom, badge] {
            thumbnail.addSublayer(sublayer)
        }
        face.addSublayer(shade)
        face.addSublayer(tab)
        face.addSublayer(outline)
        for rounded in [face, thumbnail, shade, tab, outline, badge] {
            rounded.cornerCurve = .continuous
        }
        outline.borderWidth = 1.5
        shade.backgroundColor = StageLayerStyle.black
        shade.opacity = 0
        tab.cornerRadius = DesignTokens.EditDesk.Corner.badge
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        // shelf-lab's `linear-gradient(112deg)` across its 2.6W-wide box, in that box's unit space (y down).
        sheen.colors = [0, 0.13, 0].map { NSColor.white.withAlphaComponent($0).cgColor }
        sheen.locations = [0.34, 0.47, 0.60]
        sheen.startPoint = CGPoint(x: 0.033, y: -0.376)
        sheen.endPoint = CGPoint(x: 0.967, y: 1.376)
        edgeShadow.shadowRadius = DesignTokens.EditDesk.Shadow.shelfCardEdge.radius
        StageLayerStyle.text(badge, size: 11, mono: true)
        badge.cornerRadius = DesignTokens.EditDesk.Corner.badge
        badge.masksToBounds = true
        badge.alignmentMode = .center
        update(card: nil, increasedContrast: false)
    }

    func update(card: StageCard?, increasedContrast: Bool) {
        if self.card?.id != card?.id {
            layer.removeAnimation(forKey: "opacity")
            outline.removeAnimation(forKey: "opacity")
            setWaving(false)
        }
        self.card = card
        thumbnail.contents = card?.thumbnail
        let status = card?.statusBadge
        // A long reason truncates inside the card instead of running off its edge.
        badgeWidth = min(StageLayerStyle.width(status ?? "", size: 11, mono: true) + 12, StageGeometry.cardSize.width - 16)
        badge.string = status
        badge.isHidden = status == nil
        showNowPlaying(status == nil ? card?.nowPlaying : nil)
        let colors = DesignTokens.EditDesk.Colors.self
        badge.foregroundColor = StageLayerStyle.black
        badge.backgroundColor = NSColor(colors.warning).cgColor
        thumbnail.backgroundColor = NSColor(DesignTokens.Colors.surfaceRaised).cgColor
        thumbnail.borderColor = NSColor(increasedContrast ? colors.cardRimRingIncreased : colors.cardRimRing).cgColor
        rimTop.backgroundColor = NSColor(colors.cardRimHighlight).cgColor
        rimBottom.backgroundColor = NSColor(colors.cardRimShade).cgColor
        outline.borderColor = StageLayerStyle.white
        spine.colors = [
            NSColor(colors.strokeHotShell).withAlphaComponent(0.55).cgColor,
            NSColor.black.withAlphaComponent(0.35).cgColor,
        ]
        tab.backgroundColor = NSColor(colors.strokeHotShell).withAlphaComponent(0.2).cgColor
        gridStroke = NSColor(Color.primary.opacity(DesignTokens.Card.strokeOpacity)).cgColor
        let restShadow = NSColor(DesignTokens.EditDesk.Shadow.shelfCard.color).cgColor
        let hotShadow = NSColor(DesignTokens.EditDesk.Shadow.shelfCardHover.color).cgColor
        shadowTint = restShadow.copy(alpha: 1)
        restShadowAlpha = restShadow.alpha
        hotShadowAlpha = hotShadow.alpha
        edgeShadow.shadowColor = NSColor(DesignTokens.EditDesk.Shadow.shelfCardEdge.color).cgColor
        gradient.colors = [StageLayerStyle.clear, NSColor(colors.gradientCardBottom).cgColor]
    }

    func place(_ placement: StageGeometry.CardPlacement, style: ShelfStyle, gridMix: CGFloat, dragged: Bool, reduceMotion: Bool) {
        layer.frame = placement.frame
        // The perspective has to sit on `face`'s direct parent: a plain CALayer flattens its
        // sublayers before applying anything from further up, which renders the tilt orthographic.
        // Each card gets its own vanishing point, so every card in the row leans the same way — a
        // shared one flips the taper either side of it and the run reads as a bowl.
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / StageGeometry.shelfPerspective
        layer.sublayerTransform = perspective
        let size = placement.frame.size
        let corner = StageGeometry.lerp(DesignTokens.EditDesk.Corner.shelfCard, DesignTokens.Corner.lg, gridMix)
        let tilted = 1 - gridMix
        // Facing In's middle card faces front, so its spine and contact shadow grow with its turn
        // instead of jumping sides as the card crosses the middle.
        let edged = style == .facingIn
            ? min(1, abs(placement.rotationYDegrees) / StageGeometry.metrics(for: style).tiltDegrees) : tilted
        // Both go on the near edge, which is the pivot: the right one only for a right-edge pivot.
        let outward: CGFloat = placement.anchorX > 0.5 ? 1 : -1
        let lifted = reduceMotion ? 0 : CGFloat(hover.value)
        face.anchorPoint = CGPoint(x: placement.anchorX, y: 0.5)
        face.bounds = CGRect(origin: .zero, size: size)
        face.position = CGPoint(x: size.width * placement.anchorX, y: size.height / 2)
        let posed = StageGeometry.applyingHover(placement, style: style, hover: lifted, gridMix: gridMix)
        var transform = CATransform3DMakeTranslation(0, 0, posed.translateZ)
        transform = CATransform3DRotate(transform, posed.rotationZDegrees * .pi / 180, 0, 0, 1)
        transform = CATransform3DRotate(transform, posed.rotationYDegrees * .pi / 180, 0, 1, 0)
        let scale = posed.scale
        face.transform = CATransform3DScale(transform, scale, scale, 1)
        hitShape = StageGeometry.hitShape(posed, style: style)
        shade.frame = face.bounds
        shade.cornerRadius = corner
        shade.opacity = Float(max(0, placement.dim * (1 - lifted)))
        spine.frame = CGRect(x: outward > 0 ? size.width - 3 : 0, y: 0, width: 3, height: size.height)
        spine.startPoint = CGPoint(x: outward > 0 ? 1 : 0, y: 0.5)
        spine.endPoint = CGPoint(x: outward > 0 ? 0 : 1, y: 0.5)
        spine.opacity = Float(edged)
        tab.frame = CGRect(x: 10, y: -9, width: 56, height: 10)
        tab.isHidden = style != .folders
        tab.opacity = Float(tilted)
        thumbnail.frame = face.bounds
        thumbnail.cornerRadius = corner
        // shelf-lab's slide: the band tracks the turn, clamped so the folders' 40° cannot push it off the card.
        let slide = min(max(0.5 + 0.014 * posed.rotationYDegrees + 0.012 * posed.rotationZDegrees, 0.1), 0.9)
        sheen.frame = CGRect(x: -1.6 * size.width * slide, y: 0, width: 2.6 * size.width, height: size.height)
        sheen.opacity = Float(tilted)
        rimTop.frame = CGRect(x: 0, y: 0, width: size.width, height: 1)
        rimBottom.frame = CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)
        face.cornerRadius = corner
        face.borderWidth = DesignTokens.Card.strokeWidth
        face.borderColor = gridStroke.flatMap { $0.copy(alpha: $0.alpha * gridMix) }
        gradient.frame = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        // Facing In's right half leaves each card's right side showing, so both badges move over with its turn.
        let side = placement.anchorX > 0.5 ? edged : 0
        badge.frame = CGRect(x: 8 + (size.width - 16 - badgeWidth) * side, y: 8, width: badgeWidth, height: 18)
        if let capsule, !capsule.isHidden {
            capsule.frame = CGRect(x: 8 + (size.width - 16 - capsuleWidth) * side, y: 8, width: capsuleWidth, height: 18)
            capsuleText?.frame = CGRect(x: 19, y: 3, width: max(0, capsuleWidth - 25), height: 12)
        }
        setWaving(isLive && !reduceMotion && placement.opacity > 0 && gridMix < 1)
        outline.frame = face.bounds
        outline.cornerRadius = corner
        let outlineOpacity = outline.opacity
        outline.opacity = Float(hover.value)
        if reduceMotion, outlineOpacity != outline.opacity {
            StageLayerStyle.fadeOpacity(outline, resumingFrom: outlineOpacity)
        }
        layer.opacity = Float(placement.opacity) * (dragged ? 0.3 : 1)
        let rest = DesignTokens.EditDesk.Shadow.shelfCard
        let hot = DesignTokens.EditDesk.Shadow.shelfCardHover
        let edge = DesignTokens.EditDesk.Shadow.shelfCardEdge
        let lit = max(0.3, 1 - placement.dim)
        // Each card throws a tight shadow onto the one it has fallen across, past its near edge: with
        // the whole row on one plane that contact edge is the only thing left that reads as depth.
        let contactMix = edged * (1 - lifted)
        face.shadowColor = shadowTint
        face.shadowOpacity = Float(lit * StageGeometry.lerp(
            StageGeometry.lerp(restShadowAlpha, hotShadowAlpha, lifted), CGFloat(DesignTokens.Card.restShadowOpacity), gridMix
        ))
        face.shadowRadius = StageGeometry.lerp(
            StageGeometry.lerp(rest.radius, hot.radius, lifted), DesignTokens.Card.shadowRadius, gridMix
        )
        face.shadowOffset = CGSize(
            width: outward * Self.contactShadowOffset * contactMix,
            height: StageGeometry.lerp(StageGeometry.lerp(rest.y, hot.y, lifted), DesignTokens.Card.restShadowYOffset, gridMix)
        )
        edgeShadow.frame = face.bounds
        edgeShadow.shadowOpacity = Float(lit * tilted)
        // 0.6: shelf-lab leans the contact shadow 0.6 as far as the spread one.
        edgeShadow.shadowOffset = CGSize(width: outward * Self.contactShadowOffset * 0.6 * contactMix, height: edge.y)
        // The path is a pure function of the size, so `shadowSize` is a cache key and nothing more:
        // missing the hit costs one extra `CGPath`, never a shadow of the wrong size.
        if size != shadowSize {
            let path = size == StageGeometry.cardSize
                ? Self.rowShadowPath
                : RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: face.bounds).cgPath
            face.shadowPath = path
            edgeShadow.shadowPath = path
            shadowSize = size
        }
    }

    /// Starts or stops the capsule's wave. The render server runs it, so it never asks for a frame.
    func setWaving(_ waving: Bool) {
        guard waving != isWaving else { return }
        isWaving = waving
        for (index, bar) in waveBars.enumerated() {
            if waving {
                // shelf-lab's 0.9s ease-in-out bounce, bars delayed 0 / −0.3 / −0.6s.
                let wave = CABasicAnimation(keyPath: "transform.scale.y")
                wave.fromValue = 1.0 / 3
                wave.toValue = 1
                wave.duration = 0.45
                wave.autoreverses = true
                wave.repeatCount = .infinity
                wave.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                wave.timeOffset = 0.3 * Double(index)
                bar.add(wave, forKey: "wave")
            } else {
                bar.removeAnimation(forKey: "wave")
            }
        }
    }

    private func showNowPlaying(_ nowPlaying: NowPlayingBadge?) {
        isLive = nowPlaying?.isLive ?? false
        guard let nowPlaying else {
            capsule?.isHidden = true
            setWaving(false)
            return
        }
        if capsule == nil {
            buildCapsule()
        }
        capsule?.isHidden = false
        capsuleText?.string = nowPlaying.text
        // 6pt insets, 9pt of bars and a 4pt gap: the text starts at 19.
        capsuleWidth = min(StageLayerStyle.width(nowPlaying.text, size: 10, weight: .semibold) + 25, StageGeometry.cardSize.width - 16)
    }

    private func buildCapsule() {
        let capsule = CALayer()
        // Half the 18pt height and no more: Core Animation bends a larger radius into a lens,
        // or draws nothing once it passes half the width too.
        capsule.cornerRadius = 9
        capsule.cornerCurve = .continuous
        capsule.backgroundColor = NSColor(DesignTokens.EditDesk.Colors.mediaChipFill).cgColor
        capsule.borderWidth = 0.5
        capsule.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        let glyph = NSColor(DesignTokens.EditDesk.Colors.nowPlayingGlyph).cgColor
        // 2×9pt bars 1.5pt apart after the 6pt inset, standing on the line that centres 9pt in 18pt;
        // at rest they are 5, 9 and 6pt tall.
        let restingScales: [CGFloat] = [5.0 / 9, 1, 6.0 / 9]
        waveBars = restingScales.enumerated().map { index, rest -> CALayer in
            let bar = CALayer()
            bar.backgroundColor = glyph
            bar.cornerRadius = 1
            bar.cornerCurve = .continuous
            bar.anchorPoint = CGPoint(x: 0.5, y: 1)
            bar.bounds = CGRect(x: 0, y: 0, width: 2, height: 9)
            bar.position = CGPoint(x: 7 + 3.5 * CGFloat(index), y: 13.5)
            bar.transform = CATransform3DMakeScale(1, rest, 1)
            capsule.addSublayer(bar)
            return bar
        }
        let text = CATextLayer()
        StageLayerStyle.text(text, size: 10, weight: .semibold)
        // Middle, so a long display name never truncates the "+N" count away.
        text.truncationMode = .middle
        text.foregroundColor = StageLayerStyle.white
        capsule.addSublayer(text)
        face.insertSublayer(capsule, above: thumbnail)
        self.capsule = capsule
        capsuleText = text
    }
}

@MainActor
enum StageLayerStyle {
    /// Fixed on purpose: these are the colours drawn *over* a wallpaper thumbnail, and the
    /// thumbnail does not get lighter when the app does.
    static var white: CGColor {
        NSColor.white.cgColor
    }

    static var black: CGColor {
        NSColor.black.cgColor
    }

    static var clear: CGColor {
        NSColor.black.withAlphaComponent(0).cgColor
    }

    static func fadeOpacity(_ layer: CALayer, from: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = layer.opacity
        animation.duration = 0.15
        layer.add(animation, forKey: "opacity")
    }

    /// `previous` is the model value to use off-screen, where there is no presentation layer. On
    /// screen the model layer already holds the running animation's end value, so a reversal read
    /// from it would cut to that end before fading back.
    static func fadeOpacity(_ layer: CALayer, resumingFrom previous: Float) {
        fadeOpacity(layer, from: layer.presentation()?.opacity ?? previous)
    }

    /// Reduce Motion's stand-in for a shake: the dip-and-return `ModalDragGhost` uses, within the
    /// same 0.15s budget as a fade.
    static func pulseOpacity(_ layer: CALayer) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [layer.opacity, Float(DesignTokens.Opacity.dimmedContent), layer.opacity]
        animation.keyTimes = [0, 0.5, 1]
        animation.duration = 0.15
        layer.add(animation, forKey: "opacity")
    }

    static func text(_ layer: CATextLayer, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) {
        layer.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.truncationMode = .end
        layer.contentsScale = 2
    }

    /// `weight` has to match what `text(_:size:weight:mono:)` set on the layer being measured:
    /// measuring semibold as regular is what puts a centred row off centre.
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func symbol(_ name: String, tint: NSColor, pointSize: CGFloat = 11) -> CGImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .semibold))?
            .withSymbolConfiguration(.init(paletteColors: [tint])) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func roundedPath(_ rect: CGRect, top: CGFloat, bottom: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + top), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottom, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottom), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
