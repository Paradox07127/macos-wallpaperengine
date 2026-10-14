#if !LITE_BUILD && DEBUG
import Foundation
import simd

/// Independent arithmetic for the audited WPE hdr_downsample/combine_hdr sources.
/// No production builder, uniform resolver, shader rewriter or WPE GPU output supplies expected RGB.
/// An isolated native Metal calibration selects only the attachment storage rounding policy.
enum WPEParityHDRBloomReference {
    enum StorageRounding: String, CaseIterable {
        case toNearestEven
        case towardZero

        func store(_ value: Double) -> Double {
            let nearest = Float16(value)
            guard self == .towardZero, abs(Double(nearest)) > abs(value) else { return Double(nearest) }
            return Double(value < 0 ? nearest.nextUp : nearest.nextDown)
        }

        func store(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(store(rgb.x), store(rgb.y), store(rgb.z))
        }
    }

    struct Image {
        let width: Int
        let height: Int
        var pixels: [SIMD3<Double>]

        init(width: Int, height: Int, storageRounding: StorageRounding,
             pixel: (Double, Double) -> SIMD3<Double>) {
            self.width = width
            self.height = height
            pixels = (0 ..< height).flatMap { y in
                (0 ..< width).map { x in
                    storageRounding.store(pixel((Double(x) + 0.5) / Double(width),
                                                (Double(y) + 0.5) / Double(height)))
                }
            }
        }

        /// Normalized linear/clamp sampling on the physical texture grid.
        func sample(_ uv: SIMD2<Double>) -> SIMD3<Double> {
            let x = uv.x * Double(width) - 0.5
            let y = uv.y * Double(height) - 0.5
            let ix = Int(floor(x)), iy = Int(floor(y))
            let fx = x - floor(x), fy = y - floor(y)
            func texel(_ x: Int, _ y: Int) -> SIMD3<Double> {
                pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
            }
            return (texel(ix, iy) * (1 - fx) + texel(ix + 1, iy) * fx) * (1 - fy)
                + (texel(ix, iy + 1) * (1 - fx) + texel(ix + 1, iy + 1) * fx) * fy
        }
    }

    struct Result {
        let source: Image
        /// Final stored images: index 0 is _rt2 after all additive upsampling.
        let pyramid: [Image]
        let linear: Image
    }

    static func evaluate(width: Int, height: Int, color: SIMD3<Double>, gradient: Bool,
                         storageRounding: StorageRounding) -> Result {
        let source = Image(width: width, height: height, storageRounding: storageRounding) { u, v in
            // Asymmetric ramps plus edges keep max(RGB)=R while exposing spatial-filter errors.
            gradient ? color * SIMD3(1, 0.2 * u + (u >= 0.37 ? 0.8 : 0),
                                     0.2 * v + (v >= 0.61 ? 0.8 : 0)) : color
        }
        // Fixture contract: N=4, threshold=.4, feather=.5, scatter=.5, tint=1.
        // Odd gradients use the native strength default 2; constant fields use .5.
        let threshold = 0.4, knee = 0.2, scatter = 0.5
        let strength = (gradient ? 2.0 : 0.5) / (1 + pow(scatter, 2))
        var pyramid: [Image] = []
        for level in 0 ..< 4 {
            let divisor = 1 << (level + 1)
            let input = pyramid.last ?? source
            let offset = SIMD2(Double(1 << level) / Double(width), Double(1 << level) / Double(height))
            // Original RT ctor d2c60 and resize 161f40 clamp the divided physical grid to two.
            // RV0 above still uses the original logical canvas; it is not the clamped texture's texel size.
            let image = Image(width: max(2, width / divisor), height: max(2, height / divisor),
                              storageRounding: storageRounding) { u, v in
                var rgb = four(input, uv: SIMD2(u, v), offset: offset, cubic: false)
                if level == 0 {
                    rgb = simd_max(rgb, .zero)
                    let brightness = max(rgb.x, max(rgb.y, rgb.z))
                    let soft = min(max(brightness - (threshold - knee), 0), 2 * knee)
                    let contribution = max(soft * soft * 0.25 / (knee + 1e-5), brightness - threshold)
                        / max(brightness, 1e-5)
                    rgb *= contribution * strength
                }
                return rgb
            }
            pyramid.append(image)
        }
        for level in stride(from: 3, through: 1, by: -1) {
            let input = pyramid[level], destination = pyramid[level - 1]
            let offset = SIMD2(Double(1 << level) / Double(width), Double(1 << level) / Double(height))
            var image = destination
            for y in 0 ..< image.height {
                for x in 0 ..< image.width {
                    let uv = SIMD2((Double(x) + 0.5) / Double(image.width),
                                   (Double(y) + 0.5) / Double(image.height))
                    let rgb = destination.pixels[y * image.width + x]
                        + four(input, uv: uv, offset: offset, cubic: level >= 2) * scatter
                    image.pixels[y * image.width + x] = storageRounding.store(rgb)
                }
            }
            pyramid[level - 1] = image
        }
        let linear = Image(width: width, height: height, storageRounding: storageRounding) { u, v in
            let uv = SIMD2(u, v)
            let authored = source.sample(uv) + four(pyramid[0], uv: uv,
                                                    offset: SIMD2(1 / Double(width), 1 / Double(height)), cubic: false)
            return SIMD3(clamp(decode(authored.x)), clamp(decode(authored.y)), clamp(decode(authored.z)))
        }
        return Result(source: source, pyramid: pyramid, linear: linear)
    }

