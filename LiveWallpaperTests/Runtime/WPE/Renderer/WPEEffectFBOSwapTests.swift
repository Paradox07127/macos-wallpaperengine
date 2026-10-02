#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE effect swap command")
struct WPEEffectFBOSwapTests {
    private struct Fixture {
        let root: URL
        let graph: WPERenderGraph
        let pipeline: WPEPreparedRenderPipeline

        func name(endingWith suffix: String) throws -> String {
            try #require(graph.layers.first?.localFBOs.first { $0.name.hasSuffix(suffix) }?.name)
        }
    }

    /// Step pass: B = mix(A, red, 0.5). Show pass: composite = B. With A↔B swapped after the
    /// passes, every frame feeds the previous B back in; without it A stays a fresh zero target.
    private static func makeFixture(swap: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WPEEffectFBOSwapTests-\(UUID().uuidString)")
        func write(_ name: String, _ value: Any) throws {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let text = value as? String {
                try Data(text.utf8).write(to: url)
            } else {
                try JSONSerialization.data(withJSONObject: value).write(to: url)
            }
        }
        let vertex = """
        attribute vec3 a_Position;
        attribute vec2 a_TexCoord;
        varying vec2 v_TexCoord;
        void main() { gl_Position = vec4(a_Position, 1.0); v_TexCoord = a_TexCoord; }
        """
        try write("models/image.json", ["material": "materials/image.json"])
        try write("materials/image.json", ["passes": [["shader": "genericimage2", "textures": ["source"]]]])
        for shader in ["swapstep", "swapshow"] {
            try write("materials/\(shader).json", ["passes": [["shader": "effects/\(shader)", "blending": "normal",
                                                               "depthtest": "disabled", "depthwrite": "disabled", "cullmode": "nocull"]]])
            try write("shaders/effects/\(shader).vert", vertex)
        }
        try write("shaders/effects/swapstep.frag", """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(mix(texture2D(g_Texture0, v_TexCoord).rgb, vec3(1.0, 0.0, 0.0), 0.5), 1.0); }
        """)
        try write("shaders/effects/swapshow.frag", """
        uniform sampler2D g_Texture0;
        varying vec2 v_TexCoord;
        void main() { gl_FragColor = vec4(texture2D(g_Texture0, v_TexCoord).rgb, 1.0); }
        """)
        var passes: [[String: Any]] = [
            ["material": "materials/swapstep.json", "target": "_rt_B", "bind": [["name": "_rt_A", "index": 0]]],
            ["material": "materials/swapshow.json", "bind": [["name": "_rt_B", "index": 0]]],
        ]
        if swap {
            passes.append(["command": "swap", "source": "_rt_A", "target": "_rt_B"])
        }
        try write("effects/swap/effect.json", [
            "fbos": ["_rt_A", "_rt_B"].map { ["name": $0, "scale": 1, "format": "rgba8888", "clear": "0 0 0 0", "unique": true] },
            "passes": passes,
        ])
        let scene = try JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 0"], "general": ["orthogonalprojection": ["width": 8, "height": 8]],
            "objects": [["id": "fluid", "image": "models/image.json", "origin": "4 4 0", "size": "8 8",
                         "effects": [["file": "effects/swap/effect.json"]]]],
        ])
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: WPESceneDocumentParser.parse(data: scene))
        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: root).build(graph: graph)
        return Fixture(root: root, graph: graph, pipeline: pipeline)
    }

    private static func placeholderTextures(for pipeline: WPEPreparedRenderPipeline, device: MTLDevice) throws -> [String: MTLTexture] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        [UInt8](repeating: 0, count: 4).withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 4)
        }
        var textures: [String: MTLTexture] = [:]
        for pass in pipeline.layers.flatMap(\.passes) {
            for reference in [pass.pass.source] + Array(pass.textureBindings.values) {
                switch reference {
                case let .image(name), let .asset(name): textures[name] = texture
                case .fbo, .previous: break
                }
            }
        }
        return textures
    }

    private static func centerPixel(_ texture: MTLTexture, device: MTLDevice) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width,
                                                                  height: texture.height, mipmapped: false)
        descriptor.storageMode = .shared
        let staging = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(),
                  sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        var pixel = [UInt8](repeating: 0, count: 4)
        staging.getBytes(&pixel, bytesPerRow: 4 * texture.width,
                         from: MTLRegionMake2D(texture.width / 2, texture.height / 2, 1, 1), mipmapLevel: 0)
        return pixel
    }

    @Test("swap builds without a command pass and records the pair on the effect's unique FBOs")
    func swapIsNotAPass() throws {
        let fixture = try Self.makeFixture(swap: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let layer = try #require(fixture.graph.layers.first)
        #expect(!layer.passes.contains { $0.shader.hasPrefix("commands/") })
        let a = try fixture.name(endingWith: "_rt_A")
        let b = try fixture.name(endingWith: "_rt_B")
        #expect(a.hasPrefix("_rt_unique_") && b.hasPrefix("_rt_unique_"))
        #expect(layer.localFBOs.first { $0.name == a }?.swapPartner == b)
        #expect(layer.localFBOs.first { $0.name == b }?.swapPartner == a)
    }

    @Test("Frame N's write to B is frame N+1's A: bindings exchange without a copy", arguments: [true, false])
    func swapFeedsTheNextFrame(swap: Bool) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try Self.makeFixture(swap: swap)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let executor = try WPEMetalRenderExecutor(device: device)
        let size = CGSize(width: 8, height: 8)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 8, height: 8, auto: true), sceneCamera: .defaultCamera)
        let textures = try Self.placeholderTextures(for: fixture.pipeline, device: device)
        let graphLayer = try #require(fixture.graph.layers.first)
        let a = try fixture.name(endingWith: "_rt_A")
        let b = try fixture.name(endingWith: "_rt_B")

        let intervals = executor.fboAliasIntervals(pipeline: fixture.pipeline, sceneSize: size)
        // Control: an ordinary write-before-read unique target keeps its alias-heap lifetime.
        #expect(intervals.contains { $0.key.name == b } == !swap)

        var previousBindings: (a: MTLTexture, b: MTLTexture)?
        for frame in 1 ... 3 {
            let output = try executor.render(pipeline: fixture.pipeline, size: size, textures: textures, cameraUniforms: camera)
            let red = try Int(Self.centerPixel(output, device: device)[0])
            let expected = swap ? (1 - pow(0.5, Double(frame))) * 255 : 127.5
            #expect(abs(Double(red) - expected) <= 2.5, "frame \(frame): red \(red), expected \(expected)")
            let names = Set(executor.previousFrameHistory.map { Array($0.namedTextures.keys) } ?? [])
            #expect(!names.contains(a) && !names.contains(b))
            #expect(executor.privateHistoryCandidates[a] == nil && executor.privateHistoryCandidates[b] == nil)
            guard swap, frame >= 2 else { continue }
            let bindings = try (
                a: executor.targetPool.texture(for: .fbo(name: a), layer: graphLayer, sceneSize: size, avoiding: nil),
                b: executor.targetPool.texture(for: .fbo(name: b), layer: graphLayer, sceneSize: size, avoiding: nil)
            )
            if let previousBindings {
                #expect(bindings.a === previousBindings.b && bindings.b === previousBindings.a)
            }
            previousBindings = bindings
        }
    }

    /// The sandboxed test host's NSHomeDirectory() is its container; the Steam install lives under the real home.
    private static let previewRoot = URL(fileURLWithPath: String(cString: getpwuid(getuid()).pointee.pw_dir))
        .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets/effects/fluidsimulation/preview")

    @Test("Official fluidsimulation preview builds and renders two frames",
          .enabled(if: FileManager.default.fileExists(atPath: previewRoot.appendingPathComponent("scene.json").path)))
    func officialFluidPreviewRenders() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let root = Self.previewRoot
        let engine = root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try WPESceneDocumentParser.parse(data: Data(contentsOf: root.appendingPathComponent("scene.json")))
        let graph = try WPERenderGraphBuilder(cacheRootURL: root, engineAssetsRootURL: engine).build(document: document)
        #expect(!graph.layers.flatMap(\.passes).contains { $0.shader == "commands/swap" })
        #expect(graph.layers.flatMap(\.localFBOs).filter { $0.swapPartner != nil }.count == 4)
        let pipeline = try WPERenderPipelineBuilder(cacheRootURL: root, engineAssetsRootURL: engine).build(graph: graph)
        let executor = try WPEMetalRenderExecutor(device: device)
        let textures = try Self.placeholderTextures(for: pipeline, device: device)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 256, height: 256, auto: true), sceneCamera: .defaultCamera)
        for _ in 0 ..< 2 {
            _ = try executor.render(pipeline: pipeline, size: CGSize(width: 256, height: 256), textures: textures, cameraUniforms: camera)
        }
        #expect(executor.untranslatableShaderReasonByPassID.isEmpty)
    }
}
#endif
