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

    /// Source pinned to 3596044309-full-steady.rdc SHA256 52dcc52060c373199546c0fe2e61284ee5c48b53780c2049347213546f769237.
    /// Events 1438/1456: copied scene RGB + alpha0, then straight glyph RGB and SrcAlpha alpha blending.
    /// Padding is deliberately uncovered; the right half has constant atlas coverage128/255.
    @Test("Native effect text retains coverage through border, pulse, and blur/pulse publication",
          arguments: ["copy", "border", "pulse", "blur-pulse"])
    func nativeEffectTextSurfaceCarrier(operatorName: String) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["WPEDumpScenePasses"] = "native-text"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.sceneClearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let atlas = try #require(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 2, height: 2, mipmapped: false
        )))
        var coverage = [UInt8](repeating: 128, count: 4)
        atlas.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                      withBytes: &coverage, bytesPerRow: 2)
        let corners: [SIMD2<Float>] = [.init(2, 0), .init(4, 0), .init(2, 4),
                                       .init(4, 0), .init(4, 4), .init(2, 4)]
        var vertices = corners.map { WPETextMeshVertex(position: $0, uv: .init(0.5, 0.5)) }
        let buffer = try #require(device.makeBuffer(
            bytes: &vertices, length: MemoryLayout<WPETextMeshVertex>.stride * vertices.count
        ))
        let mesh = WPETextMeshPayload(pages: [.init(vertexBuffer: buffer, vertexCount: vertices.count, texture: atlas)],
                                      color: .init(1, 1, 1, 1))
        let composite = WPETextureReference.fbo("native-text.a")
        let glyph = WPERenderPass(
            id: "native-text.0", phase: .material, shader: WPETextLayerSynthesis.glyphPassShader,
            source: composite, target: .layerComposite(name: "native-text.a"), textures: [:], binds: [:],
            constants: [:], combos: [:], blending: "normal", cullMode: "nocull",
            depthTest: "disabled", depthWrite: "disabled"
        )
        func effectPass(_ index: Int, shader: String, source: WPETextureReference,
                        target: WPERenderTarget, blend: String = "disabled") -> WPERenderPass {
            .init(id: "native-text.\(index)", phase: .effect(file: "native-source-pinned"), shader: shader,
                  source: source, target: target, textures: [0: source], binds: [:], constants: [:], combos: [:],
                  blending: blend, cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled")
        }
        let scratch = WPETextureReference.fbo("native-text.b")
        var effects: [WPERenderPass] = []
        if operatorName == "blur-pulse" {
            // Authored Gaussian zero-distance control: every tap reads the same pixel.
            // This checks the intermediate representation without relying on edge-history coverage.
            effects.append(effectPass(1, shader: "probe-gaussian-zero", source: composite,
                                      target: .layerComposite(name: "native-text.b")))
        }
        let input = effects.isEmpty ? composite : scratch
        effects.append(effectPass(effects.count + 1, shader: operatorName == "copy" ? "commands/copy" : "probe-" + operatorName,
                                  source: input, target: .layerComposite(name: "native-text.a")))
        let terminal = WPERenderPass(
            id: "native-text.final", phase: .material, shader: "commands/copy",
            source: composite, target: .scene, textures: [0: composite], binds: [:], constants: [:], combos: [:],
            blending: "premultipliednormal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let passes = [glyph] + effects + [terminal]
        let layer = WPERenderLayer(objectID: "native-text", objectName: "Native text",
                                   imagePath: "__wpetext__/offscreen/native-text.layer", materialPath: nil,
                                   geometry: .init(origin: .init(2, 2, 0), scale: .init(1, 1, 1), angles: .zero,
                                                   alignment: .center, size: CGSize(width: 4, height: 4),
                                                   alpha: 1, color: .init(1, 1, 1), brightness: 1),
                                   compositeA: "native-text.a", compositeB: "native-text.b", localFBOs: [], passes: passes)
        let vertex = "attribute vec3 a_Position;\nvoid main() { gl_Position = vec4(a_Position, 1.0); }"
        func program(_ pass: WPERenderPass) -> WPEShaderProgram {
            if pass.shader.hasPrefix("probe-") {
                let body = if pass.shader == "probe-border" {
                    // Native event1509: border depends on input alpha, authored RGB is unrelated to backdrop RGB.
                    "float a = smoothstep(0.1, 0.2, c.a); gl_FragColor = vec4(0.46275, 0.46275, 0.83137, a * 0.5);"
                } else if pass.shader == "probe-gaussian-zero" {
                    "gl_FragColor = c;"
                } else {
                    // Native event268: Add-mode pulse changes RGB while preserving coverage alpha.
                    "gl_FragColor = vec4(min(c.rgb + c.rgb, vec3(1.0)), c.a);"
                }
                return .init(name: pass.shader, vertexSource: vertex,
                             fragmentSource: "uniform sampler2D g_Texture0;\nvarying vec2 v_TexCoord;\nvoid main() { vec4 c = texture2D(g_Texture0, v_TexCoord); " + body + " }",
                             isBuiltin: false)
            }
            return .init(name: pass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true)
        }
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: passes.map {
            .init(pass: $0, shader: program($0), textureBindings: $0.textures, comboValues: [:], uniformValues: [:])
        })]).resolvingRenderContracts()
        // A declared independent carrier must remain untouched by shader alpha preprocessing.
        for prepared in pipeline.layers[0].passes where prepared.pass.shader.hasPrefix("probe-") {
            #expect(prepared.renderContract.shaderAlpha.unpremultipliedInputSlots.isEmpty)
            #expect(prepared.renderContract.shaderAlpha.premultipliedOutput == false)
        }
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: [:],
                                         sceneID: "native-text", textPayloads: ["native-text": .init(
                                             mode: .offscreen, mesh: mesh, backgroundColor: nil, copiesSceneBackground: true
                                         )])
        try #require(executor.untranslatableShaderReasonByPassID.isEmpty)
        let surface = try #require(executor.scenePassDumps.first { $0.label == glyph.id }?.texture)
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(surface))
        var bytes = [UInt8](repeating: 0, count: staged.width * staged.height * 4)
        staged.getBytes(&bytes, bytesPerRow: staged.width * 4,
                        from: MTLRegionMake2D(0, 0, staged.width, staged.height), mipmapLevel: 0)
        #expect(staged.width == 4 && staged.height == 4)
        #expect(Array(bytes[0 ..< 4]) == [51, 102, 153, 0])
        let glyphPixel = Array(bytes[12 ..< 16])
        #expect(abs(Int(glyphPixel[0]) - 153) <= 1)
        #expect(abs(Int(glyphPixel[1]) - 179) <= 1)
        #expect(abs(Int(glyphPixel[2]) - 204) <= 1)
        #expect(abs(Int(glyphPixel[3]) - 64) <= 1)
        let final = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var finalBytes = [UInt8](repeating: 0, count: 64)
        final.getBytes(&finalBytes, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        // Uncovered padding must preserve the original scene after every authored operator and publication.
        #expect(Array(finalBytes[0 ..< 4]) == [51, 102, 153, 255])
        let observed = Array(finalBytes[12 ..< 16])
        let coverageAlpha = Double(glyphPixel[3]) / 255
        let rgb: [Double] = operatorName == "border" ? [0.46275, 0.46275, 0.83137]
            : operatorName == "copy" ? glyphPixel.prefix(3).map { Double($0) / 255 } : [1, 1, 1]
        let alpha = operatorName == "border" ? 128.0 / 255 : coverageAlpha
        let backdrop = [0.2, 0.4, 0.6]
        for channel in 0 ..< 3 {
            let expected = Int(((rgb[channel] * alpha + backdrop[channel] * (1 - alpha)) * 255).rounded())
            #expect(abs(Int(observed[channel]) - expected) <= 2)
        }
        #expect(observed[3] == 255)
        #expect(executor.gpuErrorSink.summary.count == 0)
    }

    /// Opacity changes coverage without scaling independent RGB.
    @Test("Native opacity distinguishes independent text carrier from PMA",
          arguments: [UInt8(0), 128], [false, true])
    func nativeOpacityIndependentTextCarrier(sourceAlpha: UInt8, independent: Bool) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["WPEDumpScenePasses"] = "carrier-opacity"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.sceneClearColor = MTLClearColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let source = try #require(device.makeTexture(descriptor: descriptor))
        let alphaScale = Double(sourceAlpha) / 255
        let rgb = independent ? [192, 128, 64] : [192, 128, 64].map { Int((Double($0) * alphaScale).rounded()) }
        let rgba = rgb.map { UInt8($0) } + [sourceAlpha]
        let semantics: WPEResourceSemantics = independent ? .textEffectCarrier : .premultipliedColor
        rgba.withUnsafeBytes {
            source.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                           withBytes: $0.baseAddress!, bytesPerRow: 4)
        }
        let effectPass = WPERenderPass(
            id: "carrier-opacity.effect", phase: .effect(file: "effects/opacity/effect.json"),
            shader: "effects/opacity", source: .asset("carrier"), target: .layerComposite(name: "carrier-opacity.a"),
            textures: [0: .asset("carrier")], binds: [:], constants: ["g_UserAlpha": .number(0.5)],
            combos: [:], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let input = WPEPassInputContract(reference: .asset("carrier"), semantics: semantics, origin: .producer)
        let contract = WPEPassRenderContract.resolve(
            pass: effectPass, shader: nil, bindings: effectPass.textures, alphaOverride: nil,
            inputDeclarations: [0: input], outputDeclaration: semantics
        )
        let effect = WPEPreparedRenderPass(
            pass: effectPass, shader: nil, textureBindings: effectPass.textures,
            comboValues: [:], uniformValues: effectPass.constants, renderContract: contract
        )
        let terminalPass = WPERenderPass(
            id: "carrier-opacity.final", phase: .material, shader: "commands/copy",
            source: .fbo("carrier-opacity.a"), target: .scene,
            textures: [0: .fbo("carrier-opacity.a")], binds: [:], constants: [:], combos: [:],
            blending: "premultipliednormal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let terminal = WPEPreparedRenderPass(
            pass: terminalPass, shader: nil, textureBindings: terminalPass.textures, comboValues: [:], uniformValues: [:]
        )
        let layer = WPERenderLayer(
            objectID: "carrier-opacity", objectName: "Carrier opacity", imagePath: "carrier", materialPath: nil,
            geometry: .identity, compositeA: "carrier-opacity.a", compositeB: "carrier-opacity.b",
            localFBOs: [], passes: [effectPass, terminalPass]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: [effect, terminal])])
            .resolvingRenderContracts { _ in semantics }
        #expect(pipeline.layers[0].passes[0].renderContract.nativeAlpha.input == .none)
        #expect(pipeline.layers[0].passes[0].renderContract.stored == semantics)
        let output = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4),
                                         textures: ["carrier": source], sceneID: "carrier-opacity")
        try #require(executor.untranslatableShaderReasonByPassID.isEmpty)
        let intermediate = try #require(executor.scenePassDumps.first { $0.label == effectPass.id || $0.label == "Lcarrier-opacity-" + effectPass.id }?.texture)
        let staged = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(intermediate))
        var bytes = [UInt8](repeating: 0, count: staged.width * staged.height * 4)
        staged.getBytes(&bytes, bytesPerRow: staged.width * 4,
                        from: MTLRegionMake2D(0, 0, staged.width, staged.height), mipmapLevel: 0)
        for channel in 0 ..< 3 {
            let expected = independent ? Int(rgba[channel]) : Int((Double(rgba[channel]) * 0.5).rounded())
            #expect(abs(Int(bytes[channel]) - expected) <= 1)
        }
        #expect(abs(Int(bytes[3]) - Int(sourceAlpha) / 2) <= 1)
        let final = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var finalBytes = [UInt8](repeating: 0, count: 64)
        final.getBytes(&finalBytes, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        let alpha = Double(sourceAlpha) / 255 * 0.5
        for channel in 0 ..< 3 {
            let contribution = Double(rgba[channel]) * (independent ? alpha : 0.5)
            let expected = Int((contribution + [51.0, 102, 153][channel] * (1 - alpha)).rounded())
            #expect(abs(Int(finalBytes[channel]) - expected) <= 2)
        }
        #expect(finalBytes[3] == 255)
        #expect(executor.gpuErrorSink.summary.count == 0)
    }

    @Test("Explicit text effect data FBO keeps its declared role", arguments: ["r8", "rg88"])
    func textEffectExplicitDataDeclaration(format: String) {
        let glyph = WPERenderPass(
            id: "carrier.glyph", phase: .material, shader: WPETextLayerSynthesis.glyphPassShader,
            source: .fbo("a"), target: .layerComposite(name: "a"), textures: [:], binds: [:],
            constants: [:], combos: [:], blending: "normal", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let effect = WPERenderPass(
            id: "carrier.data", phase: .effect(file: "probe"), shader: "carrier-data-probe",
            source: .fbo("a"), target: .fbo(name: "data"), textures: [0: .fbo("a")], binds: [:],
            constants: [:], combos: [:], blending: "disabled", cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled"
        )
        let program = WPEShaderProgram(name: effect.shader, vertexSource: "", fragmentSource: "", isBuiltin: false)
        let prepared = [
            WPEPreparedRenderPass(pass: glyph, shader: nil, textureBindings: [:], comboValues: [:], uniformValues: [:]),
            WPEPreparedRenderPass(pass: effect, shader: program, textureBindings: effect.textures,
                                  comboValues: [:], uniformValues: [:]),
        ]
        let layer = WPERenderLayer(
            objectID: "carrier", objectName: "Carrier data", imagePath: "__wpetext__/offscreen/carrier.layer",
            materialPath: nil, geometry: .identity, compositeA: "a", compositeB: "b",
            localFBOs: [WPERenderFBO(name: "data", scale: 1, format: format)], passes: [glyph, effect]
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: prepared)]).resolvingRenderContracts()
        let expected = WPEResourceSemantics.data(format == "r8" ? .mask : .flow)
        #expect(pipeline.layers[0].passes[1].renderContract.outputDeclaration == expected)
        #expect(pipeline.layers[0].passes[1].renderContract.stored == expected)
    }

    @Test("Text carrier copy and opacity preserve physical R8 values across gates",
          arguments: [UInt8(0), 128], ["copy-disabled-open", "copy-pma-open", "opacity-disabled-open", "opacity-disabled-closed"])
    func textCarrierPhysicalR8Consumer(sourceAlpha: UInt8, configuration: String) throws {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previous
        arguments["WPEDumpScenePasses"] = "carrier-r8"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let color = SIMD4<Float>(192.0 / 255, 128.0 / 255, 64.0 / 255, 1)
        executor.sceneClearColor = MTLClearColor(red: Double(color.x), green: Double(color.y), blue: Double(color.z), alpha: 1)
        let atlas = try #require(device.makeTexture(descriptor: .texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 2, height: 2, mipmapped: false
        )))
        // Equal foreground/background RGB isolates coverage: (181/255)^2 rounds to A128.
        var coverage = [UInt8](repeating: sourceAlpha == 0 ? 0 : 181, count: 4)
        atlas.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: &coverage, bytesPerRow: 2)
        let corners: [SIMD2<Float>] = [.init(0, 0), .init(4, 0), .init(0, 4),
                                       .init(4, 0), .init(4, 4), .init(0, 4)]
        var vertices = corners.map { WPETextMeshVertex(position: $0, uv: .init(0.5, 0.5)) }
        let buffer = try #require(device.makeBuffer(
            bytes: &vertices, length: MemoryLayout<WPETextMeshVertex>.stride * vertices.count
        ))
        let mesh = WPETextMeshPayload(pages: [.init(vertexBuffer: buffer, vertexCount: vertices.count, texture: atlas)], color: color)
        let gate = WPEPassVisibilityGate(script: .init(script: "return true;", seed: .zero), initialVisible: false)
        let open = configuration.hasSuffix("open")
        let opacity = configuration.hasPrefix("opacity")
        let composite = WPETextureReference.fbo("carrier-r8.a")
        let data = WPETextureReference.fbo("carrier-r8.data")
        func pass(_ id: String, shader: String, source: WPETextureReference, target: WPERenderTarget,
                  phase: WPERenderPassPhase = .material, blend: String = "disabled",
                  constants: [String: WPESceneShaderConstantValue] = [:], visibilityGate: WPEPassVisibilityGate? = nil) -> WPERenderPass {
            .init(id: id, phase: phase, shader: shader, source: source, target: target,
                  textures: [0: source], binds: [:], constants: constants, combos: [:], blending: blend,
                  cullMode: "nocull", depthTest: "disabled", depthWrite: "disabled", visibilityGate: visibilityGate)
        }
        let glyph = pass("carrier-r8.glyph", shader: WPETextLayerSynthesis.glyphPassShader,
                         source: composite, target: .layerComposite(name: "carrier-r8.a"), blend: "normal")
        let effect = pass("carrier-r8.effect", shader: opacity ? "effects/opacity" : "commands/copy",
                          source: composite, target: .fbo(name: "carrier-r8.data"), phase: .effect(file: "probe"),
                          blend: configuration == "copy-pma-open" ? "premultipliednormal" : "disabled",
                          constants: opacity ? ["g_UserAlpha": .number(0.5)] : [:], visibilityGate: gate)
        let observe = pass("carrier-r8.observe", shader: "commands/copy", source: data,
                           target: .fbo(name: "carrier-r8.observed"))
        let terminal = pass("carrier-r8.final", shader: "commands/copy", source: composite,
                            target: .scene, blend: "premultipliednormal")
        var passes = [glyph]
        var textures: [String: MTLTexture] = [:]
        if !open {
            // Closed named-FBO gates perform no write; retain a real prior data draw.
            let seed = try #require(device.makeTexture(descriptor: .texture2DDescriptor(
                pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false
            )))
            var red: UInt8 = 192
            seed.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &red, bytesPerRow: 1)
            textures["r8-seed"] = seed
            passes.append(pass("carrier-r8.seed", shader: "commands/copy", source: .asset("r8-seed"),
                               target: .fbo(name: "carrier-r8.data")))
        }
        passes += [effect, observe, terminal]
        let layer = WPERenderLayer(
            objectID: "carrier-r8", objectName: "Carrier R8", imagePath: "__wpetext__/offscreen/carrier-r8.layer",
            materialPath: nil, geometry: .init(origin: .init(2, 2, 0), scale: .init(1, 1, 1), angles: .zero,
                                               alignment: .center, size: CGSize(width: 4, height: 4),
                                               alpha: 1, color: .init(1, 1, 1), brightness: 1),
            compositeA: "carrier-r8.a", compositeB: "carrier-r8.b", localFBOs: [
                WPERenderFBO(name: "carrier-r8.data", scale: 1, format: "r8", pixelSize: CGSize(width: 4, height: 4)),
                WPERenderFBO(name: "carrier-r8.observed", scale: 1, format: "r8", pixelSize: CGSize(width: 4, height: 4)),
            ], passes: passes
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: layer, passes: passes.map {
            .init(pass: $0, shader: nil, textureBindings: $0.textures, comboValues: [:], uniformValues: $0.constants)
        })]).resolvingRenderContracts { _ in .data(.mask) }
        let effectContract = try #require(pipeline.layers[0].passes.first { $0.id == effect.id }?.renderContract)
        let observeContract = try #require(pipeline.layers[0].passes.first { $0.id == observe.id }?.renderContract)
        #expect(effectContract.inputs[0]?.semantics == .textEffectCarrier)
        #expect(effectContract.outputDeclaration == .data(.mask))
        #expect(effectContract.stored == .data(.mask))
        #expect(observeContract.inputs[0]?.semantics == .data(.mask))
        #expect(observeContract.stored == .data(.mask))
        _ = try executor.render(pipeline: pipeline, size: CGSize(width: 4, height: 4), textures: textures,
                                passVisibility: [gate.id: open], sceneID: "carrier-r8", textPayloads: ["carrier-r8": .init(
                                    mode: .offscreen, mesh: mesh, backgroundColor: nil, copiesSceneBackground: true
                                )])
        try #require(executor.untranslatableShaderReasonByPassID.isEmpty)
        func dumped(_ id: String) -> MTLTexture? {
            executor.scenePassDumps.first { $0.label == id || $0.label == "Lcarrier-r8-" + id }?.texture
        }
        let glyphDump = try #require(dumped(glyph.id))
        let carrier = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(glyphDump))
        #expect(carrier.pixelFormat == .rgba8Unorm)
        var rgba = [UInt8](repeating: 0, count: carrier.width * carrier.height * 4)
        carrier.getBytes(&rgba, bytesPerRow: carrier.width * 4,
                         from: MTLRegionMake2D(0, 0, carrier.width, carrier.height), mipmapLevel: 0)
        for (channel, expected) in [192, 128, 64, Int(sourceAlpha)].enumerated() {
            #expect(abs(Int(rgba[channel]) - expected) <= 1)
        }
        #expect((dumped(effect.id) != nil) == open)
        let observeDump = try #require(dumped(observe.id))
        let observed = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(observeDump))
        #expect(observed.pixelFormat == .r8Unorm)
        #expect(observed.width == 4 && observed.height == 4)
        var red = [UInt8](repeating: 0, count: observed.width * observed.height)
        observed.getBytes(&red, bytesPerRow: observed.width,
                          from: MTLRegionMake2D(0, 0, observed.width, observed.height), mipmapLevel: 0)
        #expect(red.allSatisfy { abs(Int($0) - 192) <= 1 })
        #expect(executor.gpuErrorSink.summary.count == 0)
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
