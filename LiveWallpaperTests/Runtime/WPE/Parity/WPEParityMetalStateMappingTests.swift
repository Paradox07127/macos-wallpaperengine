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

    @Test("Original modifier alpha ONE / ONE reaches GPU storage before presentation")
    func modifierAlphaGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try device.makeLibrary(source: Self.stateShader, options: nil)
        // Original FUN_140099f60 writes ONE / ONE at 0x14009a186/18e, 1a4/1ac and 1c2/1ca.
        let color = SIMD4<Float>(0.75, 0.5, 0.125, 0.5)
        let clear = MTLClearColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 0.25)
        for modifier in [WPEParityBlendModifiers.max, .min, .multiply] {
            let samples = try renderStateSamples(device: device, queue: queue, library: library,
                                                 state: .wpe(.translucent, modifiers: [modifier, .writeAlpha]),
                                                 color: color, clear: clear)
            #expect(samples.allSatisfy { abs($0.w - 0.75) < 0.001 })
        }
        let rgbOnly = try renderStateSamples(device: device, queue: queue, library: library,
                                             state: .wpe(.translucent, modifiers: .multiply), color: color, clear: clear)
        #expect(rgbOnly.allSatisfy { abs($0.w - 0.25) < 0.001 })
        let combined = try renderStateSamples(
            device: device, queue: queue, library: library,
            state: .wpe(.translucent, modifiers: [.premultiplied, .alphaMax, .max, .min, .multiply]),
            color: color, clear: clear
        )
        #expect(combined.allSatisfy { abs($0.w - 0.5) < 0.001 })
    }

    @Test("A2C writes discrete MSAA samples while ordinary translucent blending mixes every sample")
    func alphaToCoverageSamplesGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try device.makeLibrary(source: Self.stateShader, options: nil)
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        for alpha in [Float(0), 0.5, 1] {
            let samples = try renderStateSamples(device: device, queue: queue, library: library,
                                                 state: .wpe(.alphaToCoverage), color: SIMD4(1, 0, 0, alpha), clear: clear)
            #expect(samples.allSatisfy { abs($0.x) < 0.001 || abs($0.x - 1) < 0.001 })
            if alpha == 0 {
                #expect(samples.allSatisfy { abs($0.x) < 0.001 })
            } else if alpha == 1 {
                #expect(samples.allSatisfy { abs($0.x - 1) < 0.001 })
            } else {
                // Matching sample positions does not establish the original fractional alpha-to-coverage mask.
                #expect(samples.contains { abs($0.x) < 0.001 })
                #expect(samples.contains { abs($0.x - 1) < 0.001 })
            }
        }
        let normal = try renderStateSamples(device: device, queue: queue, library: library,
                                            state: .wpe(.normal), color: SIMD4(1, 0, 0, 0.5), clear: clear)
        #expect(normal.allSatisfy { abs($0.x - 1) < 0.001 })
        let translucent = try renderStateSamples(device: device, queue: queue, library: library,
                                                 state: .wpe(.translucent), color: SIMD4(1, 0, 0, 0.5), clear: clear)
        #expect(translucent.allSatisfy { abs($0.x - 0.5) < 0.001 })
    }

    @Test("Default Metal sample positions and indices match WPE's D3D standard pattern")
    func nativeStandardSamplePositionsGPU() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        try #require(device.areProgrammableSamplePositionsSupported)
        let queue = try #require(device.makeCommandQueue())
        let library = try device.makeLibrary(source: Self.stateShader, options: nil)
        // Original 14012b701 writes SampleDesc.Quality = 0xffffffff on feature levels 10.1 and later.
        // D3D11.3 specification 19.2.4: offsets from pixel centre in sixteenths, in sample-index order.
        let patterns: [[SIMD2<Float>]] = [
            [SIMD2(4, 4), SIMD2(-4, -4)],
            [SIMD2(-2, -6), SIMD2(6, -2), SIMD2(-6, 2), SIMD2(2, 6)],
            [SIMD2(1, -3), SIMD2(-1, 3), SIMD2(5, 1), SIMD2(-3, -5),
             SIMD2(-5, 5), SIMD2(-7, -1), SIMD2(3, 7), SIMD2(7, -7)],
        ]
        for offsets in patterns {
            let sampleCount = offsets.count
            try #require(device.supportsTextureSampleCount(sampleCount))
            let expected = offsets.map { $0 / 16 + SIMD2<Float>(repeating: 0.5) }
            let defaults = device.getDefaultSamplePositions(sampleCount: sampleCount)
            #expect(defaults.count == sampleCount)
            for (position, expected) in zip(defaults, expected) {
                #expect(SIMD2(position.x, position.y) == expected)
            }
            let samples = try renderStateSamples(
                device: device, queue: queue, library: library, state: .wpe(.normal), color: .zero,
                clear: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0),
                sampleCount: sampleCount, fragmentName: "samplePositionFragment"
            )
            for (index, value) in samples.enumerated() {
                #expect(SIMD2(value.x, value.y) == expected[index % sampleCount])
                #expect(value.z == Float(index % sampleCount))
            }
        }
    }

    /// Exercises the production state mapping on a stored multisampled RT, then reads each sample with a GPU kernel.
    /// This is a state boundary guard; material/planner/factory wiring needs the separate scene production guard.
    private func renderStateSamples(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary,
                                    state: WPEParityBlendState, color: SIMD4<Float>, clear: MTLClearColor,
                                    sampleCount: Int = 4, fragmentName: String = "stateFragment") throws -> [SIMD4<Float>] {
        let side = 4
        try #require(device.supportsTextureSampleCount(sampleCount))
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: side,
                                                                         height: side, mipmapped: false)
        textureDescriptor.textureType = .type2DMultisample
        textureDescriptor.sampleCount = sampleCount
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        let target = try #require(device.makeTexture(descriptor: textureDescriptor))
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "stateVertex")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: fragmentName)
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba16Float
        WPEParityMetalStateMapping.apply(state, to: pipelineDescriptor)
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let sampleFunction = try #require(library.makeFunction(name: "readSamples"))
        let readSamples = try device.makeComputePipelineState(function: sampleFunction)
        let count = side * side * sampleCount
        let output = try #require(device.makeBuffer(length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let commandBuffer = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clear
        let render = try #require(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        render.setRenderPipelineState(pipeline)
        var source = color
        render.setFragmentBytes(&source, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        render.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        render.endEncoding()
        let compute = try #require(commandBuffer.makeComputeCommandEncoder())
        compute.setComputePipelineState(readSamples)
        compute.setTexture(target, index: 0)
        compute.setBuffer(output, offset: 0, index: 0)
        compute.dispatchThreads(MTLSize(width: side, height: side, depth: sampleCount),
                                threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
        compute.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        try #require(commandBuffer.status == .completed)
        try #require(commandBuffer.error == nil)
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: count))
    }

    private static let stateShader = """
    #include <metal_stdlib>
    using namespace metal;
    struct StateVertex { float4 position [[position]]; };
    vertex StateVertex stateVertex(uint id [[vertex_id]]) {
        const float2 positions[] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
        return {float4(positions[id], 0, 1)};
    }
    fragment float4 stateFragment(constant float4& color [[buffer(0)]]) { return color; }
    fragment float4 samplePositionFragment(float2 position [[sample_position]], uint sample [[sample_id]]) {
        return float4(position, float(sample), 1.0);
    }
    kernel void readSamples(texture2d_ms<float, access::read> source [[texture(0)]],
                            device float4* output [[buffer(0)]], uint3 id [[thread_position_in_grid]]) {
        if (id.x >= source.get_width() || id.y >= source.get_height() || id.z >= source.get_num_samples()) return;
        uint index = (id.y * source.get_width() + id.x) * source.get_num_samples() + id.z;
        output[index] = source.read(id.xy, id.z);
    }
    """

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
