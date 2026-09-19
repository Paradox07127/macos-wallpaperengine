import AppKit
import LiveWallpaperCore
import QuartzCore

@MainActor
final class DragGhostLayer {
    static let size = CGSize(width: 140, height: 79)
    let layer = CALayer()
    private let image = CALayer()
    var x = StageSpring(value: 0, target: 0, parameters: StageSpring.ghost)
    var y = StageSpring(value: 0, target: 0, parameters: StageSpring.ghost)
    var scale = StageSpring(value: 1, target: 1, parameters: StageSpring.ghost)
    var flight = StageSpring(value: 0, target: 0, parameters: StageSpring.drop)
    var source: StageCard.ID?
    var destination: CGRect?
    var flightOrigin = CGRect.zero

    /// CGColors are resolved once, so an appearance change has to re-resolve them by hand.
    func refreshPalette() {
        image.borderColor = NSColor(DesignTokens.EditDesk.Colors.strokeHotShell).cgColor
    }

    init() {
        layer.addSublayer(image)
        image.contentsGravity = .resizeAspectFill
        image.masksToBounds = true
        image.cornerRadius = DesignTokens.EditDesk.Corner.shelfCard
        image.borderWidth = 2
        refreshPalette()
        layer.shadowColor = NSColor(DesignTokens.EditDesk.Shadow.hoverCard.color).cgColor
        layer.shadowRadius = DesignTokens.EditDesk.Shadow.hoverCard.radius
        layer.shadowOffset = CGSize(width: 0, height: DesignTokens.EditDesk.Shadow.hoverCard.y)
        layer.shadowOpacity = 1
        // Above every card: their z climbs with the library index plus the hover bump.
        layer.zPosition = 10000
        layer.isHidden = true
    }

    func begin(card: StageCard, at point: CGPoint) {
        source = card.id
        image.contents = card.thumbnail
        x.jump(to: point.x)
        y.jump(to: point.y)
        scale.jump(to: 1)
        flight.jump(to: 0)
        destination = nil
        layer.opacity = 1
        layer.isHidden = false
        render()
    }

    func render() {
        guard source != nil else { return }
        var rect = CGRect(
            x: x.value - Self.size.width / 2, y: y.value - Self.size.height / 2,
            width: Self.size.width, height: Self.size.height
        )
        if let destination {
            let t = flight.value
            rect = CGRect(
                x: flightOrigin.minX + (destination.minX - flightOrigin.minX) * t,
                y: flightOrigin.minY + (destination.minY - flightOrigin.minY) * t,
                width: flightOrigin.width + (destination.width - flightOrigin.width) * t,
                height: flightOrigin.height + (destination.height - flightOrigin.height) * t
            )
            layer.opacity = Float(1 - min(1, t))
        }
        layer.transform = CATransform3DIdentity
        layer.frame = rect
        image.frame = layer.bounds
        let rotation = -5 * .pi / 180 * (1 - flight.value)
        layer.transform = CATransform3DScale(CATransform3DMakeRotation(rotation, 0, 0, 1), scale.value, scale.value, 1)
        layer.shadowPath = CGPath(
            roundedRect: layer.bounds, cornerWidth: DesignTokens.EditDesk.Corner.shelfCard,
            cornerHeight: DesignTokens.EditDesk.Corner.shelfCard, transform: nil
        )
    }

    func finish() {
        source = nil
        destination = nil
        layer.isHidden = true
    }
}
