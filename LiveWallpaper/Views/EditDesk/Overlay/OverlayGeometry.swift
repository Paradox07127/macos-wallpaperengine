import CoreGraphics
import LiveWallpaperCore

enum OverlayGeometry {
    static let gridScreenSpacing: CGFloat = 50
    static let liftScale: CGFloat = 1.03
    static let liftResponse: Double = 0.2
    static let liftDamping: Double = 0.82
    static let dropDuration: Double = 0.12
    static let reducedMotionDuration: Double = 0.15
    /// MOTION 15: a new object lands from 1.1× on a 0.3 spring.
    static let landingScale: CGFloat = 1.1
    static let landingResponse: Double = 0.3
    static let canvasInset = DesignTokens.EditDesk.Spacing.s12
    static let dropPreviewOpacity: Double = 0.85
    static let ghostOpacity: Double = 0.9
    static let refusedStrokeScreenWidth: CGFloat = 1.5

    /// A widget dropped from the add strip, in board pixels.
    struct WidgetDrop: Equatable {
        /// The raw footprint centred on the pointer and kept on the board: where a refused drop is drawn.
        var footprint: CGRect
        /// nil when no legal spot lies within one footprint of the pointer.
        var landing: CGPoint?
        var guideX: MonitorSnapGuide?
        var guideY: MonitorSnapGuide?
    }

    /// `kind` at its default size, centred on `point`: snapped the way a board drag snaps, then moved to
    /// the nearest legal spot within one footprint. A guide the move left behind is dropped.
    @MainActor
    static func widgetDrop(kind: MonitorWidgetKind, at point: CGPoint, geometry: MonitorBoardGeometry,
                           items: [MonitorBoardItem], renderScale: CGFloat, snaps: Bool) -> WidgetDrop {
        let size = geometry.pixelSize(for: kind, size: InteractionModel.defaultSize(for: kind))
        let free = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        let snapped = snap(freeRect: CGRect(origin: free, size: size), geometry: geometry, candidates: items,
                           renderScale: renderScale, enabled: snaps)
        let landing = LayoutEngine.land(freeOrigin: free, snappedOrigin: snapped.snapped ? snapped.origin : nil,
                                        footprint: size, geometry: geometry, items: items, ignoring: nil)
        return WidgetDrop(
            footprint: CGRect(origin: geometry.clampOrigin(free, footprint: size), size: size),
            landing: landing,
            guideX: landing?.x == snapped.origin.x ? snapped.guideX : nil,
            guideY: landing?.y == snapped.origin.y ? snapped.guideY : nil
        )
    }

    static func refusedStrokeWidth(forRenderScale scale: CGFloat) -> CGFloat {
        refusedStrokeScreenWidth / validScale(scale)
    }

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
