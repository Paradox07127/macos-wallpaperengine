#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("WPE unique effect histories")
struct WPEUniqueEffectHistoryTests {
    @Test("Repeated effects isolate unique targets, binds, commands and material textures")
    func graphScopesEveryReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ name: String, _ value: [String: Any]) throws {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        try write("models/image.json", ["material": "materials/image.json"])
        try write("materials/image.json", ["passes": [["shader": "genericimage2", "textures": ["source"]]]])
        try write("materials/accumulate.json", ["passes": [["shader": "effects/test", "textures": ["_rt_History"]]]])
        try write("effects/test/effect.json", [
            "fbos": [["name": "_rt_History", "scale": 1, "format": "rgba8888", "unique": true],
                     ["name": "_rt_Scratch", "scale": 1, "format": "rgba8888"]],
            "passes": [["material": "materials/accumulate.json", "target": "_rt_Scratch",
                        "bind": [["index": 1, "name": "_rt_History"]]],
                       ["command": "copy", "source": "_rt_Scratch", "target": "_rt_History"],
                       ["command": "copy", "source": "_rt_History"]],
        ])
        let effects = [["file": "effects/test/effect.json"], ["file": "effects/test/effect.json"]]
        let data = try JSONSerialization.data(withJSONObject: ["camera": ["center": "0 0 0"], "general": ["orthogonalprojection": ["width": 8, "height": 8]], "objects": [
            ["id": "one", "image": "models/image.json", "effects": effects],
            ["id": "two", "image": "models/image.json", "effects": effects],
        ]])
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: WPESceneDocumentParser.parse(data: data))
        #expect(graph.layers.count == 2)
        var names: Set<String> = []
        for layer in graph.layers {
            let histories = layer.localFBOs.filter(\.unique)
            #expect(histories.count == 2)
            for (index, fbo) in histories.enumerated() {
                #expect(names.insert(fbo.name).inserted)
                let pass = layer.passes[1 + index * 3]
                #expect(pass.textures[0] == .fbo(fbo.name))
                #expect(pass.binds[1] == .fbo(fbo.name))
                #expect(pass.target == .fbo(name: "_rt_Scratch"))
                #expect(layer.passes[2 + index * 3].target == .fbo(name: fbo.name))
                #expect(layer.passes[3 + index * 3].textures[0] == .fbo(fbo.name))
            }
        }
    }

    @Test("Unique feedback survives frames, stays outside the alias heap and resets on reload")
    func temporalFeedback() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let size = CGSize(width: 8, height: 8)
        func layer(_ id: String, color: [Double]) -> WPEPreparedRenderLayer {
            let history = "_rt_unique_" + id
            let scratch = "_rt_shared_scratch"
            func pass(_ suffix: String, source: WPETextureReference, target: WPERenderTarget, accumulate: Bool) -> WPEPreparedRenderPass {
                let graph = WPERenderPass(id: id + suffix, phase: .effect(file: "test"),
                                          shader: accumulate ? "effects/historytest" : "commands/copy", source: source, target: target,
                                          textures: [0: source], binds: accumulate ? [0: .previous] : [:], constants: ["g_Color": .vector(color)], combos: [:],
                                          blending: "premultiplied", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
                let shader = WPEShaderProgram(name: graph.shader, vertexSource: "", fragmentSource: accumulate ? """
                uniform sampler2D g_Texture0;
                uniform vec4 g_Color;
                varying vec2 v_TexCoord;
                void main() { gl_FragColor = vec4(mix(texture2D(g_Texture0, v_TexCoord).rgb, g_Color.rgb, 0.5), 0.5); }
                """ : "", isBuiltin: !accumulate)
                return WPEPreparedRenderPass(pass: graph, shader: shader, textureBindings: [0: source],
                                             comboValues: [:], uniformValues: ["g_Color": .vector(color)])
            }
            let passes = [pass(".0", source: .fbo(history), target: .fbo(name: scratch), accumulate: true),
                          pass(".1", source: .fbo(scratch), target: .fbo(name: history), accumulate: false),
                          pass(".2", source: .fbo(scratch), target: .scene, accumulate: false)]
            let geometry = WPERenderLayerGeometry(origin: SIMD3(4, 4, 0), scale: SIMD3(repeating: 1),
                                                  angles: .zero, alignment: .center, size: size, alpha: 1, color: SIMD3(repeating: 1), brightness: 1)
            let graph = WPERenderLayer(objectID: id, objectName: id, imagePath: "unused", materialPath: nil,
                                       geometry: geometry, compositeA: id + "a", compositeB: id + "b", localFBOs: [
                                           WPERenderFBO(name: history, scale: 1, format: "rgba8888", unique: true),
                                           WPERenderFBO(name: scratch, scale: 1, format: "rgba8888"),
                                       ], passes: passes.map(\.pass))
            return WPEPreparedRenderLayer(graphLayer: graph, passes: passes)
        }
        let pipeline = WPEPreparedRenderPipeline(layers: [layer("red", color: [1, 0, 0, 1]), layer("green", color: [0, 1, 0, 1])])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 8, height: 8, auto: true), sceneCamera: .defaultCamera)
        let intervals = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: size)
        #expect(!intervals.contains { $0.key.name.hasPrefix("_rt_unique_") })
        func sample(_ texture: MTLTexture) throws -> [UInt8] {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: 8, height: 8, mipmapped: false)
            d.storageMode = .shared
            let staging = try #require(device.makeTexture(descriptor: d))
            let queue = try #require(device.makeCommandQueue())
            let command = try #require(queue.makeCommandBuffer())
            let blit = try #require(command.makeBlitCommandEncoder())
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(), sourceSize: .init(width: 8, height: 8, depth: 1),
                      to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init())
            blit.endEncoding(); command.commit(); command.waitUntilCompleted()
            var pixel = [UInt8](repeating: 0, count: 4)
            staging.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(4, 4, 1, 1), mipmapLevel: 0)
            return pixel
        }
        for frame in 0 ..< 3 {
            _ = try executor.render(pipeline: pipeline, size: size, textures: [:], cameraUniforms: camera)
            let history = try #require(executor.previousFrameHistory)
            #expect(Set(history.namedTextures.keys) == ["_rt_unique_red", "_rt_unique_green"])
            for (id, channel) in [("red", 0), ("green", 1)] {
                let pixel = try sample(#require(history.namedTextures["_rt_unique_" + id]))
                #expect(abs(Int(pixel[channel]) - Int((1.055 * pow(0.5 * (1 - pow(0.5, Double(frame + 1))), 1 / 2.4) - 0.055) * 255)) <= 2)
                #expect(pixel[1 - channel] == 0)
                #expect(abs(Int(pixel[3]) - 128) <= 1)
            }
        }
        // A scene-size change must discard old history just like a scene reload.
        _ = try executor.render(pipeline: pipeline, size: CGSize(width: 9, height: 8), textures: [:], cameraUniforms: camera)
        let reset = try sample(#require(executor.previousFrameHistory?.namedTextures["_rt_unique_red"]))
        #expect(abs(Int(reset[0]) - 137) <= 2)
    }
}
#endif
