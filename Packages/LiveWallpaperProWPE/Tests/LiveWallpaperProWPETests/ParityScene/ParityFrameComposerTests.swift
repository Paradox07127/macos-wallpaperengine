@testable import LiveWallpaperProWPE
import Testing

struct ParityFrameComposerTests {
    @Test func oneLayerWithLDRBloomMatchesListB() throws {
        var post = bloomConfig()
        post.sceneMipMappedFrameBufferEnabled = true
        post.qualityMipMappedFrameBufferEnabled = true
        post.colorCorrectionEnabled = true
        post.fadeActive = true
        let frame = try WPEParityFrameComposer.compose(scene: ParitySceneFixtures.scene([ParitySceneFixtures.layer()]),
                                                       post: post)
        #expect(lines(frame) == [
            "bind backbuffer|backbufferDepth",
            "clear backbuffer 0.1,0.2,0.3,1.0",
            "clearDepth backbufferDepth 0.0",
            "bind backbuffer|backbufferDepth",
            "draw genericimage2 [L/image] translucent",
            "copy backbuffer->_rt_FullFrameBuffer",
            "copy backbuffer->_rt_MipMappedFrameBuffer",
            "mips _rt_MipMappedFrameBuffer",
            "bind _rt_4FrameBuffer",
            "draw downsample_quarter_bloom [_rt_FullFrameBuffer] normal",
            "bind _rt_8FrameBuffer",
            "draw downsample_eighth_blur_v [_rt_4FrameBuffer] normal",
            "bind _rt_Bloom",
            "draw blur_h_bloom [_rt_8FrameBuffer] normal",
            "bind backbuffer|backbufferDepth",
            "draw combine [_rt_FullFrameBuffer,_rt_Bloom] normal",
            "copy backbuffer->_rt_FullFrameBuffer",
            "draw ccsimple [_rt_FullFrameBuffer] normal",
            "draw fade [] translucent",
        ])
        let drawCount = frame.operations.count {
            if case .draw = $0.kind {
                true
            } else {
                false
            }
        }
        #expect(frame.draws.count == drawCount)
    }

    @Test func conflictingResourceNamesTheID() {
        let scene = WPEParitySceneFrameBuilder.build(ParitySceneFixtures.scene([ParitySceneFixtures.layer()]))
        let post = WPEParityPostProcessBuilder.build(bloomConfig())
        let transientDepth = post.resources.map { resource in
            resource.id != "backbufferDepth" ? resource : WPELogicalResource(
                id: resource.id, width: resource.width, height: resource.height, format: resource.format,
                lifetime: .frameTransient
            )
        }
        let conflicting = WPEParityPostProcessFrame(resources: transientDepth, operations: post.operations,
                                                    draws: post.draws, present: post.present)
        #expect(throws: WPEParityFrameCompositionError.conflictingResource("backbufferDepth")) {
            try WPEParityFrameComposer.merge(scene, conflicting)
        }
    }

    @Test func mismatchedBackbufferAndSamplesThrow() {
        let scene = ParitySceneFixtures.scene([ParitySceneFixtures.layer()])
        #expect(throws: WPEParityFrameCompositionError.backbufferMismatch(scene: "1920x1080 rgba8unorm",
                                                                          post: "1280x720 rgba8unorm")) {
            try WPEParityFrameComposer.compose(
                scene: scene, post: WPEParityPostProcessConfig(backbufferWidth: 1280, backbufferHeight: 720)
            )
        }
        #expect(throws: WPEParityFrameCompositionError.backbufferMismatch(scene: "1920x1080 rgba8unorm",
                                                                          post: "1920x1080 rgba16float")) {
            try WPEParityFrameComposer.compose(scene: scene, post: WPEParityPostProcessConfig(
                backbufferWidth: 1920, backbufferHeight: 1080, backbufferFormat: "rgba16float"
            ))
        }
        #expect(throws: WPEParityFrameCompositionError.sampleCountMismatch(scene: 1, post: 4)) {
            try WPEParityFrameComposer.compose(scene: scene, post: WPEParityPostProcessConfig(
                msaaSampleCount: 4, backbufferWidth: 1920, backbufferHeight: 1080
            ))
        }
    }

    @Test(arguments: ["none", "ldr", "hdr", "msaa", "mipmapped"])
    func composedFrameCompiles(_ variant: String) throws {
        var post = variant == "none" || variant == "mipmapped"
            ? WPEParityPostProcessConfig(backbufferWidth: 1920, backbufferHeight: 1080) : bloomConfig()
        post.hdrEnabled = variant == "hdr"
        post.sceneMipMappedFrameBufferEnabled = variant == "mipmapped"
        post.qualityMipMappedFrameBufferEnabled = variant == "mipmapped"
        if variant == "msaa" {
            post.msaaSampleCount = 4
            post.colorCorrectionEnabled = true
            post.fadeActive = true
        }
        let layers = [
            ParitySceneFixtures.layer("A", effects: [ParitySceneFixtures.effect("E1"),
                                                     ParitySceneFixtures.effect("E2", readsFullFrameBuffer: true)]),
            ParitySceneFixtures.layer("B", colorBlendMode: 2),
        ]
        let frame = try WPEParityFrameComposer.compose(
            scene: ParitySceneFixtures.scene(layers, msaaSamples: post.msaaSampleCount), post: post
        )
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        for resource in frame.resources where resource.lifetime == .persistent {
            #expect(graph.storage[resource.id] == .dedicated, "\(resource.id)")
        }
        #expect(graph.storage["backbufferDepth"] == .dedicated)
    }

    @Test func hdrBackbufferFormatReachesTheSceneTargets() throws {
        var scene = ParitySceneFixtures.scene([ParitySceneFixtures.layer()], msaaSamples: 4)
        scene.backbufferFormat = "rgba16float"
        var post = bloomConfig()
        post.hdrEnabled = true
        post.msaaSampleCount = 4
        post.backbufferFormat = "rgba16float"
        let frame = try WPEParityFrameComposer.compose(scene: scene, post: post)
        let formats = Dictionary(uniqueKeysWithValues: frame.resources.map { ($0.id, $0.format) })
        #expect(formats["backbuffer"] == "rgba16float")
        #expect(formats["_rt_FullFrameBuffer"] == "rgba16float")
        #expect(formats["_rt_FullFrameBufferMultiSampled"] == "rgba16float")
        _ = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
    }

    @Test func memoryReportFor4KFrame() throws {
        let (width, height) = (3840, 2160)
        let twoPass = WPEParitySceneEffect(id: "E", passes: [WPEParityScenePass(shader: "e0", compose: true),
                                                             WPEParityScenePass(shader: "e1")])
        let scene = WPEParitySceneDescription(width: width, height: height, objects: [
            WPEParitySceneObject(id: "A", width: width, height: height),
            WPEParitySceneObject(id: "B", width: width, height: height, effects: [twoPass]),
        ])
        let post = WPEParityPostProcessConfig(sceneBloomEnabled: true, userBloomEnabled: true,
                                              objectTableNonEmpty: true, colorCorrectionEnabled: true,
                                              backbufferWidth: width, backbufferHeight: height)
        let frame = try WPEParityFrameComposer.compose(scene: scene, post: post)
        let graph = try WPERenderGraphCompiler.compile(resources: frame.resources, operations: frame.operations)
        let layout = graph.heapLayout { (size: bytes($0), alignment: 65536) }
        let members = graph.allocationGroups.joined().compactMap { graph.resources[$0] }
        let memberBytes = members.reduce(0) { $0 + bytes($1) }
        let dedicated = graph.storage.values.count { $0 == .dedicated }
        print("[frame-memory] heapBytes=\(layout.size) memberBytes=\(memberBytes) heapMembers=\(members.count) "
            + "dedicatedResources=\(dedicated)")
        #expect(layout.size < memberBytes)
    }

    // MARK: Helpers

    private func bloomConfig() -> WPEParityPostProcessConfig {
        WPEParityPostProcessConfig(sceneBloomEnabled: true, userBloomEnabled: true, objectTableNonEmpty: true,
                                   backbufferWidth: 1920, backbufferHeight: 1080)
    }

    /// Width × height × bytes per pixel × samples, summed over the mip chain.
    private func bytes(_ resource: WPELogicalResource) -> Int {
        let pixel = resource.format == "rgba16float" ? 8 : 4
        return (0 ..< resource.mipCount).reduce(0) { total, level in
            total + max(1, resource.width >> level) * max(1, resource.height >> level) * pixel * resource.sampleCount
        }
    }

    private func lines(_ frame: WPEParityFrame) -> [String] {
        frame.operations.enumerated().map { index, operation in
            switch operation.kind {
            case let .setTargets(color, depth):
                "bind " + (color.map(\.resource.rawValue) + [depth?.resource.rawValue].compactMap(\.self))
                    .joined(separator: "|")
            case let .clearColor(view, color):
                "clear \(view.resource) \(color.red),\(color.green),\(color.blue),\(color.alpha)"
            case let .clearDepth(view, depth):
                "clearDepth \(view.resource) \(depth)"
            case .draw:
                describe(frame.draws[index])
            case let .copy(source, destination):
                "copy \(source)->\(destination)"
            case let .generateMips(id):
                "mips \(id)"
            case let .resolve(source, destination):
                "resolve \(source)->\(destination)"
            }
        }
    }

    private func describe(_ draw: WPEParityFrameDraw?) -> String {
        let (shader, reads, blend): (String, [WPEResourceID], String) = switch draw {
        case let .scene(draw): (draw.shader, draw.reads, draw.blend.rawValue)
        case let .post(draw): (draw.shader, draw.reads, "\(draw.blend)")
        case nil: ("<missing description>", [], "")
        }
        return "draw \(shader) [\(reads.map(\.rawValue).joined(separator: ","))] \(blend)"
    }
}
