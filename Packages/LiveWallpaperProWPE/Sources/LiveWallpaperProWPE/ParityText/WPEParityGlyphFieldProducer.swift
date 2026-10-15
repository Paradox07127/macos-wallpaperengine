import CFreeType
import CWPESDF

/// Numeric field prepared from the existing face's current size, before the atlas takes ownership of its bytes.
/// The raw float stages are optional diagnostic outputs; they are never retained by the atlas or uploaded.
public struct WPEParityGlyphField: Sendable {
    public let bitmap: WPEParityGlyphBitmap
    public let box: WPEParityGlyphBox
    public let yPpem: Int
    public let isColor: Bool
    public let transform: Transform
    public let beforeCorrection: [Float]
    public let afterCorrection: [Float]

    /// The original six-double descriptor, kept as scalars rather than exposing a C++ object to Swift.
    public struct Transform: Equatable, Sendable {
        public let scaleX: Double, scaleY: Double
        public let translateX: Double, translateY: Double
        public let distanceScale: Double, distanceOffset: Double
    }
}

/// Two CPU planes from one loaded COLOR slot, before the existing atlas owns their bytes. The caller must
/// qualify the native atlas group's colour scale; this value does not infer it or own glyph references.
public struct WPEParityColorGlyphField: Sendable {
    public let primary: WPEParityGlyphField
    public let companion: WPEParityGlyphBitmap
    public let companionScale: Int
}

enum WPEParityGlyphFieldProducer {
    /// Only explicitly qualified scales 1/2. Synchronously borrows glyphField's same loaded FT slot.
    static func companion(face: FT_Face, field: WPEParityGlyphField, scale: Int) -> WPEParityGlyphBitmap? {
        guard field.isColor, scale == 1 || scale == 2,
              field.bitmap.width <= 4096 / scale, field.bitmap.rows <= 4096 / scale else { return nil }
        let t = field.transform
        var transform = WPEFieldTransform(scale_x: t.scaleX, scale_y: t.scaleY,
                                          translate_x: t.translateX, translate_y: t.translateY,
                                          distance_scale: t.distanceScale, distance_offset: t.distanceOffset)
        let width = field.bitmap.width * scale, height = field.bitmap.rows * scale
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let status = rgba.withUnsafeMutableBufferPointer { pixels in
            var output = WPEFieldOutput(width: Int32(width), height: Int32(height),
                                        rgba: pixels.baseAddress, rgba_capacity: pixels.count,
                                        before_correction: nil, before_capacity: 0,
                                        after_correction: nil, after_capacity: 0)
            return withColorBitmap(face.pointee.glyph.pointee) { bitmap in
                var bitmap = bitmap
                return wpe_field_color_companion(&bitmap, &transform, Int32(scale), &output)
            } ?? WPE_FIELD_INVALID_INPUT
        }
        guard status == WPE_FIELD_OK else { return nil }
        return WPEParityGlyphBitmap(width: width, rows: height, pixelMode: .rgba, pixels: rgba)
    }

    /// Called synchronously while FontFace owns the loaded slot. Never opens or retains another FT face.
    static func produce(face: FT_Face, box: WPEParityGlyphBox, isColor: Bool,
                        captureStages: Bool) -> WPEParityGlyphField? {
        let width = Int64(box.xMax) - Int64(box.xMin)
        let height = Int64(box.yMax) - Int64(box.yMin)
        // The zero-area native branch does not generate pixels. It needs a separate stale-cell qualification.
        guard width > 0, height > 0 else { return nil }
        let ppem = max(Int(face.pointee.size.pointee.metrics.y_ppem), 1)
        let nominalScale = Float(32) / Float(ppem)
        let contentWidth = max(1, Int(Float(width) * nominalScale))
        let contentHeight = max(1, Int(Float(height) * nominalScale))
        guard contentWidth <= 4072, contentHeight <= 4072 else { return nil }
        let cellWidth = contentWidth + 24, cellHeight = contentHeight + 24
        // Original caller first truncates content extents, then computes these in float32, promoting to double.
        let scale = Float(max(contentWidth, contentHeight)) / Float(max(width, height))
        let range = Float(24) / scale
        let offset = -(Double(range) * -0.5)
        let distanceScale = 1 / (Double(range) * 0.5 - Double(range) * -0.5)
        var transform = WPEFieldTransform(
            scale_x: Double(scale), scale_y: Double(scale),
            translate_x: Double(Float(12) / scale - Float(box.xMin)),
            translate_y: Double(Float(12) / scale - Float(box.yMin)),
            distance_scale: distanceScale, distance_offset: offset
        )
        let count = cellWidth * cellHeight
        let channels = isColor ? 4 : 3
        var rgba = [UInt8](repeating: 0, count: count * 4)
        var before = [Float](repeating: 0, count: captureStages && !isColor ? count * channels : 0)
        var after = [Float](repeating: 0, count: captureStages ? count * channels : 0)
        let status = rgba.withUnsafeMutableBufferPointer { pixels in
            before.withUnsafeMutableBufferPointer { pre in
                after.withUnsafeMutableBufferPointer { post in
                    var output = WPEFieldOutput(
                        width: Int32(cellWidth), height: Int32(cellHeight),
                        rgba: pixels.baseAddress, rgba_capacity: pixels.count,
                        before_correction: pre.isEmpty ? nil : pre.baseAddress, before_capacity: pre.count,
                        after_correction: post.isEmpty ? nil : post.baseAddress, after_capacity: post.count
                    )
                    if isColor {
                        return withColorBitmap(face.pointee.glyph.pointee) { bitmap in
                            var bitmap = bitmap
                            return wpe_field_color(&bitmap, &transform, &output)
                        } ?? WPE_FIELD_INVALID_INPUT
                    }
                    return wpe_field_outline(&face.pointee.glyph.pointee.outline, &transform, &output)
                }
            }
        }
        guard status == WPE_FIELD_OK else { return nil }
        return WPEParityGlyphField(
            bitmap: WPEParityGlyphBitmap(width: cellWidth, rows: cellHeight, pixelMode: .rgba, pixels: rgba),
            box: box, yPpem: ppem, isColor: isColor,
            transform: .init(scaleX: transform.scale_x, scaleY: transform.scale_y,
                             translateX: transform.translate_x, translateY: transform.translate_y,
                             distanceScale: transform.distance_scale, distanceOffset: transform.distance_offset),
            beforeCorrection: before, afterCorrection: after
        )
    }

    private static func withColorBitmap<Result>(_ slot: FT_GlyphSlotRec,
                                                body: (WPEFieldBGRA) -> Result) -> Result? {
        let bitmap = slot.bitmap
        guard UInt32(bitmap.pixel_mode) == FT_PIXEL_MODE_BGRA.rawValue, let top = bitmap.buffer else { return nil }
        let width = Int(bitmap.width), rows = Int(bitmap.rows), pitch = Int(bitmap.pitch)
        guard width > 0, rows > 0, width <= 4096, rows <= 4096, abs(pitch) >= width * 4 else { return nil }
        let row0 = pitch < 0 ? (rows - 1) * -pitch : 0
        let allocation = top - row0
        return body(WPEFieldBGRA(bytes: allocation, capacity: (rows - 1) * abs(pitch) + width * 4,
                                 row0_offset: row0, width: Int32(width), rows: Int32(rows),
                                 pitch: bitmap.pitch, left: slot.bitmap_left, top: slot.bitmap_top))
    }
}
