#if !LITE_BUILD
import LiveWallpaperProWPE
import Metal

/// Metal has no rasterizer state object; these are the encoder settings a D3D11 rasterizer desc maps to.
/// ScissorEnable FALSE needs no setting (Metal's default scissor covers the target); MultisampleEnable and
/// AntialiasedLineEnable only affect line rasterization in D3D11 and have no Metal counterpart.
struct WPEParityMetalRasterSettings: Equatable, Sendable {
    var fillMode: MTLTriangleFillMode
    var cullMode: MTLCullMode
    var frontFacing: MTLWinding
    var depthBias: Float
    var depthSlopeScale: Float
    var depthBiasClamp: Float
    var depthClipMode: MTLDepthClipMode
}

enum WPEParityMetalStateMapping {
    // MARK: Blend

    /// Writes RT0 into colour attachment 0 and alpha-to-coverage into the pipeline.
    static func apply(_ state: WPEParityBlendState, to pipeline: MTLRenderPipelineDescriptor) {
        pipeline.isAlphaToCoverageEnabled = state.alphaToCoverageEnable
        apply(state.renderTarget0, to: pipeline.colorAttachments[0])
    }

    static func apply(_ rt: WPEParityRenderTargetBlendDesc, to attachment: MTLRenderPipelineColorAttachmentDescriptor) {
        attachment.isBlendingEnabled = rt.blendEnable
        attachment.sourceRGBBlendFactor = blendFactor(rt.srcBlend)
        attachment.destinationRGBBlendFactor = blendFactor(rt.destBlend)
        attachment.rgbBlendOperation = blendOperation(rt.blendOp)
        attachment.sourceAlphaBlendFactor = blendFactor(rt.srcBlendAlpha)
        attachment.destinationAlphaBlendFactor = blendFactor(rt.destBlendAlpha)
        attachment.alphaBlendOperation = blendOperation(rt.blendOpAlpha)
        attachment.writeMask = writeMask(rt.renderTargetWriteMask)
    }

    static func blendFactor(_ blend: D3D11Blend) -> MTLBlendFactor {
        switch blend {
        case .zero: .zero
        case .one: .one
        case .srcColor: .sourceColor
        case .invSrcColor: .oneMinusSourceColor
        case .srcAlpha: .sourceAlpha
        case .invSrcAlpha: .oneMinusSourceAlpha
        case .destAlpha: .destinationAlpha
        case .invDestAlpha: .oneMinusDestinationAlpha
        case .destColor: .destinationColor
        case .invDestColor: .oneMinusDestinationColor
        case .srcAlphaSat: .sourceAlphaSaturated
        case .blendFactor: .blendColor
        case .invBlendFactor: .oneMinusBlendColor
        case .src1Color: .source1Color
        case .invSrc1Color: .oneMinusSource1Color
        case .src1Alpha: .source1Alpha
        case .invSrc1Alpha: .oneMinusSource1Alpha
        }
    }

    static func blendOperation(_ op: D3D11BlendOp) -> MTLBlendOperation {
        switch op {
        case .add: .add
        case .subtract: .subtract
        case .revSubtract: .reverseSubtract
        case .min: .min
        case .max: .max
        }
    }

    static func writeMask(_ mask: D3D11ColorWriteMask) -> MTLColorWriteMask {
        var result: MTLColorWriteMask = []
        if mask.contains(.red) {
            result.insert(.red)
        }
        if mask.contains(.green) {
            result.insert(.green)
        }
        if mask.contains(.blue) {
            result.insert(.blue)
        }
        if mask.contains(.alpha) {
            result.insert(.alpha)
        }
        return result
    }

    // MARK: Depth-stencil

