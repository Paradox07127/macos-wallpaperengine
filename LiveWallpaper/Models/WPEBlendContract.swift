#if !LITE_BUILD
import Metal

struct WPEBlendContract: Equatable, Hashable, Sendable {
    let enabled: Bool
    let sourceRGB: MTLBlendFactor
    let destinationRGB: MTLBlendFactor
    let sourceAlpha: MTLBlendFactor
    let destinationAlpha: MTLBlendFactor
    let rgbOperation: MTLBlendOperation
    let alphaOperation: MTLBlendOperation
    let shaderPremultiplication: Bool
    let recognized: Bool

    init(_ authored: String) {
        let mode = authored.lowercased()
        let attachment = MTLRenderPipelineColorAttachmentDescriptor()
        Self.decode(mode, to: attachment)
        enabled = attachment.isBlendingEnabled
        sourceRGB = attachment.sourceRGBBlendFactor
        destinationRGB = attachment.destinationRGBBlendFactor
        sourceAlpha = attachment.sourceAlphaBlendFactor
        destinationAlpha = attachment.destinationAlphaBlendFactor
        rgbOperation = attachment.rgbBlendOperation
        alphaOperation = attachment.alphaBlendOperation
        let normalized = mode.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "").replacingOccurrences(of: " ", with: "")
        shaderPremultiplication = normalized.hasPrefix("premultiplied")
        recognized = ["disabled", "premultiplieddisabled", "premultiplied", "premultipliednormal",
                      "premultipliedtranslucent", "premultipliednormalmapped", "premultipliedadditive",
                      "additive", "premultipliedmultiply", "multiply", "premultipliedscreen", "screen",
                      "translucent", "normalmapped", "normal"].contains(mode)
    }

    func apply(to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = enabled
        attachment.sourceRGBBlendFactor = sourceRGB
        attachment.destinationRGBBlendFactor = destinationRGB
        attachment.sourceAlphaBlendFactor = sourceAlpha
        attachment.destinationAlphaBlendFactor = destinationAlpha
        attachment.rgbBlendOperation = rgbOperation
        attachment.alphaBlendOperation = alphaOperation
    }

    private static func decode(_ mode: String, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        switch mode {
        case "disabled", "premultiplieddisabled":
            attachment.isBlendingEnabled = false

        // Sources already store premultiplied RGB, so srcRGB=.one.
        case "premultiplied", "premultipliednormal", "premultipliedtranslucent", "premultipliednormalmapped":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        case "premultipliedadditive":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one

        case "additive":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one

        case "premultipliedmultiply":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one

        case "multiply":
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .destinationColor
            attachment.destinationRGBBlendFactor = .zero
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .one

        case "premultipliedscreen", "screen":
            // Premultiplied source: src + dst·(1−src) ≡ WPE's alpha-weighted
            // screen mix(dst, screen(dst,src), a) — black pixels leave dst intact.
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        default:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
    }
}
#endif
