import Foundation

public enum WPEParityPostProcessBuilder {
    /// Starts after `WPEParitySceneFrameBuilder`, which leaves the scene targets bound and, with MSAA, has already
    /// resolved the multisampled scene into the backbuffer while the multisampled target stays bound.
    public static func build(_ config: WPEParityPostProcessConfig) -> WPEParityPostProcessFrame {
        precondition(config.backbufferWidth > 0 && config.backbufferHeight > 0 && config.msaaSampleCount > 0)
        var stream = WPEParityPostProcessStream(config: config)
        if config.bloomEnabled {
            stream.snapshot()
        }
        if config.sceneMipMappedFrameBufferEnabled {
            stream.resource("_rt_MipMappedFrameBuffer", mips: stream.mipCount, lifetime: .pooled)
        }
        if config.mipMappedFrameBufferRefreshEnabled {
            stream.append("mipCopy", .copy(source: "backbuffer", destination: "_rt_MipMappedFrameBuffer"))
            stream.append("generateMips", .generateMips("_rt_MipMappedFrameBuffer"))
        }
        if config.bloomEnabled {
            if config.hdrEnabled {
                stream.hdrBloom()
            } else {
                stream.ldrBloom()
            }
            stream.bindScene()
            // Main+0x3150 (14017fa70.c:152-175)
            if config.hdrEnabled {
                let upsample = config.displayHDREnabled ? "combine_dhdr_upsample" : "combine_hdr_upsample"
                // 14017fa70.c:728-731: zw keep the last pyramid pass's values.
                let scale = stream.displayLuminanceScale
                stream.draw("combine_hdr", material: "materials/util/\(upsample).json",
                            reads: ["_rt_FullFrameBuffer", "_rt_2FrameBuffer"],
                            constants: ["g_RenderVar0": [scale.x, scale.y, stream.renderVar0[2], stream.renderVar0[3]]])
            } else {
                stream.draw("combine", material: "materials/util/combine_ldr.json",
                            reads: ["_rt_FullFrameBuffer", "_rt_Bloom"])
            }
        } else {
            if config.hdrEnabled {
                stream.snapshot()
            }
            if config.msaaSampleCount > 1,
               config.hdrEnabled || config.colorCorrectionEnabled || config.fadeActive {
                stream.bindScene()
            }
            if config.hdrEnabled {
                // Main+0x3158; shader passthroughsrgb.
                stream.draw("combine_srgb", reads: ["_rt_FullFrameBuffer"])
            }
        }
        if config.colorCorrectionEnabled {
            stream.snapshot()
            let correction = config.colorCorrection
            var constants: [String: [Float]] = [:]
            var combos: [String: Int32] = [:]
            var textures: [Int32: String] = [:]
            // 140181f30.c:265-275, 409-413, 499-512
            if correction.adjustsColor {
                combos["COL"] = 1
                constants["g_Params"] = correction.params
            }
            if correction.appliesLUT {
                combos["LUT"] = 1
                constants["g_LutParams"] = [correction.lutAmount]
                textures[1] = "lut/" + correction.lut
            }
            stream.draw("ccsimple", reads: ["_rt_FullFrameBuffer"], constants: constants, combos: combos,
                        textures: textures)
        }
        if config.fadeActive {
            stream.draw("fade", blend: .translucent)
        }
        return WPEParityPostProcessFrame(resources: stream.resources, operations: stream.operations, draws: stream.draws)
    }
}

private struct WPEParityPostProcessStream {
    let config: WPEParityPostProcessConfig
    var resources: [WPELogicalResource]
    var operations: [WPERenderOperation] = []
    var draws: [WPEParityPostProcessDraw] = []
    /// Main+0xb8, the engine's g_RenderVar0, as the last HDR pass left it.
    var renderVar0: [Float] = [0, 0, 0, 0]

    init(config: WPEParityPostProcessConfig) {
        self.config = config
        resources = [
            WPELogicalResource(id: "backbuffer", width: config.backbufferWidth, height: config.backbufferHeight,
                               format: config.backbufferFormat, lifetime: .output),
            WPELogicalResource(id: "backbufferDepth", width: config.backbufferWidth, height: config.backbufferHeight,
                               format: "depth32float", lifetime: .pooled),
        ]
    }

    /// Native rtFlags0x10 count includes level0: min(ceilLog2(width), ceilLog2(height)) minus3, clamped1
    /// (1400d2c60/1400d3500). Metal's valid one-pixel edge also has exactly one level.
    var mipCount: Int {
        let edge = min(config.backbufferWidth, config.backbufferHeight)
        let ceiling = Int.bitWidth - (edge - 1).leadingZeroBitCount
        return max(1, ceiling - 3)
    }

    mutating func resource(_ id: WPEResourceID, divisor: Int = 1, format: String? = nil,
                           mips: Int = 1, samples: Int = 1, lifetime: WPEResourceLifetime = .frameTransient) {
        guard !resources.contains(where: { $0.id == id }) else { return }
        // Native d2c60 and resize 161f40 clamp each divided RT extent to two. Keep the exact extent of
        // full-size snapshots: a one-pixel Metal canvas is a Mac policy and its copies must still match.
        let minimum = divisor == 1 ? 1 : 2
        resources.append(WPELogicalResource(id: id, width: max(minimum, config.backbufferWidth / divisor),
                                            height: max(minimum, config.backbufferHeight / divisor),
                                            format: format ?? config.backbufferFormat, mipCount: mips,
                                            sampleCount: samples, lifetime: lifetime))
    }

    mutating func append(_ pass: String, _ kind: WPERenderOperation.Kind) {
        operations.append(WPERenderOperation(pass: WPEPassIdentity(pass), kind))
    }

