#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperProWPE
import Metal
import simd

struct WPETextMeshVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

struct WPETextMeshPageDraw {
    let vertexBuffer: MTLBuffer
    let vertexCount: Int
    let texture: MTLTexture
}

/// One text object's frame draw: glyph quads in top-left scene-pixel space
/// plus the object's straight color (rgb×brightness) and alpha.
struct WPETextMeshPayload {
    let pages: [WPETextMeshPageDraw]
    var color: SIMD4<Float>
}

/// Placement of a text object for one frame, in author conventions: `origin`
/// in top-left y-down scene pixels, `rotation` in author-space CCW radians,
/// `scale` including live scripts, parents and perspective depth.
struct WPETextMeshPlacement {
    let originTopLeft: SIMD2<Double>
    let scale: SIMD2<Double>
    let rotation: Double
}

/// The unified WPE text renderer: FreeType-rule layout (`WPETextLayoutEngine`)
/// + R8 coverage atlas, drawn as one glyph mesh per object — the same
/// bitmap-atlas pipeline Windows WPE runs (see memory `wpe-text-windows-model`).
/// Not `@MainActor`: lives inside the renderer's actor isolation.
final class WPETextMeshRenderer {
    private let device: MTLDevice
    private let fonts: WPETextFontResolver
    private let atlas: WPETextGlyphAtlas

    /// Built mesh cache per object id — geometry rebuilds only when the
    /// resolved text or placement changes; color/alpha refresh every frame.
    private struct CachedMesh {
        let geometryKey: String
        let pages: [WPETextMeshPageDraw]
    }

    private var meshCache: [String: CachedMesh] = [:]

    init(device: MTLDevice, resolver: WPEMultiRootResourceResolver, fonts: WPETextFontResolver? = nil) {
        self.device = device
        self.fonts = fonts ?? WPETextFontResolver(resolver: resolver)
        self.atlas = WPETextGlyphAtlas(device: device)
    }

    /// Reclaims all text-owned GPU resources without imposing a glyph-size or
    /// page-count ceiling. System/lifecycle suspension calls this only after
    /// frame production stops; the next frame rebuilds meshes and atlas cells
    /// from the then-current live strings (time, weekday, scripts, and so on).
    @discardableResult
    func releaseCachedResources() -> Int {
        meshCache.removeAll(keepingCapacity: false)
        return atlas.removeAllPages()
    }

    func payload(
        for object: WPESceneTextObject,
        placement: WPETextMeshPlacement
    ) -> WPETextMeshPayload? {
        let brightness = Float(max(object.brightness, 0))
        let color = SIMD4<Float>(
            Float(object.color.x) * brightness,
            Float(object.color.y) * brightness,
            Float(object.color.z) * brightness,
            Float(object.alpha)
        )
        let geometryKey = [
            object.text,
            object.fontRelativePath ?? "",
            "\(object.pointSize)",
            "\(object.letterSpacing)",
            object.horizontalAlignment,
            object.verticalAlignment,
            "\(object.maxWidth ?? -1)",
            "\(object.maxRows ?? 0)",
            "\(object.limitUseEllipsis)",
            "\(placement.originTopLeft.x),\(placement.originTopLeft.y)",
            "\(placement.scale.x),\(placement.scale.y)",
            "\(placement.rotation)"
        ].joined(separator: "|")
        if let cached = meshCache[object.id], cached.geometryKey == geometryKey {
            return WPETextMeshPayload(pages: cached.pages, color: color)
        }

        let font = fonts.font(for: object)
        guard let layout = WPETextLayoutEngine.layout(
            text: object.text,
            font: font,
            letterSpacing: object.letterSpacing,
            horizontalAlignment: object.horizontalAlignment,
            maxWidth: object.maxWidth,
            maxRows: object.maxRows,
            ellipsis: object.limitUseEllipsis
        ) else {
            meshCache[object.id] = nil
            return nil
        }

        let anchor = layout.anchorOffset(
            horizontalAlignment: object.horizontalAlignment,
            verticalAlignment: object.verticalAlignment
        )
        // Author +y-up block space → top-left y-down screen space: negate y,
        // then scale and rotate about the origin (author CCW = screen CW, so
        // -rotation here), matching the oracle's pivot-at-origin semantics.
        let cosR = cos(-placement.rotation)
        let sinR = sin(-placement.rotation)
        let place: (Double, Double) -> SIMD2<Float> = { xUp, yUp in
            let x = (anchor.x + xUp) * placement.scale.x
            let y = -(anchor.y + yUp) * placement.scale.y
            return SIMD2<Float>(
                Float(placement.originTopLeft.x + x * cosR - y * sinR),
                Float(placement.originTopLeft.y + x * sinR + y * cosR)
            )
        }

        var perPage: [Int: [WPETextMeshVertex]] = [:]
        for quad in layout.quads {
            guard let entry = atlas.entry(glyph: quad.glyph, font: quad.runFont, cell: quad.cell) else {
                continue
            }
            let u0 = Float(entry.uvRect.minX)
            let u1 = Float(entry.uvRect.maxX)
            let vTop = Float(entry.uvRect.minY)
            let vBottom = Float(entry.uvRect.maxY)
            let topLeft = place(Double(quad.rect.minX), Double(quad.rect.maxY))
            let topRight = place(Double(quad.rect.maxX), Double(quad.rect.maxY))
            let bottomLeft = place(Double(quad.rect.minX), Double(quad.rect.minY))
            let bottomRight = place(Double(quad.rect.maxX), Double(quad.rect.minY))
            perPage[entry.page, default: []].append(contentsOf: [
                WPETextMeshVertex(position: topLeft, uv: SIMD2<Float>(u0, vTop)),
                WPETextMeshVertex(position: topRight, uv: SIMD2<Float>(u1, vTop)),
                WPETextMeshVertex(position: bottomLeft, uv: SIMD2<Float>(u0, vBottom)),
                WPETextMeshVertex(position: topRight, uv: SIMD2<Float>(u1, vTop)),
                WPETextMeshVertex(position: bottomRight, uv: SIMD2<Float>(u1, vBottom)),
                WPETextMeshVertex(position: bottomLeft, uv: SIMD2<Float>(u0, vBottom))
            ])
        }

        var pages: [WPETextMeshPageDraw] = []
        for page in perPage.keys.sorted() {
            guard let vertices = perPage[page], !vertices.isEmpty,
                  let texture = atlas.texture(page: page) else { continue }
            let buffer = vertices.withUnsafeBytes { raw -> MTLBuffer? in
                guard let base = raw.baseAddress else { return nil }
                return device.makeBuffer(bytes: base, length: raw.count, options: [])
            }
            guard let buffer else { continue }
            pages.append(WPETextMeshPageDraw(
                vertexBuffer: buffer,
                vertexCount: vertices.count,
                texture: texture
            ))
        }
        guard !pages.isEmpty else {
            meshCache[object.id] = nil
            return nil
        }
        meshCache[object.id] = CachedMesh(geometryKey: geometryKey, pages: pages)
        return WPETextMeshPayload(pages: pages, color: color)
    }
}
#endif
