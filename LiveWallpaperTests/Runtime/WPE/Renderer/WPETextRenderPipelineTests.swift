#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

struct WPETextRenderPipelineTests {
    private func fonts() -> WPETextFontResolver {
        WPETextFontResolver(resolver: WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        ))
    }

    private func textObject(
        _ text: String,
        textScript: String? = nil,
        padding: Double = 20,
        effects: [WPESceneImageEffect] = []
    ) -> WPESceneTextObject {
        WPESceneTextObject(
            id: "tt", name: "target", text: text, textScript: textScript,
            fontRelativePath: nil, pointSize: 18,
            color: SIMD3<Double>(1, 1, 1), alpha: 0.5,
            origin: SIMD3<Double>(960, 540, 0), scale: SIMD3<Double>(1, 1, 1),
            visible: true,
            horizontalAlignment: "center", verticalAlignment: "center",
            maxWidth: nil, parallaxDepth: SIMD2<Double>(0, 0), padding: padding,
            effects: effects
        )
    }

    private func document(with object: WPESceneTextObject) -> WPESceneDocument {
        WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: [],
            textObjects: [object],
            objectPaintOrder: [object.id: 0],
            diagnostics: []
        )
    }

    @Test("Layout snapshot ceils ascent like WPE")
    func layoutSnapshotCeilsAscent() throws {
        let object = textObject("Hello")
        let resolver = fonts()
        let snapshot = WPETextRenderPlanner.snapshot(for: object, fonts: resolver)
        let layout = try #require(WPETextLayoutEngine.layout(
            text: object.text,
            font: resolver.font(for: object),
            horizontalAlignment: object.horizontalAlignment
        ))
        #expect(snapshot.ascender == layout.metrics.ascender.rounded(.up))
    }

    @Test("Direct text glyph pass targets the scene and owns no text texture")
    func directTextBuildsScenePass() throws {
        let object = textObject("Hello")
        let plan = WPETextRenderPlanner.plan(for: object, fonts: fonts())
        let document = document(with: object).appendingImageObjects([plan.imageObject])
        let root = FileManager.default.temporaryDirectory
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first { $0.objectID == object.id })
        #expect(plan.mode == .direct)
        #expect(layer.passes.count == 1)
        #expect(layer.passes[0].shader == WPETextLayerSynthesis.glyphPassShader)
        #expect(layer.passes[0].target == .scene)
        #expect(layer.passes[0].textures.isEmpty)
    }

    @Test("Text effects route through an exact offscreen composite before scene")
    func effectedTextBuildsOffscreenChain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WPETextGraph-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let effectRoot = root.appendingPathComponent("effects/opacity")
        let materialRoot = root.appendingPathComponent("materials/effects")
        try FileManager.default.createDirectory(at: effectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: materialRoot, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "passes": [["material": "materials/effects/opacity.json"]]
        ]).write(to: effectRoot.appendingPathComponent("effect.json"))
        try JSONSerialization.data(withJSONObject: [
            "passes": [["shader": "effects/opacity", "textures": [NSNull()]]]
        ]).write(to: materialRoot.appendingPathComponent("opacity.json"))

        let effect = WPESceneImageEffect(
            id: "e", name: "opacity", fileRelativePath: "effects/opacity/effect.json",
            visible: true, passOverrides: []
        )
        let object = textObject("Hello", effects: [effect])
        let plan = WPETextRenderPlanner.plan(for: object, fonts: fonts())
        let document = document(with: object).appendingImageObjects([plan.imageObject])
        let graph = try WPERenderGraphBuilder(cacheRootURL: root).build(document: document)
        let layer = try #require(graph.layers.first)
        #expect(plan.mode == .offscreen)
        #expect(layer.passes.first?.shader == WPETextLayerSynthesis.glyphPassShader)
        if case .layerComposite = layer.passes.first?.target { } else {
            Issue.record("glyph pass must start in the layer composite")
        }
        #expect(layer.passes.contains { $0.shader == "effects/opacity" })
        #expect(layer.passes.last?.target == .scene)
    }

    @Test("Dynamic clock widths do not retain a guessed maximum")
    func dynamicClockUsesCurrentExtent() {
        let resolver = fonts()
        let seed = textObject("1:11", textScript: "export function update(v) { return v }")
        let wide = seed.withLiveText("23:59:59", alpha: 1, color: nil)
        let seedSnapshot = WPETextRenderPlanner.snapshot(for: seed, fonts: resolver)
        let wideSnapshot = WPETextRenderPlanner.snapshot(for: wide, fonts: resolver)
        // Bind as CGFloat: a CGFloat/Double mix inside `#expect` compares false for bit-identical operands (see WPETextLayerSynthesisTests).
        let expectedSeedWidth: CGFloat = ceil(seedSnapshot.blockSize.width + seed.padding * 2)
        let expectedWideWidth: CGFloat = ceil(wideSnapshot.blockSize.width + wide.padding * 2)
        #expect(seedSnapshot.surfaceSize.width == expectedSeedWidth)
        #expect(wideSnapshot.surfaceSize.width == expectedWideWidth)
        #expect(wideSnapshot.surfaceSize.width > seedSnapshot.surfaceSize.width)
    }

    /// The glyph FBO is composited later as a premultiplied image, so its alpha has to
    /// match the coverage its RGB was premultiplied by. Squaring it breaks that invariant
    /// and the composite lets too much background through — thin text washes out.
    @Test("Glyph target alpha matches the coverage its RGB was premultiplied by")
    func glyphTargetAlphaMatchesPremultipliedCoverage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 2, height: 2, mipmapped: false
        )
        let atlas = try #require(device.makeTexture(descriptor: atlasDescriptor))
        var texels: [UInt8] = [128, 128, 128, 128]
        atlas.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &texels, bytesPerRow: 2)
        let corners: [SIMD2<Float>] = [
            .init(0, 0), .init(4, 0), .init(0, 4),
            .init(4, 0), .init(4, 4), .init(0, 4)
        ]
        var vertices = corners.map { WPETextMeshVertex(position: $0, uv: SIMD2<Float>(0.5, 0.5)) }
        let buffer = try #require(device.makeBuffer(
            bytes: &vertices,
            length: MemoryLayout<WPETextMeshVertex>.stride * vertices.count
        ))
        let payload = WPETextMeshPayload(
            pages: [WPETextMeshPageDraw(vertexBuffer: buffer, vertexCount: vertices.count, texture: atlas)],
            color: SIMD4<Float>(1, 1, 1, 1)
        )
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 4, height: 4, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try executor.encodeTextMesh(
            payload: WPETextRenderPayload(
                mode: .direct,
                mesh: payload,
                backgroundColor: nil,
                copiesSceneBackground: false
            ),
            sceneSize: CGSize(width: 4, height: 4),
            output: output,
            clearsOutput: true,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var halves = [UInt16](repeating: 0, count: 4 * 4 * 4)
        output.getBytes(&halves, bytesPerRow: 32, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        let coverage = Float(128) / 255
        let alpha = Float(Float16(bitPattern: halves[(4 + 1) * 4 + 3]))
        let red = Float(Float16(bitPattern: halves[(4 + 1) * 4]))
        #expect(abs(alpha - coverage) < 0.01)
        // The premultiplied invariant the composite depends on.
        #expect(abs(red - alpha) < 0.01)
    }

    @Test("Copied text backgrounds do not add the backdrop again around glyphs",
          arguments: [MTLPixelFormat.rgba8Unorm, .rgba16Float])
    func copiedTextBackgroundPreservesScene(format: MTLPixelFormat) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: 4, height: 4, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        let scene = try #require(device.makeTexture(descriptor: descriptor))
        let surface = try #require(device.makeTexture(descriptor: descriptor))
        if format == .rgba16Float {
            var values = (0 ..< 16).flatMap { _ in
                [Float16(0.2), Float16(0.4), Float16(0.6), Float16(1)].map(\.bitPattern)
            }
            scene.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                          withBytes: &values, bytesPerRow: 32)
        } else {
            var values: [UInt8] = (0 ..< 16).flatMap { _ in [51, 102, 153, 255] }
            scene.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                          withBytes: &values, bytesPerRow: 16)
        }
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 2, height: 2, mipmapped: false
        )
        let atlas = try #require(device.makeTexture(descriptor: atlasDescriptor))
        var coverage = [UInt8](repeating: 128, count: 4)
        atlas.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                      withBytes: &coverage, bytesPerRow: 2)
        // The left half is padding; the right half is a partly covered glyph.
        let corners: [SIMD2<Float>] = [
            .init(2, 0), .init(4, 0), .init(2, 4),
            .init(4, 0), .init(4, 4), .init(2, 4),
        ]
        var vertices = corners.map { WPETextMeshVertex(position: $0, uv: .init(0.5, 0.5)) }
        let buffer = try #require(device.makeBuffer(
            bytes: &vertices, length: MemoryLayout<WPETextMeshVertex>.stride * vertices.count
        ))
        let mesh = WPETextMeshPayload(
            pages: [.init(vertexBuffer: buffer, vertexCount: vertices.count, texture: atlas)],
            color: .init(1, 1, 1, 1)
        )
        let queue = try #require(device.makeCommandQueue())
        let commandBuffer = try #require(queue.makeCommandBuffer())
        try executor.encodeTextBackground(
            source: scene,
            uniforms: WPEObjectQuadUniforms(centerAndSize: .init(0, 0, 4, 4),
                                            sceneSizeAndRotation: .init(4, 4, 0, 0),
                                            uvSignAndPadding: .init(1, 1, 0, 0)),
            output: surface, commandBuffer: commandBuffer
        )
        try executor.encodeTextMesh(
            payload: WPETextRenderPayload(mode: .offscreen, mesh: mesh,
                                          backgroundColor: nil, copiesSceneBackground: true),
            sceneSize: CGSize(width: 4, height: 4), output: surface,
            clearsOutput: false, commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)

        let source = WPETextureReference.image("copied-clock")
        let pass = WPERenderPass(
            id: "clock.composite", phase: .material, shader: "commands/copy",
            source: source, target: .scene, textures: [0: source], binds: [:],
            constants: [:], combos: [:], blending: "premultipliednormal",
            cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let layer = WPERenderLayer(
            objectID: "clock", objectName: "Clock", imagePath: "copied-clock",
            materialPath: nil, geometry: .identity, compositeA: "clock.a",
            compositeB: "clock.b", localFBOs: [], passes: [pass]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(
            graphLayer: layer, passes: [.init(
                pass: pass,
                shader: .init(name: pass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
                textureBindings: [0: source], comboValues: [:], uniformValues: [:]
            )]
        )])
        executor.sceneClearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4),
                                         textures: ["copied-clock": surface])
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var bytes = [UInt8](repeating: 0, count: 64)
        staged.getBytes(&bytes, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        let blank = 4 * 4
        for channel in 0 ..< 4 {
            #expect(abs(Int(bytes[blank + channel]) - [51, 102, 153, 255][channel]) <= 2)
        }
        let glyph = (4 + 3) * 4
        for channel in 0 ..< 3 {
            let backdrop = [Float(0.2), 0.4, 0.6][channel]
            let expected = Int((Float(128) / 255 + backdrop * (1 - Float(128) / 255)) * 255)
            #expect(abs(Int(bytes[glyph + channel]) - expected) <= 2)
        }
        #expect(bytes[glyph + 3] == 255)
    }
}
#endif