    mutating func snapshot() {
        resource("_rt_FullFrameBuffer", lifetime: .pooled)
        append("snapshot", .copy(source: "backbuffer", destination: "_rt_FullFrameBuffer"))
    }

    mutating func bind(_ id: WPEResourceID) {
        append("bind:\(id)", .setTargets(color: [WPETextureView(id, mips: 0 ..< 1)], depth: nil))
    }

    mutating func bindScene() {
        append("bind:backbuffer", .setTargets(color: [WPETextureView("backbuffer")],
                                              depth: WPETextureView("backbufferDepth")))
    }

    /// `material` defaults to `materials/util/<shader>.json`.
    mutating func draw(_ shader: String, material: String? = nil, reads: [WPEResourceID] = [],
                       blend: WPEParityPostProcessDraw.Blend = .normal, constants: [String: [Float]] = [:],
                       combos: [String: Int32] = [:], textures: [Int32: String] = [:]) {
        let texels = reads.map { id in
            let resource = resources.first { $0.id == id }!
            return SIMD2<Float>(1 / Float(resource.width), 1 / Float(resource.height))
        }
        let description = WPEParityPostProcessDraw(shader: shader,
                                                   material: material ?? "materials/util/\(shader).json",
                                                   reads: reads, blend: blend, constants: constants,
                                                   texelSizes: texels, combos: combos, textures: textures)
        draws.append(description)
        renderVar0 = constants["g_RenderVar0"] ?? renderVar0
        append(shader, .draw(WPEDrawOperation(reads: reads.map { WPETextureView($0) },
                                              readsDestination: blend != .normal, overwritesTargets: blend == .normal,
                                              state: WPEDrawStateKey(description))))
    }

    // FUN_140183610: the three LDR passes precede combine.
    mutating func ldrBloom() {
        resource("_rt_4FrameBuffer", divisor: 4, format: "rgba8unorm")
        resource("_rt_8FrameBuffer", divisor: 8, format: "rgba8unorm")
        resource("_rt_Bloom", divisor: 8, format: "rgba8unorm")
        bind("_rt_4FrameBuffer")
        // 14017f1b0.c:316-330
        let bloom = config.bloomSettings
        draw("downsample_quarter_bloom", reads: ["_rt_FullFrameBuffer"],
             constants: ["g_BloomStrength": [bloom.strength], "g_BloomThreshold": [bloom.threshold],
                         "g_BloomTint": tint])
        bind("_rt_8FrameBuffer")
        draw("downsample_eighth_blur_v", reads: ["_rt_4FrameBuffer"])
        bind("_rt_Bloom")
        draw("blur_h_bloom", reads: ["_rt_8FrameBuffer"])
    }

    /// FUN_140183610: N − 1 downsamples below the bloom pass, then upsamples back to `_rt_2FrameBuffer`.
    mutating func hdrBloom() {
        let bloom = config.bloomSettings
        let levels = config.hdrBloomLevelCount
        let (threshold, feather) = (bloom.hdrThreshold, bloom.hdrFeather)
        // 0x14017f847-0x14017f89b
        let strength = bloom.hdrStrength / (pow(bloom.hdrScatter, Float(max(levels, 2) - 2)) + 1)
        // Native capacity survives active-N changes. The renderer prepares these named pool targets once.
        for level in 1 ... config.hdrBloomCapacity {
            let divisor = 1 << level
            resource(pyramid(divisor), divisor: divisor, format: "rgba16float", lifetime: .pooled)
        }
        bind(pyramid(2))
        // 14017f1b0.c:364-371
        draw("hdr_downsample_bloom", reads: ["_rt_FullFrameBuffer"], constants: [
            "g_BloomStrength": [strength],
            "g_BloomBlendParams": [threshold, threshold - threshold * feather, 2 * threshold * feather,
                                   0.25 / (threshold * feather + 1e-5)],
            "g_BloomTint": tint, "g_RenderVar0": texelVariable(1),
        ])
        for level in 1 ..< levels {
            let scale = 1 << level
            bind(pyramid(scale * 2))
            draw("hdr_downsample", reads: [pyramid(scale)], constants: ["g_RenderVar0": texelVariable(scale)])
        }
        for level in stride(from: levels - 1, through: 1, by: -1) {
            let scale = 1 << level
            bind(pyramid(scale))
            draw(level >= levels - 2 ? "hdr_upsample_cubic" : "hdr_upsample", reads: [pyramid(scale * 2)],
                 blend: .additive,
                 constants: ["g_RenderVar0": texelVariable(scale), "g_BloomScatter": [bloom.hdrScatter]])
        }
    }

    /// combine_hdr's g_RenderVar0.xy. Windows sets (sdrWhite, peak − sdrWhite) / 80 nits (14012ac60.c:189-191,
    /// 545-555); the shader is linear in both, so EDR units (1 = SDR white) divide them by sdrWhite.
    var displayLuminanceScale: SIMD2<Float> {
        config.displayHDREnabled ? SIMD2(1, max(config.maximumPotentialEDR - 1, 0)) : SIMD2(1, 1)
    }

    var tint: [Float] {
        let tint = config.bloomSettings.tint
        return [tint.x, tint.y, tint.z]
    }

    /// `scale` texels of the backbuffer, as (x, y, −x, −y).
    func texelVariable(_ scale: Int) -> [Float] {
        let x = Float(scale) / Float(config.backbufferWidth)
        let y = Float(scale) / Float(config.backbufferHeight)
        return [x, y, -x, -y]
    }

    func pyramid(_ divisor: Int) -> WPEResourceID {
        WPEResourceID("_rt_\(divisor)FrameBuffer")
    }
}
