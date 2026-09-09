import CoreGraphics
import LiveWallpaperCore

enum ClockOverlayLayout {
    static func renderRect(
        configuration: ClockOverlayConfiguration, canvas: CGSize,
        referenceWidth: CGFloat = 0, safeArea: MonitorSafeAreaInsets = .none
    ) -> CGRect {
        guard canvas.width > 0, canvas.height > 0 else { return .zero }
        let configuration = configuration.normalized
        let geometry = MonitorBoardGeometry(boardSize: canvas, referenceWidth: referenceWidth, safeArea: safeArea)
        let scale = referenceWidth > 0 ? canvas.width / referenceWidth : 1
        let width = min(configuration.width * scale, geometry.safeRect.width,
                        geometry.safeRect.height * ClockOverlayConfiguration.aspectRatio)
        let size = CGSize(width: width, height: width / ClockOverlayConfiguration.aspectRatio)
        let origin = geometry.clampOrigin(
            CGPoint(x: configuration.x * canvas.width, y: configuration.y * canvas.height), footprint: size
        )
        return CGRect(origin: origin, size: size)
    }

    static func placing(_ configuration: ClockOverlayConfiguration, origin: CGPoint, canvas: CGSize,
                        referenceWidth: CGFloat, safeArea: MonitorSafeAreaInsets) -> ClockOverlayConfiguration {
        guard canvas.width > 0, canvas.height > 0 else { return configuration }
        var next = configuration.normalized
        next.x = origin.x / canvas.width
        next.y = origin.y / canvas.height
        let rect = renderRect(configuration: next, canvas: canvas, referenceWidth: referenceWidth, safeArea: safeArea)
        next.x = rect.minX / canvas.width
        next.y = rect.minY / canvas.height
        return next.normalized
    }
}
