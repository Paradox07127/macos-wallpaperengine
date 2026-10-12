#if !LITE_BUILD && DEBUG
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE parity D3D11 state to Metal mapping")
struct WPEParityMetalStateMappingTests {
    // MARK: Blend

    @Test("Translucent RT0 maps every blend field into colour attachment 0")
    func translucentBlend() throws {
        let pipeline = MTLRenderPipelineDescriptor()
        WPEParityMetalStateMapping.apply(.wpe(.translucent), to: pipeline)
        let attachment = try #require(pipeline.colorAttachments[0])
        #expect(attachment.isBlendingEnabled)
        #expect(attachment.sourceRGBBlendFactor == .sourceAlpha)
        #expect(attachment.destinationRGBBlendFactor == .oneMinusSourceAlpha)
        #expect(attachment.rgbBlendOperation == .add)
        #expect(attachment.sourceAlphaBlendFactor == .sourceAlpha)
        #expect(attachment.destinationAlphaBlendFactor == .oneMinusSourceAlpha)
        #expect(attachment.alphaBlendOperation == .add)
        #expect(attachment.writeMask == [.red, .green, .blue])
        #expect(!pipeline.isAlphaToCoverageEnabled)
    }

    @Test("Normal with alpha write, additive, and modifier ops")
    func otherBlends() {
        let normal = MTLRenderPipelineColorAttachmentDescriptor()
        WPEParityMetalStateMapping.apply(WPEParityBlendState.wpe(.normal, modifiers: .writeAlpha).renderTarget0, to: normal)
        #expect(!normal.isBlendingEnabled)
        #expect(normal.sourceRGBBlendFactor == .one)
        #expect(normal.destinationRGBBlendFactor == .zero)
        #expect(normal.writeMask == .all)

        let additive = MTLRenderPipelineColorAttachmentDescriptor()
        WPEParityMetalStateMapping.apply(WPEParityBlendState.wpe(.additive).renderTarget0, to: additive)
        #expect(additive.isBlendingEnabled)
        #expect(additive.sourceRGBBlendFactor == .sourceAlpha)
        #expect(additive.destinationRGBBlendFactor == .one)
        #expect(additive.destinationAlphaBlendFactor == .one)

        let alphaMax = MTLRenderPipelineColorAttachmentDescriptor()
        WPEParityMetalStateMapping.apply(
            WPEParityBlendState.wpe(.translucent, modifiers: [.alphaMax, .min, .multiply]).renderTarget0, to: alphaMax
        )
        #expect(alphaMax.rgbBlendOperation == .min)
        #expect(alphaMax.alphaBlendOperation == .max)
        #expect(alphaMax.sourceRGBBlendFactor == .destinationColor)
        #expect(alphaMax.sourceAlphaBlendFactor == .one)
        #expect(alphaMax.destinationAlphaBlendFactor == .one)
        #expect(alphaMax.writeMask == .all)
    }

    @Test("Alpha-to-coverage goes on the pipeline descriptor")
    func alphaToCoverage() {
        let pipeline = MTLRenderPipelineDescriptor()
        WPEParityMetalStateMapping.apply(.wpe(.alphaToCoverage), to: pipeline)
        #expect(pipeline.isAlphaToCoverageEnabled)
        #expect(!pipeline.colorAttachments[0].isBlendingEnabled)
    }

    @Test("Every D3D11 blend factor and op has a Metal counterpart")
    func factorTable() {
        let factors: [D3D11Blend: MTLBlendFactor] = [
            .zero: .zero, .one: .one, .srcColor: .sourceColor, .invSrcColor: .oneMinusSourceColor,
            .srcAlpha: .sourceAlpha, .invSrcAlpha: .oneMinusSourceAlpha, .destAlpha: .destinationAlpha,
            .invDestAlpha: .oneMinusDestinationAlpha, .destColor: .destinationColor,
            .invDestColor: .oneMinusDestinationColor, .srcAlphaSat: .sourceAlphaSaturated,
            .blendFactor: .blendColor, .invBlendFactor: .oneMinusBlendColor, .src1Color: .source1Color,
            .invSrc1Color: .oneMinusSource1Color, .src1Alpha: .source1Alpha, .invSrc1Alpha: .oneMinusSource1Alpha,
        ]
        #expect(factors.count == D3D11Blend.allCases.count)
        for (d3d, metal) in factors {
            #expect(WPEParityMetalStateMapping.blendFactor(d3d) == metal)
        }
        let ops: [D3D11BlendOp: MTLBlendOperation] = [
            .add: .add, .subtract: .subtract, .revSubtract: .reverseSubtract, .min: .min, .max: .max,
        ]
        for (d3d, metal) in ops {
            #expect(WPEParityMetalStateMapping.blendOperation(d3d) == metal)
        }
        #expect(WPEParityMetalStateMapping.writeMask(.alpha) == .alpha)
        #expect(WPEParityMetalStateMapping.writeMask([]) == [])
    }

