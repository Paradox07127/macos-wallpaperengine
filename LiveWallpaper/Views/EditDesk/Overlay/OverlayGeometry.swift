import CoreGraphics
import LiveWallpaperCore

enum OverlayGeometry {
    static let gridScreenSpacing: CGFloat = 50
    static let liftScale: CGFloat = 1.03
    static let liftResponse: Double = 0.2
    static let liftDamping: Double = 0.82
    static let dropDuration: Double = 0.12
    static let reducedMotionDuration: Double = 0.15

    static func aspectFit(logicalSize: CGSize, in container: CGRect) -> CGRect {
        guard logicalSize.width > 0, logicalSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / logicalSize.width, container.height / logicalSize.height)
        let size = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
        return CGRect(x: container.midX - size.width / 2, y: container.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func validScale(_ renderScale: CGFloat) -> CGFloat {
        renderScale.isFinite && renderScale > 0 ? renderScale : 1
    }

    static func decorationLineWidth(forRenderScale scale: CGFloat) -> CGFloat {
        1 / validScale(scale)
    }

    static func gridSpacing(forRenderScale scale: CGFloat) -> CGFloat {
        gridScreenSpacing / validScale(scale)
    }

    static func screenRect(_ rect: CGRect, renderScale: CGFloat) -> CGRect {
        rect.applying(CGAffineTransform(scaleX: renderScale, y: renderScale))
    }

    static func musicRect(_ configuration: MusicOverlayConfiguration, logicalSize: CGSize,
                          safeArea: MonitorSafeAreaInsets) -> CGRect {
        MusicOverlayLayout.renderRect(configuration: configuration, boardSize: logicalSize, safeArea: safeArea) ?? .zero
    }

    static func clockRect(_ configuration: ClockOverlayConfiguration, logicalSize: CGSize,
                          safeArea: MonitorSafeAreaInsets) -> CGRect {
        ClockOverlayLayout.renderRect(configuration: configuration, canvas: logicalSize,
                                      referenceWidth: 0, safeArea: safeArea)
    }

    static func snap(freeRect: CGRect, geometry: MonitorBoardGeometry, candidates: [MonitorBoardItem],
                     renderScale: CGFloat, enabled: Bool) -> MonitorSnapResult {
        guard enabled else {
            return MonitorSnapResult(origin: freeRect.origin, snappedX: false, snappedY: false, guideX: nil, guideY: nil)
        }
        return LayoutEngine.snap(
            freeOrigin: freeRect.origin, footprint: freeRect.size, geometry: geometry,
            items: [], ignoring: nil,
            threshold: LayoutEngine.snapThreshold / validScale(renderScale),
            neighborhood: LayoutEngine.snapNeighborhood / validScale(renderScale),
            externalCandidates: candidates
        )
    }
}
