#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// Shipped IModelData -> binding registration -> real loader -> canonical State -> original shader/Metal.
    /// The large triangle actually addresses vertices 65536...65538; an R16 truncation draws only degenerate data.
    func testRegisteredModelDataConsumesWideIndicesUpdatesPrefixesAndRetainsSubmittedVersions() async throws {
        let source = #"""
        const material = engine.registerAsset('materials/model-data.json', true);
        const other = engine.registerAsset('materials/model-other.json', true);
        const normal = engine.registerAsset('materials/model-normal.json', true);
        let model, layer, wide, small, tick = 0, resizes = 0;
        function vertex(x,y) { return [x,y,0,0.5,0.5]; }
        function shape(vertices, indices) {
          return {vertexBuffer:vertices,indexBuffer:indices,vertexFormat:[IModelData.POSITION,IModelData.UV],
            material:material,isVertexBufferDynamic:true,isIndexBufferDynamic:true};
        }
        export function init(value) {
          wide = new Float32Array(65539 * 5);
          wide.set(vertex(-4,-4),65536*5); wide.set(vertex(4,-4),65537*5); wide.set(vertex(0,4),65538*5);
          small = new Float32Array([...vertex(-20,-4),...vertex(-12,-4),...vertex(-16,4)]);
          model = thisScene.createModelData({shapes:[shape(wide,new Uint32Array([65536,65537,65538])),
            shape(small,new Uint16Array([0,1,2]))],boundingBoxMins:new Vec3(-20,-4,0),
            boundingBoxMaxs:new Vec3(4,4,0)});
          layer = thisScene.createLayer({id:700001,name:'dynamic model',model:model,origin:'24 16 0'});
          if (!layer || thisScene.getLayer('dynamic model') !== layer) throw Error('actual model layer missing');
          return 0;
        }
        export function update(value) {
          tick += 1;
          if (tick === 2) {
            const moved = new Float32Array(wide);
            for (let i=65536;i<65539;i++) moved[i*5] += 12;
            let prefix = false;
            try { model.applyData({shapes:[{vertexBuffer:moved},{material:other}]}); }
            catch(e) { prefix = e.message === 'Material cannot be changed in IModelData.update'; }
            thisLayer.brightness = prefix ? 1 : 99;
          }
          if (tick === 5 && !thisScene.destroyLayer(layer)) throw Error('model layer destroy admission');
          return 0;
        }
        export function resizeScreen() {
          resizes += 1;
          if (resizes === 1) {
            let indexTail = false;
            try { model.replaceData({shapes:[{},
              {material:normal,indexBuffer:new Uint16Array([2,1,0])}]}); }
            catch(e) { indexTail = e.message.toLowerCase().includes('mdlv input normal0 has 0 native elements'); }
            model.replaceData({shapes:[{}, {material:material}]});
            const moved = new Float32Array(small);
            for (let i=0;i<3;i++) moved[i*5] += 2;
            let indexError = false;
            try { model.replaceData({shapes:[{},
              {material:normal,vertexBuffer:moved,indexBuffer:new Uint32Array([0,1,2])}]}); }
            catch(e) {
              if (e.message !== 'Incorrect index buffer type') throw e;
              indexError = true;
            }
            thisLayer.brightness = indexTail && indexError ? 2 : 99;
            return;
          }
          model.replaceData({shapes:[{vertexBuffer:new Float32Array([8,-4,0,0,0,1,.5,.5,
            16,-4,0,0,0,1,.5,.5,12,4,0,0,0,1,.5,.5]),
            indexBuffer:new Uint16Array([0,1,2]),
            vertexFormat:[IModelData.POSITION,IModelData.NORMAL,IModelData.UV],material:material},
            {material:material}]});
          thisScene.destroyModelData(model.__modelDataToken);
        }
        """#
        let fixture = try modelDataFixture(script: source)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler, diskCache: .init(cachesURL: scratch.appending(path: "model-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 48, height: 32)
        layer.framebufferOnly = false
        do {
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertNotNil(renderer.state.object("700001"))
            let event = try XCTUnwrap(device.makeSharedEvent())
            defer { event.signaledValue = 1 }
            let queue = driver.executor.textureSourceCommandQueue
            let blocked = try XCTUnwrap(queue.makeCommandBuffer())
            blocked.encodeWaitForEvent(event, value: 1)
            blocked.commit()
            let first = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
            XCTAssertTrue(first.retainedReferences)
            weak var oldVertices: MTLBuffer?
            var oldIndices: MTLBuffer?
            var oldPipeline: MTLRenderPipelineState?
            do {
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first { item in
                    guard item.draw.indexCount == 3, let indices = item.draw.indexBuffer, indices.length >= 12 else { return false }
                    let values = indices.contents().assumingMemoryBound(to: UInt32.self)
                    return Array(UnsafeBufferPointer(start: values, count: 3)) == [65536, 65537, 65538]
                }?.draw)
                oldVertices = draw.vertexBuffer
                oldIndices = draw.indexBuffer
                oldPipeline = draw.pipeline.state
                XCTAssertEqual(draw.pipeline.vertex.reflection.vertexInputs.sorted { $0.index < $1.index }.map(\.columns), [3, 2])
            }
            let snapshot = try modelDataSnapshot(renderer.backbuffer, device: device, queue: queue)
            let pipelineCreations = renderer.pipelineCreations
            let graphExecutors = renderer.graphExecutorIdentities
            let materialReads = fixture.reads.count("materials/model-data.json")
            let shaderReads = fixture.reads.shaderCount
            let second = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100.1, pointer: .zero))
            XCTAssertEqual(try XCTUnwrap(renderer.state.object("1")).brightness, 1)
            let nextDraw = try XCTUnwrap(renderer.lastFrameDraws.first { $0.draw.indexBuffer === oldIndices }?.draw)
            XCTAssertTrue(nextDraw.pipeline.state === oldPipeline, "an equal-layout buffer write must keep the actual PSO")
            XCTAssertEqual(renderer.pipelineCreations, pipelineCreations)
            XCTAssertEqual(renderer.graphExecutorIdentities, graphExecutors,
                           "a same-layout prefix update must retain the existing compiled graph executors")
            XCTAssertEqual(fixture.reads.count("materials/model-data.json"), materialReads)
            XCTAssertEqual(fixture.reads.shaderCount, shaderReads,
                           "a vertex update must not repeat material/HLSL planning")
            XCTAssertNotEqual(ObjectIdentifier(nextDraw.vertexBuffer), try ObjectIdentifier(XCTUnwrap(oldVertices)))
            XCTAssertEqual(try XCTUnwrap(oldVertices).contents().assumingMemoryBound(to: Float.self)[65536 * 5], -4,
                           "a pending GPU reader must retain the old immutable vertex version")
            event.signaledValue = 1
            await first.completed()
            await snapshot.command.completed()
            await second.completed()
            try await settle(driver, label: "ModelData immutable versions")
            XCTAssertNil(first.error)
            XCTAssertNil(second.error)
            let original = try readBack(snapshot.texture, device: device)
            modelDataPixel(original, width: 48, x: 24, y: 16, white: true)
            modelDataPixel(original, width: 48, x: 36, y: 16, white: false)
            let updated = try readBack(renderer.backbuffer, device: device)
            modelDataPixel(updated, width: 48, x: 24, y: 16, white: false)
            modelDataPixel(updated, width: 48, x: 36, y: 16, white: true)
            modelDataPixel(updated, width: 48, x: 8, y: 16, white: true)
        }
        weak var previous = driver.renderer
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 96, height: 64))
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertNil(previous, "the Engine callback must not keep a replaced renderer alive")
        layer.drawableSize = CGSize(width: 96, height: 64)
        do {
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertEqual(try XCTUnwrap(renderer.state.object("1")).brightness, 2,
                           "new material reflection must not preempt the later native index-width error")
            let token = try XCTUnwrap(renderer.state.object("700001")?.modelDataToken)
            let committed = try XCTUnwrap(renderer.state.modelData(token)?.shapes[1])
            XCTAssertEqual(committed.vertices.data.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }, -18,
                           "the VB prefix commits before the later index-width error and material tail observer")
            XCTAssertEqual(committed.indices?.elementWidth, .uint16)
            XCTAssertEqual(committed.indices?.data, Data([2, 0, 1, 0, 0, 0]),
                           "an earlier same-width IB prefix commits before its new material observer fails")
            XCTAssertEqual(String(data: committed.material, encoding: .utf8), "materials/model-normal.json")
            XCTAssertNil(committed.prepared, "a failing tail material observer leaves an explicit no-draw shape")
            do {
                _ = try renderer.scriptModelDataAdmission(committed, .material(token: token, shape: 1))
                XCTFail("the registered generic3 shader must require NORMAL absent from the actual source stream")
            } catch let error as WPEParityModelDataFailure {
                if case let .safety(reason) = error {
                    XCTAssertTrue(reason.lowercased().contains("mdlv input normal0 has 0 native elements"),
                                  "actual shader reflection: \(reason)")
                } else {
                    XCTFail("expected the qualified missing reflected input: \(error)")
                }
            }
            let third = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100.2, pointer: .zero))
            await third.completed()
            try await settle(driver, label: "ModelData material observer after index error")
            XCTAssertNil(third.error)
            let engine = try XCTUnwrap(renderer.script?.engine)
            XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
            let afterError = try readBack(renderer.backbuffer, device: device)
            modelDataPixel(afterError, width: 96, x: 72, y: 32, white: true)
            modelDataPixel(afterError, width: 96, x: 20, y: 32, white: false)
        }
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 192, height: 128))
        let restored = await driver.replan()
        XCTAssertTrue(restored)
        layer.drawableSize = CGSize(width: 192, height: 128)
        let resized = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100.3, pointer: .zero))
        await resized.completed()
        try await settle(driver, label: "ModelData replacement")
        let current = try XCTUnwrap(driver.renderer)
        XCTAssertTrue(current.skipped.isEmpty, "\(current.skipped)")
        XCTAssertEqual(try XCTUnwrap(current.script?.engine).exceptionCount, 0)
        let rebuilt = try XCTUnwrap(current.lastFrameDraws.first { item in
            item.draw.vertexCount == 3 && item.draw.indexType == .uint16
                && item.draw.vertexBuffer.contents().assumingMemoryBound(to: Float.self).pointee == 8
        }?.draw)
        XCTAssertEqual(rebuilt.indexCount, 3)
        XCTAssertEqual(rebuilt.pipeline.vertex.reflection.vertexInputs.sorted { $0.index < $1.index }.map(\.columns), [3, 2])
        let pixels = try readBack(current.backbuffer, device: device)
        modelDataPixel(pixels, width: 192, x: 144, y: 64, white: true)
        modelDataPixel(pixels, width: 192, x: 40, y: 64, white: true)
        let removed = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100.4, pointer: .zero))
        await removed.completed()
        try await settle(driver, label: "ModelData layer destruction")
        XCTAssertNil(current.state.object("700001"))
        try modelDataPixel(readBack(current.backbuffer, device: device), width: 192, x: 144, y: 64, white: false)
    }

    func testRegisteredModelMaterialFailureAbortsLoadAndStopsItsPreparedSound() async throws {
        let fixture = try modelDataFixture(script: """
        engine.registerAsset('materials/missing-model-data.json', true);
        export function init(value) { throw Error('init cannot run before missing dependency'); }
        """, withSound: true)
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        driver.setAudioMuted(true)
        do {
            try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                                  drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                                  compiler: fixture.compiler, diskCache: .init(cachesURL: scratch.appending(path: "missing-cache")),
                                  soundResolver: fixture.soundResolver)
            XCTFail("an unprepared registered material published a loaded scene")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertFalse(driver.didLoad)
        XCTAssertNil(driver.renderer)
        XCTAssertNil(driver.soundRuntime, "the failed load must stop and drop its own prepared sound")
        XCTAssertNotNil(driver.loadDiagnostics)
    }

    func testRegisteredMaterialCancellationAbortsOwnedLoadBeforeInit() async throws {
        let cancellation = ModelDataLoadCancellation()
        let fixture = try modelDataFixture(script: """
        engine.registerAsset('materials/model-data.json', true);
        export function init(value) { throw Error('cancelled dependency cannot initialize'); }
        """, withSound: true, cancellation: cancellation)
        let cacheURL = scratch.appending(path: "cancel-cache")
        // The non-Sendable driver belongs entirely to this task, including post-load checks and cleanup.
        let loading = Task<Void, Error> {
            let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            defer { driver.cleanup() }
            driver.setAudioMuted(true)
            do {
                try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                                      drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                                      compiler: fixture.compiler, diskCache: .init(cachesURL: cacheURL),
                                      soundResolver: fixture.soundResolver)
                XCTFail("the cancelled dependency load published a scene")
            } catch {
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertFalse(driver.didLoad)
            XCTAssertNil(driver.renderer)
            XCTAssertNil(driver.soundRuntime)
            XCTAssertNil(driver.loadDiagnostics, "cancellation must not become a renderer failure")
        }
        cancellation.install(loading)
        try await loading.value
        XCTAssertTrue(cancellation.observed, "the real registered material reader must reach the cancellation boundary")
    }

    private struct ModelDataFixture {
        let document: WPESceneDocument
        let assets: WPEParityProgramAssets
        let compiler: WPEParityHelperShaderCompiler
        let soundResolver: WPEMultiRootResourceResolver?
        let reads: ModelDataAssetReads
    }

    private func modelDataFixture(script: String, withSound: Bool = false,
                                  cancellation: ModelDataLoadCancellation? = nil) throws -> ModelDataFixture {
        let original: WPEParityProgramAssets
        do {
            original = try sceneInputs(sceneID: withSound ? "3509243656" : "3815666789").1
        } catch {
            throw NSError(domain: "ModelData.RequiredOriginal", code: 1)
        }
        for (path, expected) in [
            ("scripts/jsclasses/baseclasses.js", "708e6636167f0456eebf3ba05274d7b7763d17dfbd44c2711dc3d6d98f0cb294"),
            ("shaders/genericimage2.vert", "97370dbb18746d61629edf77ee2c30afe07605f5270f8a29a406b414932368bb"),
            ("shaders/common.h", "acf56edaeca256e6d40b4fc29ababe1f9742197300c418589137911bc8f82ed1"),
            ("shaders/common_blending.h", "f1cf5473991614784a7feafbd34c65b83a27851bfe9d763ca9c8c3fcbb2dcc6b"),
            ("shaders/common_pbr.h", "7a542df2279b6637d4f67434087df485b68ad24e06f85490d6ce424118c68d8d"),
            ("shaders/common_vertex.h", "cd4a005c0726603d613f97c8ebf9ff0a10d80f4f183de255f70bdecdb2d17ef9"),
            ("shaders/common_fragment.h", "811378cbaffd98be2800eb820d04c707d471b1cd360d6f295855a4e656e97fe4"),
            ("shaders/genericimage2.frag", "1e252e2271cae57fcfdecf3bd79d1685bb726e1e8afe09ba863dca2e1b12d68e"),
            ("shaders/generic3.vert", "258fe7388cc25aa6467a0747f4cb6f113c16d2a8829249aabba2a271c47b3305"),
            ("shaders/generic3.frag", "ff2d9f8ece1f21aea8f01136d8cfaefa05d4fef8f6cba8d7905f1422f69cd429"),
            ("materials/util/white.tex", "ac8a6c0726bf5744e816300278cf42bbe660ea885088e77bbbfb136725a26bdd"),
        ] {
            let bytes = try XCTUnwrap(original.data(path), path)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), expected, path)
        }
        let keys = ["WPE_SHADERC", "WPE_DXCOMPILER", "WPE_METALIRCONVERTER", "TEST_RUNNER_WPE_SHADERC",
                    "TEST_RUNNER_WPE_DXCOMPILER", "TEST_RUNNER_WPE_METALIRCONVERTER"]
        XCTAssertTrue(keys.allSatisfy { ProcessInfo.processInfo.environment[$0] == nil })
        let compiler: WPEParityHelperShaderCompiler
        switch WPEParityShaderToolchain.makeCompiler() {
        case let .success(value): compiler = value
        case let .failure(error): throw NSError(domain: "ModelData.RequiredBundleCompiler", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: "\(error)"])
        }
        let contents = Bundle.main.bundleURL.appending(path: "Contents").resolvingSymlinksInPath()
        let hashes = try ["MacOS/wpe-shaderc", "Frameworks/libdxcompiler.dylib", "Frameworks/libmetalirconverter.dylib"]
            .map { path in
                let url = contents.appending(path: path).resolvingSymlinksInPath()
                _ = try XCTUnwrap(url.path.hasPrefix(contents.path + "/") ? true : nil,
                                  "required compiler component must resolve inside the current app bundle")
                return SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            }
        XCTAssertEqual(compiler.compilerIdentity, "wpe-shaderc " + hashes.joined(separator: " "))
        print("ModelData compilerOrigin=current-app-bundle compilerIdentity=\(compiler.compilerIdentity)")
        let materialJSON: [String: Any] = ["passes": [["shader": "genericimage2",
                                                       "textures": ["util/white"], "blending": "normal", "cullmode": "nocull",
                                                       "depthtest": "disabled", "depthwrite": "disabled"]]]
        let material = try JSONSerialization.data(withJSONObject: materialJSON, options: [.sortedKeys])
        let normalJSON: [String: Any] = ["passes": [["shader": "generic3", "textures": ["util/white"],
                                                     "blending": "normal", "cullmode": "nocull",
                                                     "depthtest": "disabled", "depthwrite": "disabled"]]]
        let normalMaterial = try JSONSerialization.data(withJSONObject: normalJSON, options: [.sortedKeys])
        let files = ["materials/model-data.json": material, "materials/model-other.json": material,
                     "materials/model-normal.json": normalMaterial]
        let reads = ModelDataAssetReads()
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { path in
            reads.record(path)
            if path == "materials/model-data.json" {
                cancellation?.reached()
            }
            return files[path]
        }] + original.sources)
        var objects: [[String: Any]] = [["id": 1, "name": "controller", "image": "models/util/solidlayer.json",
                                         "size": "1 1", "alpha": ["value": 0, "script": script]]]
        var soundResolver: WPEMultiRootResourceResolver?
        if withSound {
            let directory = try XCTUnwrap(TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR"))
                .appending(path: "scene-sources/3509243656")
            let source = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "scene.json"))) as? [String: Any])
            let entries = try XCTUnwrap(source["objects"] as? [[String: Any]])
            let sounds = entries.filter { $0["sound"] != nil }
            XCTAssertEqual(sounds.count, 1)
            objects += sounds
            soundResolver = WPEMultiRootResourceResolver(primaryRootURL: directory, dependencyMounts: [])
        }
        let data = try JSONSerialization.data(withJSONObject: ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                                               "general": ["orthogonalprojection": ["width": 48, "height": 32, "auto": true], "clearcolor": "0 0 0", "bloom": false],
                                                               "objects": objects], options: [.sortedKeys])
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        if withSound {
            let sound = try XCTUnwrap(document.soundObjects.first)
            let resolver = try XCTUnwrap(soundResolver)
            XCTAssertEqual(document.soundObjects.count, 1)
            XCTAssertTrue(sound.visible)
            XCTAssertFalse(sound.startSilent)
            XCTAssertFalse(sound.soundRelativePaths.isEmpty)
            for path in sound.soundRelativePaths {
                _ = try resolver.resolveExistingFileURL(relativePath: path)
            }
        }
        print("ModelData scene SHA256=\(SHA256.hash(data: data))")
        print("ModelData material SHA256=\(SHA256.hash(data: material))")
        print("ModelData material observer input SHA256=\(SHA256.hash(data: normalMaterial))")
        return .init(document: document, assets: assets, compiler: compiler, soundResolver: soundResolver, reads: reads)
    }

    private func modelDataSnapshot(_ source: MTLTexture, device: MTLDevice, queue: MTLCommandQueue)
        throws -> (texture: MTLTexture, command: MTLCommandBuffer) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width,
                                                                  height: source.height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        command.commit()
        return (texture, command)
    }

    private func modelDataPixel(_ pixels: [UInt8], width: Int, x: Int, y: Int, white: Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        let offset = (y * width + x) * 4
        for lane in 0 ..< 3 {
            XCTAssertLessThanOrEqual(abs(Int(pixels[offset + lane]) - (white ? 255 : 0)), 1,
                                     "pixel \(x),\(y) lane\(lane)", file: file, line: line)
        }
    }

    private final class ModelDataAssetReads: Sendable {
        private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
        func record(_ path: String) {
            counts.withLock { $0[path, default: 0] += 1 }
        }

        func count(_ path: String) -> Int {
            counts.withLock { $0[path, default: 0] }
        }

        var shaderCount: Int {
            counts.withLock { $0.filter { $0.key.hasPrefix("shaders/") }.values.reduce(0, +) }
        }
    }

    /// Cancels only the owning load when its actual previously undeclared material reader runs.
    /// The assets callback still returns the real frozen material bytes, not a fabricated successful result.
    private final class ModelDataLoadCancellation: Sendable {
        private struct State: Sendable {
            var task: Task<Void, Error>?
            var observed = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        var observed: Bool {
            state.withLock(\.observed)
        }

        func install(_ task: Task<Void, Error>) {
            let observed = state.withLock { $0.task = task; return $0.observed }
            if observed {
                task.cancel()
            }
        }

        func reached() {
            let task = state.withLock { $0.observed = true; return $0.task }
            task?.cancel()
        }
    }
}
#endif
