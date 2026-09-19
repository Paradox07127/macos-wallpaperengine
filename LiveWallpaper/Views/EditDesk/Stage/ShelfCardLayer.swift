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
    private var restShadow: CGColor?
    private var hotShadow: CGColor?
    private(set) var card: StageCard?
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
        spine.startPoint = CGPoint(x: 0, y: 0.5)
        spine.endPoint = CGPoint(x: 1, y: 0.5)
        tab.cornerRadius = DesignTokens.EditDesk.Corner.badge
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        StageLayerStyle.text(badge, size: 9, mono: true)
        badge.cornerRadius = DesignTokens.EditDesk.Corner.badge
        badge.masksToBounds = true
        badge.alignmentMode = .center
        update(card: nil)
    }

    func update(card: StageCard?) {
        self.card = card
        thumbnail.contents = card?.thumbnail
        badgeWidth = StageLayerStyle.width(card?.onBadge ?? "", size: 9, mono: true) + 10
        badge.string = card?.onBadge
        badge.isHidden = card?.onBadge == nil
        let colors = DesignTokens.EditDesk.Colors.self
        badge.foregroundColor = StageLayerStyle.black
        badge.backgroundColor = NSColor(colors.success).cgColor
        thumbnail.backgroundColor = NSColor(colors.background).cgColor
        outline.borderColor = StageLayerStyle.white
        spine.colors = [
            NSColor(colors.strokeHotShell).withAlphaComponent(0.55).cgColor,
            NSColor.black.withAlphaComponent(0.35).cgColor,
        ]
        tab.backgroundColor = NSColor(colors.strokeHotShell).withAlphaComponent(0.2).cgColor
        regularRing = NSColor(colors.strokeShelfCardRing).cgColor
        gridRing = NSColor(colors.strokeRegular).cgColor
        restShadow = NSColor(DesignTokens.EditDesk.Shadow.shelfCard.color).cgColor
        hotShadow = NSColor(DesignTokens.EditDesk.Shadow.hoverCard.color).cgColor
        gradient.colors = [StageLayerStyle.clear, NSColor(colors.gradientCardBottom).cgColor]
    }

    func place(_ placement: StageGeometry.CardPlacement, style: ShelfStyle, gridMix: CGFloat, dragged: Bool) {
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
        let metrics = StageGeometry.metrics(for: style)
        let tilted = 1 - gridMix
        let lifted = CGFloat(hover.value)
        face.anchorPoint = CGPoint(x: placement.anchorX, y: 0.5)
        face.bounds = CGRect(origin: .zero, size: size)
        face.position = CGPoint(x: size.width * placement.anchorX, y: size.height / 2)
        var transform = CATransform3DMakeTranslation(0, 0, placement.translateZ + metrics.hoverDepth * lifted * tilted)
        let angle = placement.rotationYDegrees + metrics.hoverTiltDegrees * lifted * tilted
        transform = CATransform3DRotate(transform, angle * .pi / 180, 0, 1, 0)
        let scale = placement.scale * (1 + 0.04 * lifted * gridMix)
        face.transform = CATransform3DScale(transform, scale, scale, 1)
        shade.frame = face.bounds
        shade.cornerRadius = corner
        shade.opacity = Float(max(0, placement.dim * (1 - lifted)))
        // The lit edge is the near one, which with the left card in front is the card's own left.
        spine.frame = CGRect(x: 0, y: 0, width: 3, height: size.height)
        spine.opacity = Float(tilted)
        tab.frame = CGRect(x: 10, y: -9, width: 56, height: 10)
        tab.isHidden = style != .folders
        tab.opacity = Float(tilted)
        thumbnail.frame = face.bounds
        thumbnail.cornerRadius = corner
        face.cornerRadius = corner
        face.borderWidth = 1
        face.borderColor = gridMix == 1 ? gridRing : regularRing
        gradient.frame = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        badge.frame = CGRect(x: 8, y: 8, width: badgeWidth, height: 15)
        outline.frame = face.bounds
        outline.cornerRadius = corner
        outline.opacity = Float(hover.value)
        layer.opacity = Float(placement.opacity) * (dragged ? 0.3 : 1)
        let rest = DesignTokens.EditDesk.Shadow.shelfCard
        let hot = DesignTokens.EditDesk.Shadow.hoverCard
        face.shadowColor = hover.value > 0 ? hotShadow : restShadow
        face.shadowOpacity = Float(max(0.3, 1 - placement.dim))
        // Each card throws a tight shadow onto the one it has fallen across, to its left: with the
        // whole row on one plane that contact edge is the only thing left that reads as depth. The
        // design's wide float shadow only comes back once the cards flatten into the grid.
        let contactMix = tilted * (1 - CGFloat(hover.value))
        face.shadowRadius = rest.radius + (hot.radius - rest.radius) * hover.value
            - (rest.radius - Self.contactShadowRadius) * contactMix
        face.shadowOffset = CGSize(
            width: -Self.contactShadowOffset * contactMix,
            height: rest.y + (hot.y - rest.y) * hover.value - (rest.y - Self.contactShadowDrop) * contactMix
        )
        // Paths are rebuilt only at the two rest sizes; mid-flight frames reuse the last one.
        if size == StageGeometry.cardSize {
            face.shadowPath = Self.rowShadowPath
            shadowSize = size
        } else if gridMix == 1, size != shadowSize {
            face.shadowPath = CGPath(roundedRect: face.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
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

    static func text(_ layer: CATextLayer, size: CGFloat, weight: NSFont.Weight = .regular, mono: Bool = false) {
        layer.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.truncationMode = .end
        layer.contentsScale = 2
    }

    static func width(_ text: String, size: CGFloat, mono: Bool = false) -> CGFloat {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size, weight: .regular)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func symbol(_ name: String, tint: NSColor) -> CGImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))?
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
