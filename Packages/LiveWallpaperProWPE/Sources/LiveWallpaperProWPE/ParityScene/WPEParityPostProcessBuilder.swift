public enum WPEParityPostProcessBuilder {
    /// Starts after `WPEParitySceneFrameBuilder`, which leaves the scene targets bound and, with MSAA, has already
    /// resolved the multisampled scene into the backbuffer while the multisampled target stays bound.
    public static func build(_ config: WPEParityPostProcessConfig) -> WPEParityPostProcessFrame {
        precondition(config.backbufferWidth > 0 && config.backbufferHeight > 0 && config.msaaSampleCount > 0)
        var stream = WPEParityPostProcessStream(config: config)
        if config.bloomEnabled {
            stream.snapshot()
        }
        if config.mipMappedFrameBufferRequested {
            stream.resource("_rt_MipMappedFrameBuffer", mips: stream.mipCount, lifetime: .persistent)
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
            stream.draw(config.hdrEnabled ? "combine_hdr" : "combine",
                        reads: ["_rt_FullFrameBuffer", config.hdrEnabled ? "_rt_2FrameBuffer" : "_rt_Bloom"],
                        bloom: true, outputAlpha: config.hdrEnabled ? nil : 1)
        } else {
            if config.hdrEnabled {
                stream.snapshot()
            }
            if config.msaaSampleCount > 1,
               config.hdrEnabled || config.colorCorrectionEnabled || config.fadeActive {
                stream.bindScene()
            }
            if config.hdrEnabled {
                stream.draw("combine_srgb", reads: ["_rt_FullFrameBuffer"])
            }
        }
        if config.colorCorrectionEnabled {
            stream.snapshot()
            stream.draw("ccsimple", reads: ["_rt_FullFrameBuffer"])
        }
        if config.fadeActive {
            stream.draw("fade", blend: .translucent)
        }
        return WPEParityPostProcessFrame(resources: stream.resources, operations: stream.operations,
                                         draws: stream.draws, present: .init(backbuffer: "backbuffer"))
    }
}

private struct WPEParityPostProcessStream {
    let config: WPEParityPostProcessConfig
    var resources: [WPELogicalResource]
    var operations: [WPERenderOperation] = []
    var draws: [WPEParityPostProcessDraw] = []

    init(config: WPEParityPostProcessConfig) {
        self.config = config
        resources = [
            WPELogicalResource(id: "backbuffer", width: config.backbufferWidth, height: config.backbufferHeight,
                               format: config.backbufferFormat, lifetime: .output),
            WPELogicalResource(id: "backbufferDepth", width: config.backbufferWidth, height: config.backbufferHeight,
                               format: "depth32float", lifetime: .persistent),
        ]
    }

    var mipCount: Int {
        var size = max(config.backbufferWidth, config.backbufferHeight)
        var count = 1
        while size > 1 {
            size /= 2
            count += 1
        }
        return count
    }

    mutating func resource(_ id: WPEResourceID, divisor: Int = 1, format: String? = nil,
                           mips: Int = 1, samples: Int = 1, lifetime: WPEResourceLifetime = .frameTransient) {
        guard !resources.contains(where: { $0.id == id }) else { return }
        resources.append(WPELogicalResource(id: id, width: max(1, config.backbufferWidth / divisor),
                                            height: max(1, config.backbufferHeight / divisor),
                                            format: format ?? config.backbufferFormat, mipCount: mips,
                                            sampleCount: samples, lifetime: lifetime))
    }

    mutating func append(_ pass: String, _ kind: WPERenderOperation.Kind) {
        operations.append(WPERenderOperation(pass: WPEPassIdentity(pass), kind))
    }

    mutating func snapshot() {
        resource("_rt_FullFrameBuffer", lifetime: .persistent)
        append("snapshot", .copy(source: "backbuffer", destination: "_rt_FullFrameBuffer"))
    }

    mutating func bind(_ id: WPEResourceID) {
        append("bind:\(id)", .setTargets(color: [WPETextureView(id, mips: 0 ..< 1)], depth: nil))
    }

    mutating func bindScene() {
        append("bind:backbuffer", .setTargets(color: [WPETextureView("backbuffer")],
                                              depth: WPETextureView("backbufferDepth")))
    }

    mutating func draw(_ shader: String, reads: [WPEResourceID] = [],
                       blend: WPEParityPostProcessDraw.Blend = .normal, bloom: Bool = false,
                       outputAlpha: Float? = nil) {
        let texels = reads.map { id in
            let resource = resources.first { $0.id == id }!
            return SIMD2<Float>(1 / Float(resource.width), 1 / Float(resource.height))
        }
        let description = WPEParityPostProcessDraw(shader: shader, reads: reads, blend: blend,
                                                   geometry: .fullScreenQuad,
                                                   bloomParameters: bloom ? config.bloomParameters : [:],
                                                   texelSizes: texels, outputAlpha: outputAlpha)
        draws.append(description)
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
        draw("downsample_quarter_bloom", reads: ["_rt_FullFrameBuffer"], bloom: true)
        bind("_rt_8FrameBuffer")
        draw("downsample_eighth_blur_v", reads: ["_rt_4FrameBuffer"], bloom: true)
        bind("_rt_Bloom")
        draw("blur_h_bloom", reads: ["_rt_8FrameBuffer"], bloom: true)
    }

    mutating func hdrBloom() {
        let divisors = [2, 4, 8, 16, 32, 64, 128, 256]
        for divisor in divisors {
            resource(pyramid(divisor), divisor: divisor, format: "rgba16float")
            bind(pyramid(divisor))
            draw(divisor == 2 ? "hdr_downsample_bloom" : "hdr_downsample",
                 reads: [divisor == 2 ? "_rt_FullFrameBuffer" : pyramid(divisor / 2)], bloom: true)
        }
        for divisor in divisors.dropLast().reversed() {
            bind(pyramid(divisor))
            draw(divisor <= 4 ? "hdr_upsample_cubic" : "hdr_upsample",
                 reads: [pyramid(divisor * 2)], blend: .additive, bloom: true)
        }
    }

    func pyramid(_ divisor: Int) -> WPEResourceID {
        WPEResourceID("_rt_\(divisor)FrameBuffer")
    }
}
