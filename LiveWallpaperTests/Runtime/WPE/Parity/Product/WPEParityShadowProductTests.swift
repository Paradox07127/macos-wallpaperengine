#if !LITE_BUILD && DEBUG
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// The bundled toolchain lowers the original caster's SV_ViewportArrayIndex and the receiver's
    /// SamplerComparisonState so they work on a Depth32Float atlas.
    func testShadowToolchainEmitsViewportIndexAndDepthComparison() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (assets, compiler) = try shadowInputs()
        let caster = try WPEParityProgramResolver.resolve(WPEParityProgramDescription(
            material: WPEParityProgramMaterial(shader: "shadowcaster", path: "materials/util/shadowcaster.json"),
            engineFlags: WPEEngineComboFlags(), boundTextures: [:]
        ), sources: assets)
        let casterStages = try await compiler.compile(WPEParityShaderCompileRequest(
            program: caster.hlsl, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let casterVertex = try XCTUnwrap(casterStages.stages[.vertex]?.metallib)
        XCTAssertNotNil(casterVertex.range(of: Data("air.viewport_array_index".utf8)),
                        "caster vertex stage must write [[viewport_array_index]]")

        // SampleCmpLevelZero at both texel centres of a 2×1 Depth32Float texture holding 0.25 and 0.75.
        let program = WPEHLSLProgram(vertex: Array("""
        float4 main(uint id : SV_VertexID) : SV_Position {
            const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            return float4(p[id], 0, 1);
        }
        """.utf8), fragment: Array("""
        Texture2D g_Texture6 : register(t6);
        SamplerComparisonState g_Texture6SamplerComparisonState : register(s6);
        float4 main(float4 position : SV_Position) : SV_Target {
            return g_Texture6.SampleCmpLevelZero(g_Texture6SamplerComparisonState, float2(position.x / 2, 0.5), 0.5).rrrr;
        }
        """.utf8))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appending(path: "compare-cache")
        ))
        let artifact = try await store.artifact(for: WPEParityShaderCompileRequest(
            program: program, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.normal, modifiers: .writeAlpha),
                                                colorPixelFormat: .rgba8Unorm)
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 2, height: 1,
                                                                       mipmapped: false)
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 1,
                                                                        mipmapped: false)
        targetDescriptor.usage = .renderTarget
        targetDescriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let arena = try XCTUnwrap(WPEParityFrameArena(device: device, capacity: 65536))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let stored: [Float] = [0.25, 0.75]
        let source = try XCTUnwrap(device.makeBuffer(bytes: stored, length: 8, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: source, sourceOffset: 0, sourceBytesPerRow: 8, sourceBytesPerImage: 8,
                  sourceSize: MTLSize(width: 2, height: 1, depth: 1), to: depth, destinationSlice: 0,
                  destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        let frame = try XCTUnwrap(arena.beginFrame(for: command))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 1, 1)
        pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var draw = try WPEParityDraw(
            pipeline: pipeline, depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared)),
            primitiveType: .triangle, vertexCount: 3
        )
        draw.textures = ["g_Texture6": depth]
        draw.samplers = ["g_Texture6SamplerComparisonState": .wpeComparison()]
        try WPEParityDrawEncoder(factory: factory).encode(draw, frame: frame, hasDepthAttachment: false, on: encoder)
        encoder.endEncoding()
        command.commit()
        await command.completed()
        XCTAssertNil(command.error)
        var output = [UInt8](repeating: 0, count: 8)
        target.getBytes(&output, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 1), mipmapLevel: 0)
        XCTAssertEqual([output[0], output[4]], [255, 0], "only the texel the 0.5 reference is GREATER than may pass")

        var flags = WPEEngineComboFlags()
        flags.spotLights = 1
        flags.spotShadowLights = 1
        flags.shadowQuality = 2
        let receiver = try WPEParityProgramResolver.resolve(WPEParityProgramDescription(
            material: WPEParityProgramMaterial(shader: "generic4", combos: ["LIGHTING": 1]),
            engineFlags: flags, boundTextures: [:]
        ), sources: assets)
        XCTAssertTrue(receiver.combos.contains(WPEShaderDefine(name: "LIGHTS_SHADOW_MAPPING", value: "1")))
        let receiverStages = try await compiler.compile(WPEParityShaderCompileRequest(
            program: receiver.hlsl, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let reflection = try JSONDecoder().decode(WPEStageReflection.self,
                                                  from: XCTUnwrap(receiverStages.stages[.fragment]).reflectionJSON)
        XCTAssertTrue(reflection.resources.contains { $0.name == "g_Texture6" && $0.kind == .texture })
        XCTAssertTrue(reflection.resources.contains { $0.name == "g_Texture6SamplerComparisonState" && $0.kind == .sampler })
    }

    /// Each instance draws a full-viewport triangle at depth 0.25·(instance+1) into viewport `instance`
    /// (shadowcaster.vert:104-105), so the two viewports of the 4×2 atlas hold different depths.
    func testInstancedDrawSelectsViewportPerInstanceOnDepthOnlyTarget() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (_, compiler) = try shadowInputs()
        let program = WPEHLSLProgram(vertex: Array("""
        struct Output {
            float4 position : SV_Position;
            uint viewport : SV_ViewportArrayIndex;
        };
        Output main(uint id : SV_VertexID, uint instance : SV_InstanceID) {
            const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
            Output output;
            output.position = float4(p[id], 0.25 * (instance + 1), 1);
            output.viewport = instance;
            return output;
        }
        """.utf8), fragment: Array("void main() {}".utf8))
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appending(path: "instanced-cache")
        ))
        let artifact = try await store.artifact(for: WPEParityShaderCompileRequest(
            program: program, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
        ))
        let factory = WPEParityPipelineFactory(device: device)
        let pipeline = try factory.makePipeline(artifact: artifact, blend: .wpe(.normal), colorPixelFormat: .invalid,
                                                depthStencilPixelFormat: .depth32Float)

        let instanced = try await renderViewportDepth(instanceCount: 2, pipeline: pipeline, factory: factory, device: device)
        XCTAssertEqual(instanced, [0.25, 0.25, 0.5, 0.5, 0.25, 0.25, 0.5, 0.5],
                       "the second instance did not reach the right viewport")
        let single = try await renderViewportDepth(instanceCount: 1, pipeline: pipeline, factory: factory, device: device)
        XCTAssertEqual(single, [0.25, 0.25, 0, 0, 0.25, 0.25, 0, 0], "a single instance wrote outside viewport 0")
    }

    private func renderViewportDepth(instanceCount: Int, pipeline: WPEParityPipeline, factory: WPEParityPipelineFactory,
                                     device: MTLDevice) async throws -> [Float] {
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 4, height: 2,
                                                                       mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let arena = try XCTUnwrap(WPEParityFrameArena(device: device, capacity: 65536))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try XCTUnwrap(arena.beginFrame(for: command))
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        let indices: [UInt16] = [0, 1, 2]
        var draw = try WPEParityDraw(
            pipeline: pipeline, depthStencil: .wpe(depthTest: true, depthWrite: true),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: true, multisample: false),
            vertexBuffer: XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared)),
            primitiveType: .triangle, vertexCount: 3,
            indexBuffer: XCTUnwrap(device.makeBuffer(bytes: indices, length: 6, options: .storageModeShared)),
            indexCount: 3
        )
        draw.instanceCount = instanceCount
        draw.viewports = [MTLViewport(originX: 0, originY: 0, width: 2, height: 2, znear: 0, zfar: 1),
                          MTLViewport(originX: 2, originY: 0, width: 2, height: 2, znear: 0, zfar: 1)]
        try WPEParityDrawEncoder(factory: factory).encode(draw, frame: frame, hasDepthAttachment: true, on: encoder)
        encoder.endEncoding()
        let readback = try XCTUnwrap(device.makeBuffer(length: 32, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 4, height: 2, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: 16, destinationBytesPerImage: 32)
        blit.endEncoding()
        command.commit()
        await command.completed()
        XCTAssertNil(command.error)
        return Array(UnsafeBufferPointer(start: readback.contents().assumingMemoryBound(to: Float.self), count: 8))
    }

    func shadowInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        let original: WPEParityProgramAssets
        do { (_, original) = try sceneInputs() } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(
                domain: "WPEParityShadowProductTests.RequiredInputs", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "required captured scene and original WPE asset sources: \(error)"]
            ))
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath().standardizedFileURL
        let tools = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"].map { path in
            let url = contents.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
            _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil, "required bundle component \(url)")
            return url
        }
        let compiler = try WPEParityHelperShaderCompiler(helper: tools[0], dxcompiler: tools[1], metalIRConverter: tools[2],
                                                         workDirectory: scratch.appending(path: "shadow-shaderc"))
        return (WPEParityProgramAssets(sources: [.directory(scratch)] + original.sources), compiler)
    }

    func testShadowPlannerPreparesCastersAndComparisonReceivers() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (assets, compiler) = try shadowInputs()
        let document = try writeShadowScene()
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(
            cachesURL: scratch.appending(path: "planner-cache")
        ))
        let factory = WPEParityPipelineFactory(device: device)
        for quality: Int32 in [2, 0] {
            let plan = try WPEParityFramePlan(document: document, assets: assets,
                                              settings: .init(bloom: false, shadowQuality: quality), width: 64, height: 64)
            XCTAssertTrue(plan.skipped.isEmpty, "quality \(quality): \(plan.skipped)")
            var planner = WPEParityFrameDrawPlanner(device: device, factory: factory, plan: plan)
            var casters = 0
            var floor: WPEParityFrameDrawPlan?
            for (index, program) in plan.programs.sorted(by: { $0.key < $1.key }) {
                guard case let .scene(draw)? = plan.frames[0].draws[index] else { continue }
                let artifact = try await store.artifact(for: WPEParityShaderCompileRequest(
                    program: program.hlsl, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1
                ))
                let made: WPEParityFrameDrawPlan
                do throws(WPEParityFrameSkip) {
                    made = try planner.makePlan(index, artifact: artifact, state: plan.state)
                } catch {
                    // Rethrown untyped from this async test, the skip reaches XCTest as an unrelated NSError.
                    return XCTFail("quality \(quality) operation \(index): \(error)")
                }
                if draw.target == WPEParitySceneResource.shadowAtlas {
                    XCTAssertEqual(made.rasterizer.cullMode, .none)
                    XCTAssertEqual(made.rasterizer.slopeScaledDepthBias, -4)
                    casters += 1
                } else if draw.objectID == "1" {
                    floor = made
                }
            }
            let receiver = try XCTUnwrap(floor, "quality \(quality): the floor has no scene draw")
            if quality == 0 {
                XCTAssertEqual(casters, 0)
                XCTAssertFalse(receiver.pipeline.fragment.reflection.resources.contains { $0.name == "g_Texture6" })
                continue
            }
            XCTAssertEqual(casters, 2, "floor and blocker each cast one sub-mesh")
            XCTAssertEqual(receiver.samplers["g_Texture6SamplerComparisonState"], .wpeComparison())
            for textures in receiver.textures {
                XCTAssertNoThrow(try WPEParityDrawEncoder(factory: factory).prepare(
                    pipeline: receiver.pipeline, depthStencil: receiver.depthStencil,
                    textureNames: Set(textures.keys), samplers: receiver.samplers
                ))
            }
            try planner.fillImportedImages()
            XCTAssertNil(planner.layerImages[WPEParitySceneResource.shadowAtlas])
        }
    }

    /// Ortho 64×64: a 64×64 floor (object 1) at z 0 centred on (32, 32) and an 8×8 blocker (object 2) at z 10 centred
    /// on (32, 36). The spot at (8, 32, 30) looks down its x axis, which angles y 0.695 turns to (0.77, 0, -0.64), so
    /// the blocker's shadow falls on open floor at x 38...50, y 32...44, on one side of the light's y = 32 plane.
    func writeShadowScene(blockerCastsShadow: Bool = true) throws -> WPESceneDocument {
        for directory in ["models", "materials"] {
            try FileManager.default.createDirectory(at: scratch.appending(path: directory),
                                                    withIntermediateDirectories: true)
        }
        let material: [String: Any] = ["passes": [["shader": "generic4", "blending": "normal",
                                                   "textures": ["util/white"], "combos": ["LIGHTING": 1]]]]
        try JSONSerialization.data(withJSONObject: material).write(to: scratch.appending(path: "materials/shadowtest.json"))
        try Self.shadowQuad(halfSize: 32).write(to: scratch.appending(path: "models/floor.mdl"))
        try Self.shadowQuad(halfSize: 4).write(to: scratch.appending(path: "models/blocker.mdl"))
        let scene: [String: Any] = [
            "camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64],
                        "lightconfig": ["spot": 1, "spotshadow": 1],
                        "ambientcolor": "0 0 0", "skylightcolor": "0 0 0", "clearenabled": true,
                        "clearcolor": "0 0 0", "camerashake": false, "cameraparallax": false],
            "objects": [
                ["id": 1, "name": "floor", "image": "models/floor.mdl", "origin": "32 32 0"],
                ["id": 2, "name": "blocker", "image": "models/blocker.mdl", "origin": "32 36 10",
                 "castshadow": blockerCastsShadow ? 1 : 0],
                ["id": 3, "light": "lspot", "origin": "8 32 30", "angles": "0 0.695 0", "color": "1 1 1",
                 "intensity": 6, "radius": 200, "innercone": 30, "outercone": 45, "castshadow": true],
            ],
        ]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene), userValues: [:],
                                                makeTransformScriptResolver: { _, _ in NoScripts() })
    }

    /// MDLV0016 static model: one materials/shadowtest.json sub-mesh, a z = 0 quad with +z normals in the 0x0F
    /// layout (position, normal, tangent vec4, uv).
    private static func shadowQuad(halfSize s: Float) -> Data {
        var data = Data("MDLV0016".utf8)
        func append(_ words: [UInt32]) {
            for word in words {
                withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        append([0x0F00])
        data.append(0)
        append([1, 1])
        data.append(contentsOf: Array("materials/shadowtest.json".utf8) + [0])
        append([0, 0x0F])
        let corners: [(Float, Float, Float, Float)] = [(-s, -s, 0, 1), (s, -s, 1, 1), (-s, s, 0, 0), (s, s, 1, 0)]
        append([UInt32(corners.count * 12 * 4)])
        for (x, y, u, v) in corners {
            append([x, y, 0, 0, 0, 1, 1, 0, 0, 1, u, v].map(\.bitPattern))
        }
        let indices: [UInt16] = [0, 1, 2, 2, 1, 3]
        append([UInt32(indices.count * 2)])
        for index in indices {
            withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testSpotShadowDarkensTheFloorBehindACaster() async throws {
        let shadowed = try await renderShadowProbes(blockerCastsShadow: true)
        for (size, probe) in shadowed {
            XCTAssertGreaterThan(probe.open, 64, "\(size)×\(size): the open floor probe is not lit")
            XCTAssertLessThan(Double(probe.inside), Double(probe.open) * 0.75,
                              "\(size)×\(size): the blocker's shadow did not darken the floor \(probe)")
        }
        for (size, probe) in try await renderShadowProbes(blockerCastsShadow: false) {
            XCTAssertLessThanOrEqual(abs(probe.inside - probe.open), 2,
                                     "\(size)×\(size): mirrored floor pixels differ without a caster \(probe)")
        }
    }

    /// Red of the floor pixels at (44.25, 40.25), inside the blocker's shadow, and its mirror (44.25, 23.75) across
    /// the light's y = 32 plane, at 64×64 and after a replan to 128×128.
    private func renderShadowProbes(
        blockerCastsShadow: Bool, settings: WPEParityProgramSettings = .init(bloom: false, shadowQuality: 2)
    ) async throws -> [(Int, (inside: Int, open: Int))] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "required product GPU")
        let (assets, compiler) = try shadowInputs()
        let document = try writeShadowScene(blockerCastsShadow: blockerCastsShadow)
        let defaults = UserDefaults.appScoped()
        _ = try XCTUnwrap(defaults !== UserDefaults.standard ? true : nil, "required isolated product defaults")
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let saved = defaults.object(forKey: key)
        defaults.set(1.0, forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: document, assets: assets, settings: settings,
                              drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm,
                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
        XCTAssertNil(driver.loadDiagnostics)
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm
        layer.colorspace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        layer.framebufferOnly = false
        var probes: [(Int, (inside: Int, open: Int))] = []
        for size in [64, 128] {
            if size != 64 {
                driver.updateSurfaceGeometry(drawableSize: CGSize(width: size, height: size))
                let replanned = await driver.replan()
                XCTAssertTrue(replanned)
            }
            layer.drawableSize = CGSize(width: size, height: size)
            for frame in 1 ... 2 {
                try await present(driver, layer: layer, label: "shadow \(size) frame \(frame)")
            }
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            if settings.shadowQuality != 0 {
                try assertShadowDraws(renderer, casters: blockerCastsShadow ? 2 : 1)
            }
            let pixels = try readBack(XCTUnwrap(layer.lastTexture), device: device)
            let scale = Double(size) / 64
            func red(_ x: Double, _ y: Double) -> Int {
                Int(pixels[(Int((64 - y) * scale) * size + Int(x * scale)) * 4])
            }
            probes.append((size, (inside: red(44.25, 40.25), open: red(44.25, 23.75))))
        }
        return probes
    }

    /// One instanced caster draw per batch into the live atlas, in render passes of their own, and a receiver that
    /// samples that atlas with its live texel size.
    private func assertShadowDraws(_ renderer: WPEParityFrameRenderer, casters: Int) throws {
        let atlas = try XCTUnwrap(renderer.renderTarget(WPEParitySceneResource.shadowAtlas), "no live shadow atlas")
        XCTAssertEqual(atlas.pixelFormat, .depth32Float)
        let layout = try XCTUnwrap(renderer.shadowLayout)
        XCTAssertEqual([atlas.width, atlas.height], [layout.atlasSize.x, layout.atlasSize.y])
        XCTAssertFalse(layout.batches.isEmpty)
        let frame = try XCTUnwrap(renderer.frames.first)
        var casterDraws: [WPEParityDraw] = []
        var floor: WPEParityDraw?
        for (operation, draw) in renderer.lastFrameDraws {
            guard case let .scene(description)? = frame.draws[operation] else { continue }
            if description.target == WPEParitySceneResource.shadowAtlas {
                casterDraws.append(draw)
            } else if description.objectID == "1" {
                floor = draw
            } else {
                XCTAssertTrue(draw.viewports.isEmpty, "only caster draws may set viewports")
            }
        }
        XCTAssertEqual(casterDraws.count, casters * layout.batches.count, "one caster draw per batch")
        for (index, draw) in casterDraws.enumerated() {
            let batch = layout.batches[index % layout.batches.count]
            XCTAssertEqual(draw.instanceCount, batch.count)
            XCTAssertEqual(draw.viewports.map { [$0.originX, $0.originY, $0.width, $0.height, $0.znear, $0.zfar] },
                           batch.map { [Double($0.viewport.x), Double($0.viewport.y), Double($0.viewport.width),
                                        Double($0.viewport.height), 0, 1] })
            XCTAssertEqual(Self.floats(draw.constants[.vertex]?["g_ViewportViewProjectionMatrices"]),
                           Self.floats(.array(batch.map { .wpeTransposed($0.viewProjection) })))
        }
        let receiver = try XCTUnwrap(floor, "the floor has no scene draw")
        let bound = try XCTUnwrap(receiver.textures["g_Texture6"])
        XCTAssertTrue(bound === atlas, "the floor must sample the live atlas")
        let (width, height) = (Float(atlas.width), Float(atlas.height))
        XCTAssertEqual(Self.floats(receiver.constants[.fragment]?["g_Texture6Texel"]), [1 / width, 1 / height, width, height])
        // Viewports set by a caster stay on its encoder, so no other draw may share a render pass with the casters.
        for graph in renderer.compiledGraphs {
            for step in graph.steps {
                guard let encoder = step.encoder else { continue }
                let drawPasses = step.operations.compactMap { operation -> WPEPassIdentity? in
                    guard case .draw = graph.operations[operation].kind else { return nil }
                    return graph.operations[operation].pass
                }
                let casterPasses = drawPasses.filter { $0.rawValue.contains("/shadow/") }
                guard encoder.depthAttachment?.subresource.resource == WPEParitySceneResource.shadowAtlas
                    || !casterPasses.isEmpty else { continue }
                XCTAssertTrue(encoder.colorAttachments.isEmpty)
                XCTAssertEqual(encoder.depthAttachment?.subresource.resource, WPEParitySceneResource.shadowAtlas)
                XCTAssertEqual(casterPasses, drawPasses, "a non-caster draw shares the casters' render pass")
            }
        }
    }

    private static func floats(_ value: WPECBufferValue?) -> [Float]? {
        switch value {
        case let .vector(values)?: values
        case let .matrix(matrix)?: matrix.columns.flatMap(\.self)
        case let .array(values)?: values.flatMap { floats($0) ?? [.nan] }
        default: nil
        }
    }

    /// An absent general.shadows reads as quality 2 (14010efb0.c:120-153), so default settings draw shadows.
    func testDefaultSettingsDrawShadows() async throws {
        for (size, probe) in try await renderShadowProbes(blockerCastsShadow: true, settings: .init(bloom: false)) {
            XCTAssertGreaterThan(probe.open, 64, "\(size)×\(size): the open floor probe is not lit")
            XCTAssertLessThan(Double(probe.inside), Double(probe.open) * 0.75,
                              "\(size)×\(size): default settings drew no shadow \(probe)")
        }
        let off = try await renderShadowProbes(blockerCastsShadow: true, settings: .init(bloom: false, shadowQuality: 0))
        for (size, probe) in off {
            XCTAssertLessThanOrEqual(abs(probe.inside - probe.open), 2,
                                     "\(size)×\(size): shadow quality 0 still darkens the floor \(probe)")
        }
    }
}
#endif