    // MARK: Depth-stencil

    @Test("WPE depth states map to GREATER with the matching write flag and no stencil")
    func depthStencil() {
        let testWrite = WPEParityMetalStateMapping.depthStencilDescriptor(.wpe(depthTest: true, depthWrite: true))
        #expect(testWrite.depthCompareFunction == .greater)
        #expect(testWrite.isDepthWriteEnabled)
        for face in [testWrite.frontFaceStencil, testWrite.backFaceStencil] {
            #expect(face?.stencilCompareFunction == .always)
            #expect(face?.stencilFailureOperation == .keep)
            #expect(face?.depthFailureOperation == .keep)
            #expect(face?.depthStencilPassOperation == .keep)
        }

        let testOnly = WPEParityMetalStateMapping.depthStencilDescriptor(.wpe(depthTest: true, depthWrite: false))
        #expect(testOnly.depthCompareFunction == .greater)
        #expect(!testOnly.isDepthWriteEnabled)

        let off = WPEParityMetalStateMapping.depthStencilDescriptor(.wpe(depthTest: false, depthWrite: false))
        #expect(off.depthCompareFunction == .always)
        #expect(!off.isDepthWriteEnabled)
    }

    @Test("An enabled stencil maps ops, function and masks")
    func stencilEnabled() throws {
        var state = WPEParityDepthStencilState.wpe(depthTest: true, depthWrite: true)
        state.stencilEnable = true
        state.stencilReadMask = 0xF0
        state.stencilWriteMask = 0x0F
        state.frontFace.stencilFailOp = .incrSat
        state.frontFace.stencilDepthFailOp = .decr
        state.frontFace.stencilPassOp = .replace
        state.frontFace.stencilFunc = .equal
        let descriptor = WPEParityMetalStateMapping.depthStencilDescriptor(state)
        let front = try #require(descriptor.frontFaceStencil)
        #expect(front.stencilFailureOperation == .incrementClamp)
        #expect(front.depthFailureOperation == .decrementWrap)
        #expect(front.depthStencilPassOperation == .replace)
        #expect(front.stencilCompareFunction == .equal)
        #expect(front.readMask == 0xF0)
        #expect(front.writeMask == 0x0F)
        #expect(WPEParityMetalStateMapping.stencilDescriptor(.zeroed, read: 0xFF, write: 0xFF) == nil)
    }

    // MARK: Rasterizer

