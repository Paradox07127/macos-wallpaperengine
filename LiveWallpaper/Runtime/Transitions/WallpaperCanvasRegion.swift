import CoreGraphics

/// Where one display sits on the union of all displays sharing a transition, in canvas heights,
/// with AppKit's bottom-left origin so uv needs no y flip.
struct WallpaperCanvasRegion: Equatable {
    let origin: SIMD2<Float>
    let size: SIMD2<Float>
    /// Canvas width / canvas height.
    let canvasAspect: Float

    /// Both rects in AppKit global points.
    init(frame: CGRect, canvas: CGRect) {
        let height = canvas.height
        origin = SIMD2(Float((frame.minX - canvas.minX) / height), Float((frame.minY - canvas.minY) / height))
        size = SIMD2(Float(frame.width / height), Float(frame.height / height))
        canvasAspect = Float(canvas.width / height)
    }

    private init(origin: SIMD2<Float>, size: SIMD2<Float>, canvasAspect: Float) {
        self.origin = origin
        self.size = size
        self.canvasAspect = canvasAspect
    }

    static func identity(aspect: Float) -> WallpaperCanvasRegion {
        WallpaperCanvasRegion(origin: .zero, size: SIMD2(aspect, 1), canvasAspect: aspect)
    }
}
