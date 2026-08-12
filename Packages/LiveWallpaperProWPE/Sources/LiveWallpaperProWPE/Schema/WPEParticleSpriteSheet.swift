import Foundation

/// Particle atlas from WPE `<texture>.tex-json`. `isAlphaMask` (r8): sample as
/// opacity only; RGB from particle tint (shader must not use texture RGB).
public struct WPEParticleSpriteSheet: Sendable, Equatable {
    public let cols: Int
    public let rows: Int
    /// Cycle length; with `frameRects`, equals rect count (CPU/GPU stay in sync).
    public let frameCount: Int
    /// `.tex-json` frames/duration metadata. The current WPE particle path
    /// advances frames from normalized lifetime and `sequencemultiplier`;
    /// `baseFrameRate` is intentionally not a runtime timing input.
    public let baseFrameRate: Double
    public let isAlphaMask: Bool
    /// Explicit UVs for non-uniform grids; nil → cols×rows grid path.
    public let frameRects: [SIMD4<Float>]?

    public init(
        cols: Int,
        rows: Int,
        frameCount: Int,
        baseFrameRate: Double,
        isAlphaMask: Bool,
        frameRects: [SIMD4<Float>]? = nil
    ) {
        let resolvedRects = (frameRects?.isEmpty == false) ? frameRects : nil
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.frameCount = resolvedRects?.count ?? max(1, frameCount)
        self.baseFrameRate = max(0, baseFrameRate)
        self.isAlphaMask = isAlphaMask
        self.frameRects = resolvedRects
    }
}

/// `.tex-json` parser; nil → single-frame static sprite.
public enum WPEParticleSpriteSheetParser {
    public static func parse(data: Data, atlasPixelSize: (width: Int, height: Int)) -> WPEParticleSpriteSheet? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parse(dictionary: json, atlasPixelSize: atlasPixelSize)
    }

    public static func parse(
        dictionary json: [String: Any],
        atlasPixelSize: (width: Int, height: Int)
    ) -> WPEParticleSpriteSheet? {
        let format = (json["format"] as? String)?.lowercased() ?? "rgba8888"
        let isAlphaMask = (format == "r8")
        guard let sequences = json["spritesheetsequences"] as? [[String: Any]],
              let first = sequences.first else {
            return nil
        }
        let frameW = doubleValue(first["width"]) ?? 0
        let frameH = doubleValue(first["height"]) ?? 0
        let frameCountRaw = WPEValueParser.int(first["frames"]) ?? 0
        let duration = doubleValue(first["duration"]) ?? 1
        guard frameW > 0, frameH > 0, frameCountRaw > 0 else { return nil }
        let cols = cellCount(atlasExtent: atlasPixelSize.width, frameExtent: frameW)
        let rows = cellCount(atlasExtent: atlasPixelSize.height, frameExtent: frameH)
        let baseFrameRate = duration > 0 ? Double(frameCountRaw) / duration : Double(frameCountRaw)
        return WPEParticleSpriteSheet(
            cols: cols,
            rows: rows,
            frameCount: frameCountRaw,
            baseFrameRate: baseFrameRate,
            isAlphaMask: isAlphaMask
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }

    /// Frame extents are pixel-scale (see the sample sidecar above), so a sheet
    /// can never hold more cells than the atlas has pixels along that axis.
    /// The clamp is what keeps a malformed sub-pixel `width` from overflowing
    /// the division past `Int` and trapping the conversion.
    private static func cellCount(atlasExtent: Int, frameExtent: Double) -> Int {
        let limit = max(1, atlasExtent)
        let ratio = (Double(atlasExtent) / frameExtent).rounded()
        guard ratio.isFinite, ratio > 1 else { return 1 }
        guard ratio < Double(limit) else { return limit }
        return Int(ratio)
    }
}
