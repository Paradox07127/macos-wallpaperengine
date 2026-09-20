import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// SCREENS.md S4's "封面 blur 70 saturate 1.3 opacity .22" behind the panel's own fill.
/// Core Image renders it once into a small bitmap instead of blurring a full-size cover every
/// frame; at this radius the cover carries no detail worth the pixels.
struct ModalBackdrop: View {
    let preview: CGImage?

    /// Small enough that the blur is cheap, large enough that stretching it over 880pt shows no
    /// banding — the image is already a wash at this radius.
    static let bitmapSize = CGSize(width: 160, height: 100)
    private nonisolated static let designPanelWidth: CGFloat = 880
    private nonisolated static let designBlurRadius: CGFloat = 70

    /// The design's 70 is against an 880pt panel, so the radius is a fraction of the width, not
    /// a constant: on the 160px bitmap the same wash needs ≈12.7.
    nonisolated static func blurRadius(forWidth width: CGFloat) -> CGFloat {
        width * designBlurRadius / designPanelWidth
    }

    @State private var bitmap: CGImage?

    var body: some View {
        Color.clear
            .overlay {
                if let bitmap {
                    Image(decorative: bitmap, scale: 1)
                        .resizable()
                }
            }
            .opacity(0.22)
            .allowsHitTesting(false)
            .task(id: preview.map(ObjectIdentifier.init)) {
                bitmap = Self.blurredBitmap(preview)
            }
    }

    static func blurredBitmap(_ source: CGImage?) -> CGImage? {
        guard let source, source.width > 0, source.height > 0 else { return nil }
        let extent = CGRect(origin: .zero, size: bitmapSize)
        let output = CIImage(cgImage: source)
            .transformed(by: CGAffineTransform(
                scaleX: bitmapSize.width / CGFloat(source.width),
                y: bitmapSize.height / CGFloat(source.height)
            ))
            // Without this the blur samples transparent black past the edges and the wash
            // fades out at the panel's border instead of filling it.
            .clampedToExtent()
            .applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: blurRadius(forWidth: bitmapSize.width)]
            )
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
        return CIContext().createCGImage(output, from: extent)
    }
}