    static func sRGBByte(_ linear: Double) -> Double {
        let value = linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return (clamp(value) * 255).rounded()
    }

    private static func decode(_ authored: Double) -> Double {
        authored < 0.04045 ? authored / 12.92 : pow((authored + 0.055) / 1.055, 2.4)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func four(_ image: Image, uv: SIMD2<Double>, offset: SIMD2<Double>, cubic: Bool)
        -> SIMD3<Double> {
        var sum = SIMD3<Double>.zero
        for y in [-1.0, 1.0] {
            for x in [-1.0, 1.0] {
                let point = uv + SIMD2(x * offset.x, y * offset.y)
                sum += cubic ? bicubic(image, uv: point, logicalSize: 0.5 / offset) : image.sample(point)
            }
        }
        return sum * 0.25
    }

    /// Cubic B-spline, evaluated with the original four optimized bilinear samples.
    /// On odd dimensions logicalSize is fractional; replacing it with image.width/height changes the filter.
    private static func bicubic(_ image: Image, uv: SIMD2<Double>, logicalSize: SIMD2<Double>) -> SIMD3<Double> {
        let position = uv * logicalSize - SIMD2(repeating: 0.5)
        let base = SIMD2(floor(position.x), floor(position.y))
        func weights(_ f: Double) -> SIMD4<Double> {
            let f2 = f * f, f3 = f2 * f
            return SIMD4(1 - 3 * f + 3 * f2 - f3, 4 - 6 * f2 + 3 * f3,
                         1 + 3 * f + 3 * f2 - 3 * f3, f3) / 6
        }
        let wx = weights(position.x - base.x), wy = weights(position.y - base.y)
        let sx = SIMD2(wx.x + wx.y, wx.z + wx.w), sy = SIMD2(wy.x + wy.y, wy.z + wy.w)
        let xs = SIMD2(base.x - 0.5 + wx.y / sx.x, base.x + 1.5 + wx.w / sx.y) / logicalSize.x
        let ys = SIMD2(base.y - 0.5 + wy.y / sy.x, base.y + 1.5 + wy.w / sy.y) / logicalSize.y
        return image.sample(SIMD2(xs.x, ys.x)) * sx.x * sy.x
            + image.sample(SIMD2(xs.y, ys.x)) * sx.y * sy.x
            + image.sample(SIMD2(xs.x, ys.y)) * sx.x * sy.y
            + image.sample(SIMD2(xs.y, ys.y)) * sx.y * sy.y
    }
}
#endif