    @Test("Rasterizer: cull, counter-clockwise front, slope bias, depth clip")
    func rasterizer() {
        let biased = WPEParityMetalStateMapping.rasterSettings(
            .wpe(flipFrontFace: true, cullingDisabled: false, slopeDepthBias: true, multisample: true)
        )
        #expect(biased == WPEParityMetalRasterSettings(
            fillMode: .fill, cullMode: .front, frontFacing: .counterClockwise,
            depthBias: 0, depthSlopeScale: -4, depthBiasClamp: 0, depthClipMode: .clip
        ))
        #expect(WPEParityMetalStateMapping.rasterSettings(
            .wpe(flipFrontFace: false, cullingDisabled: false, slopeDepthBias: false, multisample: false)
        ).cullMode == .back)
        #expect(WPEParityMetalStateMapping.rasterSettings(
            .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false)
        ).cullMode == .none)

        var custom = WPEParityRasterizerState.wpe(
            flipFrontFace: false, cullingDisabled: false, slopeDepthBias: false, multisample: false
        )
        custom.frontCounterClockwise = false
        custom.depthClipEnable = false
        custom.fillMode = .wireframe
        custom.depthBias = 3
        custom.depthBiasClamp = 0.5
        #expect(WPEParityMetalStateMapping.rasterSettings(custom) == WPEParityMetalRasterSettings(
            fillMode: .lines, cullMode: .back, frontFacing: .clockwise,
            depthBias: 3, depthSlopeScale: 0, depthBiasClamp: 0.5, depthClipMode: .clamp
        ))
    }

    // MARK: Sampler

    @Test("Anisotropic clamp sampler maps every field")
    func anisotropicSampler() throws {
        let descriptor = try #require(WPEParityMetalStateMapping.samplerDescriptor(.wpe(filter: .anisotropic, address: .clamp)))
        #expect(descriptor.minFilter == .linear)
        #expect(descriptor.magFilter == .linear)
        #expect(descriptor.mipFilter == .linear)
        #expect(descriptor.maxAnisotropy == 8)
        #expect(descriptor.sAddressMode == .clampToEdge)
        #expect(descriptor.tAddressMode == .clampToEdge)
        #expect(descriptor.rAddressMode == .clampToEdge)
        #expect(descriptor.compareFunction == .never)
        #expect(descriptor.lodMinClamp == 0)
        #expect(descriptor.lodMaxClamp == .greatestFiniteMagnitude)
        #expect(descriptor.supportArgumentBuffers)
        if #available(macOS 26.0, *) {
            #expect(descriptor.lodBias == 0)
        }
    }

    @Test("Point and linear wrap samplers keep aniso at 1 and mip filtering on")
    func pointLinearSampler() throws {
        let point = try #require(WPEParityMetalStateMapping.samplerDescriptor(.wpe(filter: .point, address: .wrap)))
        #expect(point.minFilter == .nearest)
        #expect(point.magFilter == .nearest)
        #expect(point.mipFilter == .nearest)
        #expect(point.maxAnisotropy == 1)
        #expect(point.sAddressMode == .repeat)
        #expect(point.tAddressMode == .repeat)
        #expect(point.rAddressMode == .repeat)

        let linear = try #require(WPEParityMetalStateMapping.samplerDescriptor(.wpe(filter: .linear, address: .wrap)))
        #expect(linear.minFilter == .linear)
        #expect(linear.magFilter == .linear)
        #expect(linear.mipFilter == .linear)
        #expect(linear.maxAnisotropy == 1)
    }

    @Test("Comparison sampler: GREATER, border address, transparent black border")
    func comparisonSampler() throws {
        let descriptor = try #require(WPEParityMetalStateMapping.samplerDescriptor(.wpeComparison()))
        #expect(descriptor.compareFunction == .greater)
        #expect(descriptor.minFilter == .linear)
        #expect(descriptor.mipFilter == .linear)
        #expect(descriptor.maxAnisotropy == 1)
        #expect(descriptor.sAddressMode == .clampToBorderColor)
        #expect(descriptor.borderColor == .transparentBlack)
    }

    @Test("A border colour Metal cannot express yields no descriptor")
    func unsupportedBorderColor() {
        var state = WPEParitySamplerState.wpeComparison()
        state.borderColor = SIMD4(0.5, 0, 0, 1)
        #expect(WPEParityMetalStateMapping.samplerDescriptor(state) == nil)
        state.borderColor = SIMD4(1, 1, 1, 1)
        #expect(WPEParityMetalStateMapping.samplerDescriptor(state)?.borderColor == .opaqueWhite)
    }

    @Test("Every factory sampler builds a real MTLSamplerState")
    func makeSamplerStates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var states = [WPEParitySamplerState.wpeComparison()]
        for filter in WPEParitySamplerFilter.allCases {
            for address in WPEParitySamplerAddress.allCases {
                states.append(.wpe(filter: filter, address: address))
            }
        }
        for state in states {
            let descriptor = try #require(WPEParityMetalStateMapping.samplerDescriptor(state))
            #expect(device.makeSamplerState(descriptor: descriptor) != nil)
        }
    }
}
#endif
