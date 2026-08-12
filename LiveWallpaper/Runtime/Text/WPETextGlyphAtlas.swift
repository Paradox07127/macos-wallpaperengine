#if !LITE_BUILD
import CoreGraphics
import CoreText
import Foundation
import LiveWallpaperCore
import Metal

/// R8 coverage-glyph atlas mirroring WPE's runtime font atlas: glyphs are
/// rasterized once at their final pixel size and sampled 1:1 by the text mesh.
/// Rasterization is synchronous — a CoreText coverage fill is cheap, so there
/// is no warm-up frame and no fallback path.
/// Not `@MainActor`: lives inside the renderer's actor isolation.
final class WPETextGlyphAtlas {
    struct Entry {
        let page: Int
        let uvRect: CGRect
        /// Raster cell in texels; equals the layout quad's size.
        let cellSize: CGSize
    }

    private struct Key: Hashable {
        let fontID: String
        let glyph: CGGlyph
        /// Integer raster box dimensions participate so a changed em size
        /// (different bounding box) never reuses a stale cell.
        let width: Int
        let height: Int
    }

    private struct Shelf {
        var y: Int
        var height: Int
        var x: Int
    }

    private let device: MTLDevice
    private let pageSize: Int
    private var pages: [MTLTexture] = []
    private var shelves: [[Shelf]] = []
    private var entries: [Key: Entry] = [:]
    private var fontIDs: [CTFont: String] = [:]
    private var loggedOversizedDrop = false

    init(device: MTLDevice, pageSize: Int = 2048) {
        self.device = device
        self.pageSize = pageSize
    }

    /// Fetches (or rasterizes) the glyph cell. `cell` is the glyph's OWN
    /// integral raster box around its pen (`WPETextGlyphQuad.cell`) — its
    /// origin is the pen→bearing offset used to draw, its size the cell size.
    /// Placement stays in the mesh.
    func entry(glyph: CGGlyph, font: CTFont, cell: CGRect) -> Entry? {
        let width = Int(cell.width)
        let height = Int(cell.height)
        // +1: the allocator reserves a 1px isolation strip, so the largest
        // representable glyph is pageSize−1. Oversized glyphs are dropped —
        // log once so missing characters are diagnosable, not silent.
        guard width > 0, height > 0, width + 1 <= pageSize, height + 1 <= pageSize else {
            if width > 0, height > 0, loggedOversizedDrop == false {
                loggedOversizedDrop = true
                Logger.warning(
                    "Text glyph \(glyph) (\(width)x\(height)px) exceeds the \(pageSize)px atlas page and was dropped",
                    category: .wpeRender
                )
            }
            return nil
        }
        let key = Key(fontID: fontIdentifier(font), glyph: glyph, width: width, height: height)
        if let cached = entries[key] { return cached }
        guard let coverage = rasterize(glyph: glyph, font: font, cell: cell, width: width, height: height),
              let slot = allocate(width: width + 1, height: height + 1) else { return nil }
        pages[slot.page].replace(
            region: MTLRegionMake2D(slot.x, slot.y, width, height),
            mipmapLevel: 0,
            withBytes: coverage,
            bytesPerRow: width
        )
        let scale = 1.0 / CGFloat(pageSize)
        let entry = Entry(
            page: slot.page,
            uvRect: CGRect(
                x: CGFloat(slot.x) * scale,
                y: CGFloat(slot.y) * scale,
                width: CGFloat(width) * scale,
                height: CGFloat(height) * scale
            ),
            cellSize: CGSize(width: width, height: height)
        )
        entries[key] = entry
        return entry
    }

    func texture(page: Int) -> MTLTexture? {
        pages.indices.contains(page) ? pages[page] : nil
    }

    /// Drops every atlas allocation. The shelf allocator cannot safely recycle
    /// individual cells because cached meshes retain their UVs; its owner first
    /// discards those meshes, then calls this at a renderer suspension boundary.
    /// The next visible frame rasterizes only the glyphs that are still live.
    @discardableResult
    func removeAllPages() -> Int {
        let removedPageCount = pages.count
        pages.forEach { WPEMetalTextureMetadataRegistry.shared.unregister(texture: $0) }
        entries.removeAll(keepingCapacity: false)
        shelves.removeAll(keepingCapacity: false)
        pages.removeAll(keepingCapacity: false)
        fontIDs.removeAll(keepingCapacity: false)
        loggedOversizedDrop = false
        return removedPageCount
    }

    // MARK: - Rasterization

    /// Alpha-only CoreText fill of the glyph into its integer raster box.
    /// CG memory row 0 is the cell's TOP scanline, which lands on texture
    /// v=uvRect.minY — the mesh maps its quad's top edge there.
    private func rasterize(
        glyph: CGGlyph,
        font: CTFont,
        cell: CGRect,
        width: Int,
        height: Int
    ) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let gray = CGColorSpace(name: CGColorSpace.linearGray),
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: gray,
                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
                  ) else { return false }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            var g = glyph
            // Pen position inside the cell: `cell` is the glyph's bearing box
            // around its pen, so drawing at (-minX, -minY) lands the glyph's
            // bounding box inside [0, size].
            var position = CGPoint(x: -cell.minX, y: -cell.minY)
            CTFontDrawGlyphs(font, &g, &position, 1, context)
            return true
        }
        return drawn ? pixels : nil
    }

    // MARK: - Shelf packing

    private func allocate(width: Int, height: Int) -> (page: Int, x: Int, y: Int)? {
        for page in pages.indices {
            if let slot = allocate(onPage: page, width: width, height: height) {
                return slot
            }
        }
        guard makePage() else { return nil }
        return allocate(onPage: pages.count - 1, width: width, height: height)
    }

    private func allocate(onPage page: Int, width: Int, height: Int) -> (page: Int, x: Int, y: Int)? {
        for index in shelves[page].indices where shelves[page][index].height >= height
            && pageSize - shelves[page][index].x >= width {
            let shelf = shelves[page][index]
            shelves[page][index].x += width
            return (page, shelf.x, shelf.y)
        }
        let nextY = shelves[page].last.map { $0.y + $0.height } ?? 0
        guard pageSize - nextY >= height else { return nil }
        shelves[page].append(Shelf(y: nextY, height: height, x: width))
        return (page, 0, nextY)
    }

    private func makePage() -> Bool {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: pageSize,
            height: pageSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return false }
        texture.label = "WPE text glyph atlas \(pages.count)"
        WPEMetalTextureMetadataRegistry.shared.register(texture: texture)
        // New MTLTexture contents are undefined; the 1px isolation strips
        // between cells are never written by glyph uploads, and linear
        // sampling reads them at every cell edge — zero the page once.
        let zeroRow = [UInt8](repeating: 0, count: pageSize * pageSize)
        zeroRow.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, pageSize, pageSize),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: pageSize
            )
        }
        pages.append(texture)
        shelves.append([])
        return true
    }

    private func fontIdentifier(_ font: CTFont) -> String {
        if let cached = fontIDs[font] { return cached }
        let psName = CTFontCopyPostScriptName(font) as String
        let id = "\(psName)|\(Int(CTFontGetSize(font).rounded()))"
        fontIDs[font] = id
        return id
    }
}
#endif
