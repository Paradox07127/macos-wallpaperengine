import LiveWallpaperProWPE
import Testing

struct ParityPostProcessTests {
    @Test func ldrBloomMatchesListB() throws {
        var config = bloomConfig()
        config.colorCorrectionEnabled = true
        config.fadeActive = true
        let frame = WPEParityPostProcessBuilder.build(config)
        #expect(sequence(frame) == ldrSequence + ["copy backbuffer -> _rt_FullFrameBuffer",
                                                  "draw ccsimple [_rt_FullFrameBuffer] normal",
                                                  "draw fade [] translucent", "present backbuffer"])
        #expect(frame.draws.last?.geometry == .fullScreenQuad)
        #expect(frame.draws.first { $0.shader == "combine" }?.outputAlpha == 1)
        try verifyCompilation(frame)
    }

    @Test func hdrBloomHasExactPyramidAndCubicLastTwoUpsamples() throws {
        var config = bloomConfig()
        config.hdrEnabled = true
        config.backbufferFormat = "rgba16float"
        let frame = WPEParityPostProcessBuilder.build(config)
        #expect(sequence(frame) == hdrSequence + ["present backbuffer"])
        let expected: [(String, Int, Int)] = [
            ("_rt_2FrameBuffer", 1920, 1080),
            ("_rt_4FrameBuffer", 960, 540),
            ("_rt_8FrameBuffer", 480, 270),
            ("_rt_16FrameBuffer", 240, 135),
            ("_rt_32FrameBuffer", 120, 67),
            ("_rt_64FrameBuffer", 60, 33),
            ("_rt_128FrameBuffer", 30, 16),
            ("_rt_256FrameBuffer", 15, 8),
        ]
        for (name, width, height) in expected {
            let resource = try #require(frame.resources.first { $0.id.rawValue == name })
            #expect(resource.width == width && resource.height == height)
            #expect(resource.format == "rgba16float")
            #expect(resource.lifetime == .frameTransient)
        }
        #expect(!frame.resources.contains { $0.id == "_rt_Bloom" })
        try verifyCompilation(frame)
    }

    @Test(arguments: [false, true]) func noBloomWithAndWithoutHDR(hdr: Bool) throws {
        var config = baseConfig()
        config.hdrEnabled = hdr
        let frame = WPEParityPostProcessBuilder.build(config)
        let expected = hdr ? ["copy backbuffer -> _rt_FullFrameBuffer",
                              "draw combine_srgb [_rt_FullFrameBuffer] normal", "present backbuffer"]
            : ["present backbuffer"]
        #expect(sequence(frame) == expected)
        #expect(!frame.resources.contains { $0.lifetime == .frameTransient && $0.id != "backbufferDepth" })
        try verifyCompilation(frame)
    }

    @Test(arguments: [false, true], [false, true])
    func colorCorrectionAndFadeAreIndependent(cc: Bool, fade: Bool) throws {
        var config = baseConfig()
        config.colorCorrectionEnabled = cc
        config.fadeActive = fade
        let frame = WPEParityPostProcessBuilder.build(config)
        var expected: [String] = []
        if cc {
            expected += ["copy backbuffer -> _rt_FullFrameBuffer", "draw ccsimple [_rt_FullFrameBuffer] normal"]
        }
        if fade {
            expected.append("draw fade [] translucent")
        }
        #expect(sequence(frame) == expected + ["present backbuffer"])
        try verifyCompilation(frame)
    }

    @Test(arguments: [0, 1, 2]) func everyBloomGateDisablesTheChain(gate: Int) throws {
        let enabled = bloomConfig()
        var disabled = enabled
        switch gate {
        case 0: disabled.sceneBloomEnabled = false
        case 1: disabled.userBloomEnabled = false
        default: disabled.objectTableNonEmpty = false
        }
        let on = WPEParityPostProcessBuilder.build(enabled)
        let off = WPEParityPostProcessBuilder.build(disabled)
        #expect(sequence(on) == ldrSequence + ["present backbuffer"])
        #expect(sequence(off) == ["present backbuffer"])
        try verifyCompilation(on)
        try verifyCompilation(off)
    }

    @Test func hdrSwitchReplacesLDRChain() throws {
        var config = bloomConfig()
        let ldr = WPEParityPostProcessBuilder.build(config)
        config.hdrEnabled = true
        let hdr = WPEParityPostProcessBuilder.build(config)
        #expect(sequence(ldr) == ldrSequence + ["present backbuffer"])
        #expect(sequence(hdr) == hdrSequence + ["present backbuffer"])
        try verifyCompilation(ldr)
        try verifyCompilation(hdr)
    }

    @Test(arguments: [false, true]) func msaaLeavesTheResolveToTheSceneBuilder(bloom: Bool) throws {
        var config = bloom ? bloomConfig() : baseConfig()
        let singleSample = WPEParityPostProcessBuilder.build(config)
        config.msaaSampleCount = 4
        let msaa = WPEParityPostProcessBuilder.build(config)
        #expect(sequence(msaa) == sequence(singleSample))
        #expect(sequence(singleSample) == (bloom ? ldrSequence : []) + ["present backbuffer"])
        try verifyCompilation(singleSample, msaaSamples: 1)
        try verifyCompilation(msaa, msaaSamples: 4)
    }

    @Test(arguments: [false, true]) func mipCopyPrecedesPostProcessing(bloom: Bool) throws {
        var config = bloom ? bloomConfig() : baseConfig()
        config.hdrEnabled = true
        config.sceneMipMappedFrameBufferEnabled = true
        config.qualityMipMappedFrameBufferEnabled = true
        let frame = WPEParityPostProcessBuilder.build(config)
        let mipSequence = ["copy backbuffer -> _rt_MipMappedFrameBuffer", "mips _rt_MipMappedFrameBuffer"]
        let expected = bloom ? [hdrSequence[0]] + mipSequence + Array(hdrSequence.dropFirst())
            : mipSequence + ["copy backbuffer -> _rt_FullFrameBuffer", "draw combine_srgb [_rt_FullFrameBuffer] normal"]
        #expect(sequence(frame) == expected + ["present backbuffer"])
        let mip = try #require(frame.resources.first { $0.id == "_rt_MipMappedFrameBuffer" })
        #expect(mip.width == 3840 && mip.height == 2160 && mip.mipCount == 12)
        #expect(mip.format == config.backbufferFormat && mip.lifetime == .persistent)
        try verifyCompilation(frame)
    }

    @Test(arguments: [0, 1]) func eachMipGateSuppressesCopyAndGeneration(gate: Int) throws {
        var config = bloomConfig()
        config.sceneMipMappedFrameBufferEnabled = true
        config.qualityMipMappedFrameBufferEnabled = true
        let enabled = WPEParityPostProcessBuilder.build(config)
        if gate == 0 {
            config.sceneMipMappedFrameBufferEnabled = false
        } else {
            config.qualityMipMappedFrameBufferEnabled = false
        }
        let disabled = WPEParityPostProcessBuilder.build(config)
        #expect(sequence(enabled) == [ldrSequence[0], "copy backbuffer -> _rt_MipMappedFrameBuffer",
                                      "mips _rt_MipMappedFrameBuffer"] + Array(ldrSequence.dropFirst()) + ["present backbuffer"])
        #expect(sequence(disabled) == ldrSequence + ["present backbuffer"])
        try verifyCompilation(disabled)
        try verifyCompilation(enabled)
    }

    @Test func uniformValuesAndTexelsReachDrawStateWithoutConversion() throws {
        var config = bloomConfig()
        config.bloomParameters = ["g_Bloom": SIMD4<Float>(0.37, 1.7, -0.2, 4.25)]
        let frame = WPEParityPostProcessBuilder.build(config)
        #expect(frame.draws.allSatisfy { $0.bloomParameters == config.bloomParameters })
        #expect(frame.draws.map(\.texelSizes) == [
            [SIMD2<Float>(1 / 3840, 1 / 2160)],
            [SIMD2<Float>(1 / 960, 1 / 540)],
            [SIMD2<Float>(1 / 480, 1 / 270)],
            [SIMD2<Float>(1 / 3840, 1 / 2160), SIMD2<Float>(1 / 480, 1 / 270)],
        ])
        try verifyCompilation(frame)
    }

    @Test func fractionalSizesTruncateAndNeverBecomeZero() throws {
        var config = bloomConfig()
        config.hdrEnabled = true
        config.backbufferWidth = 17
        config.backbufferHeight = 3
        let frame = WPEParityPostProcessBuilder.build(config)
        #expect(frame.resources.first { $0.id == "_rt_2FrameBuffer" }?.width == 8)
        #expect(frame.resources.first { $0.id == "_rt_2FrameBuffer" }?.height == 1)
        #expect(frame.resources.first { $0.id == "_rt_256FrameBuffer" }?.width == 1)
        #expect(frame.resources.first { $0.id == "_rt_256FrameBuffer" }?.height == 1)
        try verifyCompilation(frame)
    }

    @Test func ldrTargetsUseQuarterAndEighthRGBA8Storage() throws {
        let frame = WPEParityPostProcessBuilder.build(bloomConfig())
        for (id, width, height) in [("_rt_4FrameBuffer", 960, 540),
                                    ("_rt_8FrameBuffer", 480, 270), ("_rt_Bloom", 480, 270)] {
            let resource = try #require(frame.resources.first { $0.id.rawValue == id })
            #expect(resource.width == width && resource.height == height)
            #expect(resource.format == "rgba8unorm" && resource.lifetime == .frameTransient)
        }
        try verifyCompilation(frame)
    }

    @Test func allNonMipSwitchCombinationsCompile() throws {
        for mask in 0 ..< 128 {
            var config = baseConfig()
            config.sceneBloomEnabled = mask & 1 != 0
            config.userBloomEnabled = mask & 2 != 0
            config.objectTableNonEmpty = mask & 4 != 0
            config.hdrEnabled = mask & 8 != 0
            config.msaaSampleCount = mask & 16 != 0 ? 4 : 1
            config.colorCorrectionEnabled = mask & 32 != 0
            config.fadeActive = mask & 64 != 0
            try verifyCompilation(WPEParityPostProcessBuilder.build(config), msaaSamples: config.msaaSampleCount)
        }
    }

    private func baseConfig() -> WPEParityPostProcessConfig {
        WPEParityPostProcessConfig(backbufferWidth: 3840, backbufferHeight: 2160)
    }

    private func bloomConfig() -> WPEParityPostProcessConfig {
        WPEParityPostProcessConfig(sceneBloomEnabled: true, userBloomEnabled: true, objectTableNonEmpty: true,
                                   backbufferWidth: 3840, backbufferHeight: 2160)
    }

    /// Stands in for the scene builder: clear the scene target and, with MSAA, resolve it and leave it bound.
    private func compile(_ frame: WPEParityPostProcessFrame, msaaSamples: Int) throws -> WPECompiledRenderGraph {
        let black = WPEClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard msaaSamples > 1 else {
            let backbuffer = WPETextureView("backbuffer")
            let prefix = [
                WPERenderOperation(pass: "objects", .setTargets(color: [backbuffer], depth: nil)),
                WPERenderOperation(pass: "objects", .clearColor(backbuffer, black)),
            ]
            return try WPERenderGraphCompiler.compile(resources: frame.resources,
                                                      operations: prefix + frame.operations)
        }
        let scene: WPEResourceID = "_rt_FullFrameBufferMultiSampled"
        let sceneResource = WPELogicalResource(id: scene, width: 3840, height: 2160, format: "rgba8unorm",
                                               sampleCount: msaaSamples, lifetime: .frameTransient)
        let prefix = [
            WPERenderOperation(pass: "objects", .setTargets(color: [WPETextureView(scene)], depth: nil)),
            WPERenderOperation(pass: "objects", .clearColor(WPETextureView(scene), black)),
            WPERenderOperation(pass: "objects.resolve", .resolve(source: scene, destination: "backbuffer")),
        ]
        return try WPERenderGraphCompiler.compile(resources: frame.resources + [sceneResource],
                                                  operations: prefix + frame.operations)
    }

    private func verifyCompilation(_ frame: WPEParityPostProcessFrame, msaaSamples: Int = 1) throws {
        let graph = try compile(frame, msaaSamples: msaaSamples)
        for resource in frame.resources where resource.lifetime == .persistent {
            #expect(graph.storage[resource.id] == .dedicated)
        }
        for resource in frame.resources where resource.lifetime == .frameTransient
            && resource.id != "backbufferDepth" {
            guard case .aliased = graph.storage[resource.id] else {
                Issue.record("Sampled bloom resource must use heap storage: \(resource.id)")
                continue
            }
            let first = try #require(graph.encoders.first { $0.attachment(resource.id) != nil })
            #expect(first.attachment(resource.id)?.load == .dontCare)
            #expect(first.attachment(resource.id)?.store == .store)
        }
        #expect(frame.present.backbuffer == "backbuffer")
        let operations = frame.operations.compactMap { operation -> WPEDrawOperation? in
            if case let .draw(draw) = operation.kind {
                return draw
            }
            return nil
        }
        #expect(operations.count == frame.draws.count)
        for (operation, description) in zip(operations, frame.draws) {
            #expect(operation.state == WPEDrawStateKey(description))
            #expect(operation.reads.map(\.resource) == description.reads)
            #expect(operation.readsDestination == (description.blend != .normal))
            #expect(operation.overwritesTargets == (description.blend == .normal))
            #expect(!operation.depthTest && !operation.depthWrite)
            #expect(description.geometry == .fullScreenQuad)
        }
    }

    private func sequence(_ frame: WPEParityPostProcessFrame) -> [String] {
        var drawIndex = 0
        return frame.operations.map { operation in
            switch operation.kind {
            case let .setTargets(colors, depth):
                return "bind \(colors.map(\.resource.rawValue).joined(separator: ",")) depth=\(depth?.resource.rawValue ?? "none")"
            case .draw:
                let draw = frame.draws[drawIndex]
                drawIndex += 1
                return "draw \(draw.shader) [\(draw.reads.map(\.rawValue).joined(separator: ","))] \(draw.blend)"
            case let .copy(source, destination): return "copy \(source) -> \(destination)"
            case let .generateMips(id): return "mips \(id)"
            case let .resolve(source, destination): return "resolve \(source) -> \(destination)"
            case .clearColor, .clearDepth: return "unexpected clear"
            }
        } + ["present \(frame.present.backbuffer)"]
    }

    private var ldrSequence: [String] {
        [
            "copy backbuffer -> _rt_FullFrameBuffer",
            "bind _rt_4FrameBuffer depth=none",
            "draw downsample_quarter_bloom [_rt_FullFrameBuffer] normal",
            "bind _rt_8FrameBuffer depth=none",
            "draw downsample_eighth_blur_v [_rt_4FrameBuffer] normal",
            "bind _rt_Bloom depth=none",
            "draw blur_h_bloom [_rt_8FrameBuffer] normal",
            "bind backbuffer depth=backbufferDepth",
            "draw combine [_rt_FullFrameBuffer,_rt_Bloom] normal",
        ]
    }

    private var hdrSequence: [String] {
        [
            "copy backbuffer -> _rt_FullFrameBuffer",
            "bind _rt_2FrameBuffer depth=none",
            "draw hdr_downsample_bloom [_rt_FullFrameBuffer] normal",
            "bind _rt_4FrameBuffer depth=none",
            "draw hdr_downsample [_rt_2FrameBuffer] normal",
            "bind _rt_8FrameBuffer depth=none",
            "draw hdr_downsample [_rt_4FrameBuffer] normal",
            "bind _rt_16FrameBuffer depth=none",
            "draw hdr_downsample [_rt_8FrameBuffer] normal",
            "bind _rt_32FrameBuffer depth=none",
            "draw hdr_downsample [_rt_16FrameBuffer] normal",
            "bind _rt_64FrameBuffer depth=none",
            "draw hdr_downsample [_rt_32FrameBuffer] normal",
            "bind _rt_128FrameBuffer depth=none",
            "draw hdr_downsample [_rt_64FrameBuffer] normal",
            "bind _rt_256FrameBuffer depth=none",
            "draw hdr_downsample [_rt_128FrameBuffer] normal",
            "bind _rt_128FrameBuffer depth=none",
            "draw hdr_upsample [_rt_256FrameBuffer] additive",
            "bind _rt_64FrameBuffer depth=none",
            "draw hdr_upsample [_rt_128FrameBuffer] additive",
            "bind _rt_32FrameBuffer depth=none",
            "draw hdr_upsample [_rt_64FrameBuffer] additive",
            "bind _rt_16FrameBuffer depth=none",
            "draw hdr_upsample [_rt_32FrameBuffer] additive",
            "bind _rt_8FrameBuffer depth=none",
            "draw hdr_upsample [_rt_16FrameBuffer] additive",
            "bind _rt_4FrameBuffer depth=none",
            "draw hdr_upsample_cubic [_rt_8FrameBuffer] additive",
            "bind _rt_2FrameBuffer depth=none",
            "draw hdr_upsample_cubic [_rt_4FrameBuffer] additive",
            "bind backbuffer depth=backbufferDepth",
            "draw combine_hdr [_rt_FullFrameBuffer,_rt_2FrameBuffer] normal",
        ]
    }
}
