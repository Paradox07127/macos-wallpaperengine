import AppKit
import LiveWallpaperCore
import QuartzCore

@MainActor
final class ShelfCardLayer {
    let layer = CALayer()
    let face = CALayer()
    private let thumbnail = CALayer()
    private let gradient = CAGradientLayer()
    private let badge = CATextLayer()
    private let outline = CALayer()
    private let shade = CALayer()
    private let spine = CAGradientLayer()
    private let tab = CALayer()
    private var regularRing: CGColor?
    private var gridRing: CGColor?
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

    private static let rowShadowPath = CGPath(
        roundedRect: CGRect(origin: .zero, size: StageGeometry.cardSize),
        cornerWidth: DesignTokens.EditDesk.Corner.shelfCard,
        cornerHeight: DesignTokens.EditDesk.Corner.shelfCard, transform: nil
    )
    /// Contact shadow cast onto the card behind. SCREENS S2 only gives the wide float shadow,
    /// which on a single plane leaves the overlap looking pasted on.
    private static let contactShadowOffset: CGFloat = 9
    private static let contactShadowRadius: CGFloat = 9
    private static let contactShadowDrop: CGFloat = 4
    private var badgeWidth: CGFloat = 0
    private var shadowSize = CGSize.zero

    init() {
        layer.addSublayer(face)
        face.anchorPoint = CGPoint(x: 0, y: 0.5)
        face.addSublayer(thumbnail)
        thumbnail.masksToBounds = true
        thumbnail.contentsGravity = .resizeAspectFill
        thumbnail.addSublayer(gradient)
        thumbnail.addSublayer(badge)
        face.addSublayer(shade)
        face.addSublayer(spine)
        face.addSublayer(tab)
        face.addSublayer(outline)
        outline.borderWidth = 1.5
        shade.backgroundColor = StageLayerStyle.black
        shade.opacity = 0
        tab.cornerRadius = DesignTokens.EditDesk.Corner.badge
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
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
        }
        self.card = card
        thumbnail.contents = card?.thumbnail
        let badgeText = card?.statusBadge ?? card?.onBadge
        // A long display name truncates inside the card instead of running off its edge.
        badgeWidth = min(StageLayerStyle.width(badgeText ?? "", size: 11, mono: true) + 12, StageGeometry.cardSize.width - 16)
        badge.string = badgeText
        badge.isHidden = badgeText == nil
        let colors = DesignTokens.EditDesk.Colors.self
        badge.foregroundColor = StageLayerStyle.black
        badge.backgroundColor = NSColor(card?.statusBadge == nil ? colors.success : colors.warning).cgColor
        thumbnail.backgroundColor = NSColor(colors.background).cgColor
        outline.borderColor = StageLayerStyle.white
        spine.colors = [
            NSColor(colors.strokeHotShell).withAlphaComponent(0.55).cgColor,
            NSColor.black.withAlphaComponent(0.35).cgColor,
        ]
        tab.backgroundColor = NSColor(colors.strokeHotShell).withAlphaComponent(0.2).cgColor
        regularRing = NSColor(colors.strokeShelfCardRing).cgColor
        gridRing = NSColor(increasedContrast ? colors.strokeRegularIncreased : colors.strokeRegular).cgColor
        let restShadow = NSColor(DesignTokens.EditDesk.Shadow.shelfCard.color).cgColor
        let hotShadow = NSColor(DesignTokens.EditDesk.Shadow.shelfCardHover.color).cgColor
        shadowTint = restShadow.copy(alpha: 1)
        restShadowAlpha = restShadow.alpha
        hotShadowAlpha = hotShadow.alpha
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
        let corner = DesignTokens.EditDesk.Corner.shelfCard
            + (DesignTokens.EditDesk.Corner.gridCard - DesignTokens.EditDesk.Corner.shelfCard) * gridMix
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
        face.cornerRadius = corner
        face.borderWidth = 1
        face.borderColor = gridMix == 1 ? gridRing : regularRing
        gradient.frame = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        badge.frame = CGRect(x: 8, y: 8, width: badgeWidth, height: 18)
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
        face.shadowColor = shadowTint
        face.shadowOpacity = Float(
            max(0.3, 1 - placement.dim) * (restShadowAlpha + (hotShadowAlpha - restShadowAlpha) * lifted)
        )
        // Each card throws a tight shadow onto the one it has fallen across, past its near edge: with
        // the whole row on one plane that contact edge is the only thing left that reads as depth. The
        // design's wide float shadow only comes back once the cards flatten into the grid.
        let contactMix = edged * (1 - lifted)
        face.shadowRadius = rest.radius + (hot.radius - rest.radius) * lifted
            - (rest.radius - Self.contactShadowRadius) * contactMix
        face.shadowOffset = CGSize(
            width: outward * Self.contactShadowOffset * contactMix,
            height: rest.y + (hot.y - rest.y) * lifted - (rest.y - Self.contactShadowDrop) * contactMix
        )
        // The path is a pure function of the size, so `shadowSize` is a cache key and nothing more:
        // missing the hit costs one extra `CGPath`, never a shadow of the wrong size.
        if size != shadowSize {
            face.shadowPath = size == StageGeometry.cardSize
                ? Self.rowShadowPath
                : CGPath(roundedRect: face.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
            shadowSize = size
        }
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