    static func depthStencilDescriptor(_ state: WPEParityDepthStencilState) -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        // DepthEnable FALSE turns off the depth write as well, whatever DepthWriteMask says.
        descriptor.depthCompareFunction = state.depthEnable ? compareFunction(state.depthFunc) : .always
        descriptor.isDepthWriteEnabled = state.depthEnable && state.depthWriteMask == .all
        // Metal's default face (always pass, keep) is a disabled stencil; nil resets to it.
        if state.stencilEnable {
            descriptor.frontFaceStencil = stencilDescriptor(state.frontFace, read: state.stencilReadMask,
                                                            write: state.stencilWriteMask)
            descriptor.backFaceStencil = stencilDescriptor(state.backFace, read: state.stencilReadMask,
                                                           write: state.stencilWriteMask)
        }
        return descriptor
    }

    /// `nil` for a zeroed face: D3D11 rejects that desc while StencilEnable is TRUE.
    static func stencilDescriptor(_ face: WPEParityDepthStencilOpDesc, read: UInt8, write: UInt8) -> MTLStencilDescriptor? {
        guard let fail = face.stencilFailOp, let depthFail = face.stencilDepthFailOp,
              let pass = face.stencilPassOp, let function = face.stencilFunc else { return nil }
        let descriptor = MTLStencilDescriptor()
        descriptor.stencilFailureOperation = stencilOperation(fail)
        descriptor.depthFailureOperation = stencilOperation(depthFail)
        descriptor.depthStencilPassOperation = stencilOperation(pass)
        descriptor.stencilCompareFunction = compareFunction(function)
        descriptor.readMask = UInt32(read)
        descriptor.writeMask = UInt32(write)
        return descriptor
    }

    static func compareFunction(_ function: D3D11ComparisonFunc) -> MTLCompareFunction {
        switch function {
        case .never: .never
        case .less: .less
        case .equal: .equal
        case .lessEqual: .lessEqual
        case .greater: .greater
        case .notEqual: .notEqual
        case .greaterEqual: .greaterEqual
        case .always: .always
        }
    }

    static func stencilOperation(_ op: D3D11StencilOp) -> MTLStencilOperation {
        switch op {
        case .keep: .keep
        case .zero: .zero
        case .replace: .replace
        case .incrSat: .incrementClamp
        case .decrSat: .decrementClamp
        case .invert: .invert
        case .incr: .incrementWrap
        case .decr: .decrementWrap
        }
    }

    // MARK: Rasterizer

    static func rasterSettings(_ state: WPEParityRasterizerState) -> WPEParityMetalRasterSettings {
        WPEParityMetalRasterSettings(
            fillMode: state.fillMode == .solid ? .fill : .lines,
            cullMode: cullMode(state.cullMode),
            frontFacing: state.frontCounterClockwise ? .counterClockwise : .clockwise,
            depthBias: Float(state.depthBias),
            depthSlopeScale: state.slopeScaledDepthBias,
            depthBiasClamp: state.depthBiasClamp,
            depthClipMode: state.depthClipEnable ? .clip : .clamp
        )
    }

    static func cullMode(_ mode: D3D11CullMode) -> MTLCullMode {
        switch mode {
        case .none: .none
        case .front: .front
        case .back: .back
        }
    }

    // MARK: Sampler

    /// `nil` when Metal cannot express the desc: a BORDER address with a border colour other than
    /// transparent black, opaque black or opaque white, or a non-zero LOD bias before macOS 26.
    static func samplerDescriptor(_ state: WPEParitySamplerState) -> MTLSamplerDescriptor? {
        let descriptor = MTLSamplerDescriptor()
        let filterBits = state.filter.rawValue
        descriptor.minFilter = filterBits & 0x10 != 0 ? .linear : .nearest
        descriptor.magFilter = filterBits & 0x04 != 0 ? .linear : .nearest
        // D3D11 always samples the mip chain, so POINT maps to .nearest, never .notMipmapped.
        descriptor.mipFilter = filterBits & 0x01 != 0 ? .linear : .nearest
        descriptor.maxAnisotropy = filterBits & 0x40 != 0 ? Int(state.maxAnisotropy) : 1
        // D3D11 ignores ComparisonFunc unless the filter is a comparison filter.
        if filterBits & 0x80 != 0 {
            descriptor.compareFunction = compareFunction(state.comparisonFunc)
        }
        descriptor.sAddressMode = addressMode(state.addressU)
        descriptor.tAddressMode = addressMode(state.addressV)
        descriptor.rAddressMode = addressMode(state.addressW)
        if [state.addressU, state.addressV, state.addressW].contains(.border) {
            guard let color = borderColor(state.borderColor) else { return nil }
            descriptor.borderColor = color
        }
        descriptor.lodMinClamp = state.minLOD
        descriptor.lodMaxClamp = state.maxLOD
        if #available(macOS 26.0, *) {
            descriptor.lodBias = state.mipLODBias
        } else if state.mipLODBias != 0 {
            return nil
        }
        descriptor.supportArgumentBuffers = true
        return descriptor
    }

    static func addressMode(_ mode: D3D11TextureAddressMode) -> MTLSamplerAddressMode {
        switch mode {
        case .wrap: .repeat
        case .mirror: .mirrorRepeat
        case .clamp: .clampToEdge
        case .border: .clampToBorderColor
        case .mirrorOnce: .mirrorClampToEdge
        }
    }

    static func borderColor(_ rgba: SIMD4<Float>) -> MTLSamplerBorderColor? {
        switch rgba {
        case SIMD4(0, 0, 0, 0): .transparentBlack
        case SIMD4(0, 0, 0, 1): .opaqueBlack
        case SIMD4(1, 1, 1, 1): .opaqueWhite
        default: nil
        }
    }
}
#endif
