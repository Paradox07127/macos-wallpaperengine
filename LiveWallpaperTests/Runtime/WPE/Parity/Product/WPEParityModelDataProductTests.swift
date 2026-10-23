#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import os
import QuartzCore
import XCTest

extension WPEParitySceneDriverTests {
    /// Shipped IModelData -> precache loader -> canonical State -> original shader/Metal.
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
        let fixture = try modelDataFixture(script: source, precache: ["materials/model-data.json", "materials/model-normal.json",
                                                                      "materials/model-other.json"])
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
            XCTAssertEqual(renderer.pathCamera.size, SIMD2<Float>(48, 32), "explicit camera qualifies the pixel coordinates")
            XCTAssertNotNil(renderer.instance.state.object("700001"))
            let event = try XCTUnwrap(device.makeSharedEvent())
            defer { event.signaledValue = 1 }
            let queue = driver.executor.textureSourceCommandQueue
            let blocked = try XCTUnwrap(queue.makeCommandBuffer())
            blocked.encodeWaitForEvent(event, value: 1)
            blocked.commit()
            let first = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
            XCTAssertTrue(first.retainedReferences)
            weak var oldVertices: MTLBuffer?
            weak var oldPrepared: WPEParityModelDataMetalShape?
            let modelToken = try XCTUnwrap(renderer.instance.state.object("700001")?.modelDataToken)
            oldPrepared = try XCTUnwrap(renderer.instance.state.modelData(modelToken)?.shapes.first?.prepared as? WPEParityModelDataMetalShape)
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
            XCTAssertEqual(try XCTUnwrap(renderer.instance.state.object("1")).brightness, 1)
            XCTAssertNil(oldPrepared, "the planner operation view must retire the replaced CPU/GPU wrapper")
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
        weak let previous = driver.renderer
        driver.updateSurfaceGeometry(drawableSize: CGSize(width: 96, height: 64))
        let replanned = await driver.replan()
        XCTAssertTrue(replanned)
        XCTAssertNil(previous, "the Engine callback must not keep a replaced renderer alive")
        layer.drawableSize = CGSize(width: 96, height: 64)
        do {
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertEqual(try XCTUnwrap(renderer.instance.state.object("1")).brightness, 2,
                           "new material reflection must not preempt the later native index-width error")
            let token = try XCTUnwrap(renderer.instance.state.object("700001")?.modelDataToken)
            let committed = try XCTUnwrap(renderer.instance.state.modelData(token)?.shapes[1])
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
            let engine = try XCTUnwrap(renderer.instance.script?.engine)
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
        XCTAssertEqual(try XCTUnwrap(current.instance.script?.engine).exceptionCount, 0)
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
        XCTAssertNil(current.instance.state.object("700001"))
        try modelDataPixel(readBack(current.backbuffer, device: device), width: 192, x: 144, y: 64, white: false)
    }

    /// An id-less createLayer takes the next free id; setParent onto a passthrough draws the mesh in its composite.
    func testCreatedModelLayerWithoutIDReparentedOntoComposeLayerDrawsInsideIt() async throws {
        let source = #"""
        const material = engine.registerAsset('materials/model-data.json', true);
        export function init(value) {
          const model = thisScene.createModelData({shapes:[{
            vertexBuffer:new Float32Array([-4,-4,0,0.5,0.5, 4,-4,0,0.5,0.5, 0,4,0,0.5,0.5]),
            indexBuffer:new Uint16Array([0,1,2]),vertexFormat:[IModelData.POSITION,IModelData.UV],material:material}],
            boundingBoxMins:new Vec3(-4,-4,0),boundingBoxMaxs:new Vec3(4,4,0)});
          const layer = thisScene.createLayer({model:model,name:'child',origin:new Vec3(0,0,0),perspective:false});
          layer.setParent(thisScene.getLayer('canvas'), false);
          return 0;
        }
        """#
        let fixture = try modelDataFixture(script: source, extraObjects: [[
            "id": 2, "name": "canvas", "image": "models/util/composelayer.json", "origin": "36 16 0",
            "size": "16 16", "copybackground": false,
        ]], precache: ["materials/model-data.json"])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "reparented-model-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 48, height: 32)
        layer.framebufferOnly = false
        let renderer = try XCTUnwrap(driver.renderer)
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
        await command.completed()
        try await settle(driver, label: "reparented ModelData layer")
        XCTAssertNil(command.error)
        let engine = try XCTUnwrap(renderer.instance.script?.engine)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(renderer.instance.state.parentID(of: "3"), "2")
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        let pixels = try readBack(renderer.backbuffer, device: device)
        // Canvas pixel (x, y), y up.
        modelDataPixel(pixels, width: 48, x: 36, y: 31 - 16, white: true)
        modelDataPixel(pixels, width: 48, x: 0, y: 31 - 0, white: false)
    }

    /// Same-layout applyData on a mesh inside a compose layer swaps the buffer version without re-planning the frame,
    /// and the composite shows the new vertices exactly as a full replan of the same data does.
    func testSameLayoutApplyDataInsideComposeLayerKeepsGraphsAndMatchesFullReplan() async throws {
        let source = #"""
        const material = engine.registerAsset('materials/model-data.json', true);
        let model, tick = 0;
        function triangle(x) { return new Float32Array([x-4,-4,0,0.5,0.5, x+4,-4,0,0.5,0.5, x,4,0,0.5,0.5]); }
        export function init(value) {
          model = thisScene.createModelData({shapes:[{vertexBuffer:triangle(-4),indexBuffer:new Uint16Array([0,1,2]),
            vertexFormat:[IModelData.POSITION,IModelData.UV],material:material,isVertexBufferDynamic:true}],
            boundingBoxMins:new Vec3(-8,-4,0),boundingBoxMaxs:new Vec3(8,4,0)});
          const layer = thisScene.createLayer({model:model,name:'child',origin:new Vec3(0,0,0),perspective:false});
          layer.setParent(thisScene.getLayer('canvas'), false);
          return 0;
        }
        export function update(value) {
          tick += 1;
          if (tick === 2) model.applyData({shapes:[{vertexBuffer:triangle(0)}]});
          if (tick === 3) model.applyData({shapes:[{vertexBuffer:triangle(4)}]});
          return 0;
        }
        """#
        let fixture = try modelDataFixture(script: source, extraObjects: [[
            "id": 2, "name": "canvas", "image": "models/util/composelayer.json", "origin": "36 16 0",
            "size": "16 16", "copybackground": false,
        ]], precache: ["materials/model-data.json"])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "composite-model-update-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 48, height: 32)
        layer.framebufferOnly = false
        let renderer = try XCTUnwrap(driver.renderer)
        let first = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
        await first.completed()
        XCTAssertEqual(renderer.instance.state.parentID(of: "3"), "2")
        let layouts = renderer.frameLayoutCalls
        let executors = renderer.graphExecutorIdentities
        for (index, timestamp) in [100.1, 100.2].enumerated() {
            let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: timestamp, pointer: .zero))
            await command.completed()
            XCTAssertNil(command.error)
            XCTAssertEqual(renderer.frameLayoutCalls, layouts, "applyData \(index + 1) re-planned the frame")
            XCTAssertEqual(renderer.graphExecutorIdentities, executors, "applyData \(index + 1) replaced the graphs")
        }
        try await settle(driver, label: "composite ModelData update")
        let engine = try XCTUnwrap(renderer.instance.script?.engine)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        let updated = try readBack(renderer.backbuffer, device: device)
        // Canvas pixel (x, y), y up: the triangle moved from canvas x -4 to +4.
        modelDataPixel(updated, width: 48, x: 40, y: 31 - 16, white: true)
        modelDataPixel(updated, width: 48, x: 32, y: 31 - 16, white: false)
        for size in [CGSize(width: 96, height: 64), CGSize(width: 48, height: 32)] {
            driver.updateSurfaceGeometry(drawableSize: size)
            let replanned = await driver.replan()
            XCTAssertTrue(replanned)
        }
        let replanner = try XCTUnwrap(driver.renderer)
        XCTAssertFalse(replanner === renderer)
        let replannedFrame = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100.3, pointer: .zero))
        await replannedFrame.completed()
        try await settle(driver, label: "composite ModelData full replan")
        XCTAssertNil(replannedFrame.error)
        XCTAssertEqual(try readBack(replanner.backbuffer, device: device), updated,
                       "the buffer version swap drew a different composite than a full replan of the same data")
    }

    /// The mesh is built during another object's init, so the material lookup runs on a binding that registered nothing.
    func testModelLayerUsesMaterialRegisteredByAnotherBinding() async throws {
        let source = #"""
        const material = engine.registerAsset('materials/model-data.json', true);
        shared.makeModel = () => thisScene.createModelData({boundingBoxMins:new Vec3(-4,-4,0), boundingBoxMaxs:new Vec3(4,4,0),
          shapes:[{vertexBuffer:new Float32Array([-4,-4,0,.5,.5, 4,-4,0,.5,.5, 0,4,0,.5,.5]),
          indexBuffer:new Uint16Array([0,1,2]), vertexFormat:[IModelData.POSITION, IModelData.UV], material}]});
        export function init(value) { return 0; }
        """#
        let caller = #"""
        export function init(value) {
          const layer = thisScene.createLayer({model: shared.makeModel(), name:'cross binding model',
            origin:new Vec3(24,16,0), perspective:false});
          return layer ? 0.5 : 0.25;
        }
        """#
        let fixture = try modelDataFixture(script: source, extraObjects: [[
            "id": 2, "name": "caller", "image": "models/util/solidlayer.json", "size": "1 1",
            "alpha": ["value": 0, "script": caller],
        ]], precache: ["materials/model-data.json"])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "cross-binding-model-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 48, height: 32)
        layer.framebufferOnly = false
        let renderer = try XCTUnwrap(driver.renderer)
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
        await command.completed()
        let engine = try XCTUnwrap(renderer.instance.script?.engine)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(renderer.instance.state.object("2")?.alpha, 0.5)
        XCTAssertNotNil(renderer.instance.state.object("3")?.modelDataToken)
        XCTAssertTrue(renderer.lastFrameDraws.contains { $0.draw.indexCount == 3 })
    }

    func testSingleArgumentRegisteredMaterialLoadsSceneAndDrawsCreatedModelLayer() async throws {
        let source = #"""
        const material = engine.registerAsset('materials/model-data.json');
        export function init(value) {
          const model = thisScene.createModelData({shapes:[{
            vertexBuffer:new Float32Array([-4,-4,0,0.5,0.5, 4,-4,0,0.5,0.5, 0,4,0,0.5,0.5]),
            indexBuffer:new Uint16Array([0,1,2]),vertexFormat:[IModelData.POSITION,IModelData.UV],material:material}],
            boundingBoxMins:new Vec3(-4,-4,0),boundingBoxMaxs:new Vec3(4,4,0)});
          const layer = thisScene.createLayer({id:700002,model:model,name:'unflagged',origin:'24 16 0',perspective:false});
          return layer ? 0.5 : 0.25;
        }
        """#
        let fixture = try modelDataFixture(script: source)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "unflagged-model-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 48, height: 32)
        layer.framebufferOnly = false
        let renderer = try XCTUnwrap(driver.renderer)
        let engine = try XCTUnwrap(renderer.instance.script?.engine)
        XCTAssertEqual(engine.bindings.flatMap(\.registeredAssets).map(\.flag), [false])
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
        await command.completed()
        try await settle(driver, label: "unflagged registered material")
        XCTAssertNil(command.error)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(renderer.instance.state.object("1")?.alpha, 0.5)
        let token = try XCTUnwrap(renderer.instance.state.object("700002")?.modelDataToken)
        XCTAssertNotNil(renderer.instance.state.modelData(token))
        XCTAssertTrue(renderer.lastFrameDraws.contains { $0.draw.indexCount == 3 })
        try modelDataPixel(readBack(renderer.backbuffer, device: device), width: 48, x: 24, y: 16, white: true)
    }

    func testRegisteredNonMaterialAndMissingAssetsNeitherFailLoadNorBlockInit() async throws {
        let fixture = try modelDataFixture(script: """
        if (engine.registerAsset('models/foo.mdl') !== 'models/foo.mdl') throw Error('model registration');
        if (engine.registerAsset('particles/x.json') !== 'particles/x.json') throw Error('particle registration');
        engine.registerAsset('materials/missing-model-data.json', true);
        export function init(value) { return 0.5; }
        """)
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler, diskCache: .init(cachesURL: scratch.appending(path: "registered-cache")))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        let renderer = try XCTUnwrap(driver.renderer)
        let engine = try XCTUnwrap(renderer.instance.script?.engine)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertEqual(renderer.instance.state.object("1")?.alpha, 0.5)
        for path in ["models/foo.mdl", "particles/x.json"] {
            XCTAssertEqual(fixture.reads.count(path), 0, "registration must not read \(path)")
        }
    }

    func testMissingRegisteredMaterialIsSkippedWithWarningAndInitStillRuns() async throws {
        let fixture = try modelDataFixture(script: """
        engine.registerAsset('materials/missing.json');
        engine.registerAsset('models/foo.mdl');
        export function init(value) { return 0.5; }
        """)
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "missing-registered-cache")))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.renderer?.instance.state.object("1")?.alpha, 0.5)
        XCTAssertGreaterThan(fixture.reads.count("materials/missing.json"), 0)
        XCTAssertEqual(fixture.reads.count("models/foo.mdl"), 0)
        let warnings = LogFileSink.shared.recentDiagnosticLines(maxLines: 50, maxContextLines: 0)
        XCTAssertTrue(warnings.contains { $0.contains("[WARNING]") && $0.contains("materials/missing.json") },
                      "a skipped registered material must leave a warning")
    }

    func testPrecacheMaterialPathsKeepOnlyMaterialsPrefixedStrings() throws {
        let general = try XCTUnwrap(WPESceneJSONValue(jsonValue: ["precache": [
            "materials/a.json", "models/b.json", 7, NSNull(), ["materials/nested.json"], "materialsx.json", "Materials/c.json",
        ]]))
        XCTAssertEqual(WPEParitySceneDriver.precacheMaterialPaths(general), ["materials/a.json", "materialsx.json"])
        XCTAssertEqual(WPEParitySceneDriver.precacheMaterialPaths(.object(["precache": .string("materials/a.json")])), [])
        XCTAssertEqual(WPEParitySceneDriver.precacheMaterialPaths(.object([:])), [])
    }

    func testPrecacheLoadsOnlyMaterialsEntriesAndSkipsAFailedOne() async throws {
        let fixture = try modelDataFixture(script: "export function init(value) { return 0.5; }",
                                           precache: ["models/b.json", 7, "materials/missing-model-data.json",
                                                      "materials/model-data.json"])
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler, diskCache: .init(cachesURL: scratch.appending(path: "precache-cache")))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.loadDiagnostics)
        XCTAssertEqual(driver.renderer?.instance.state.object("1")?.alpha, 0.5)
        XCTAssertGreaterThan(fixture.reads.count("materials/model-data.json"), 0)
        XCTAssertGreaterThan(fixture.reads.count("materials/missing-model-data.json"), 0)
        XCTAssertEqual(fixture.reads.count("models/b.json"), 0, "a non-materials precache entry must be skipped")
    }

    func testCreatedModelDataResolvesUnregisteredMaterialAndReportsMissingOneAsInvalid() async throws {
        let source = #"""
        const make = material => thisScene.createModelData({shapes:[{
          vertexBuffer:new Float32Array([-4,-4,0,0.5,0.5, 4,-4,0,0.5,0.5, 0,4,0,0.5,0.5]),
          indexBuffer:new Uint16Array([0,1,2]),vertexFormat:[IModelData.POSITION,IModelData.UV],material}],
          boundingBoxMins:new Vec3(-4,-4,0),boundingBoxMaxs:new Vec3(4,4,0)});
        export function init(value) {
          let missing = false;
          try { make('materials/absent.json'); } catch (e) { missing = e.message === 'Invalid material'; }
          const layer = thisScene.createLayer({id:700003,model:make('materials/model-data.json'),name:'unregistered',
            origin:'24 16 0',perspective:false});
          return layer && missing ? 0.5 : 0.25;
        }
        """#
        let fixture = try modelDataFixture(script: source, precache: ["materials/model-data.json"])
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let driver = try WPEParitySceneDriver(device: device)
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: fixture.assets, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler,
                              diskCache: .init(cachesURL: scratch.appending(path: "unregistered-model-cache")))
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm_srgb
        layer.drawableSize = CGSize(width: 48, height: 32)
        layer.framebufferOnly = false
        let renderer = try XCTUnwrap(driver.renderer)
        let engine = try XCTUnwrap(renderer.instance.script?.engine)
        XCTAssertEqual(renderer.instance.state.object("1")?.alpha, 0.5)
        let command = try XCTUnwrap(driver.renderAndPresentFrame(layer: layer, timestamp: 100, pointer: .zero))
        await command.completed()
        try await settle(driver, label: "unregistered ModelData material")
        XCTAssertNil(command.error)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
        XCTAssertTrue(renderer.lastFrameDraws.contains { $0.draw.indexCount == 3 })
        try modelDataPixel(readBack(renderer.backbuffer, device: device), width: 48, x: 24, y: 16, white: true)
    }

    func testScriptInitFailureLoadsSceneAndReportsScriptDiagnostic() async throws {
        let fixture = try modelDataFixture(script: "export function init(value) { return value; }")
        let assets = fixture.assets
        let withoutBaseClasses = WPEParityProgramAssets(sources: [.lookup(scratch) { path in
            path == "scripts/jsclasses/baseclasses.js" ? nil : assets.data(path)
        }])
        let driver = try WPEParitySceneDriver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { driver.cleanup() }
        try await driver.load(document: fixture.document, assets: withoutBaseClasses, settings: .init(bloom: false),
                              drawableSize: CGSize(width: 48, height: 32), pixelFormat: .bgra8Unorm_srgb,
                              compiler: fixture.compiler, diskCache: .init(cachesURL: scratch.appending(path: "no-base-cache")))
        XCTAssertTrue(driver.didLoad)
        XCTAssertNil(driver.renderer?.instance.script)
        guard case let .other(layer, _)? = driver.loadDiagnostics else {
            return XCTFail("script init failure is missing from the load diagnostics: \(String(describing: driver.loadDiagnostics))")
        }
        XCTAssertEqual(layer, "scripts")
    }

    func testPrecacheMaterialCancellationAbortsOwnedLoadBeforeInit() async throws {
        let cancellation = ModelDataLoadCancellation()
        let fixture = try modelDataFixture(script: """
        export function init(value) { throw Error('cancelled dependency cannot initialize'); }
        """, withSound: true, precache: ["materials/model-data.json"], cancellation: cancellation)
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
        XCTAssertTrue(cancellation.observed, "the real precache material reader must reach the cancellation boundary")
    }

    private struct ModelDataFixture {
        let document: WPESceneDocument
        let assets: WPEParityProgramAssets
        let compiler: WPEParityHelperShaderCompiler
        let soundResolver: WPEMultiRootResourceResolver?
        let reads: ModelDataAssetReads
    }

    private func modelDataFixture(script: String, withSound: Bool = false, extraObjects: [[String: Any]] = [],
                                  precache: [Any]? = nil,
                                  cancellation: ModelDataLoadCancellation? = nil) throws -> ModelDataFixture {
        let original: WPEParityProgramAssets
        do {
            original = try sceneInputs(sceneID: withSound ? "3509243656" : "3815666789").1
        } catch {
            throw TestScratch.requiredInputError(error, failure: NSError(domain: "ModelData.RequiredOriginal", code: 1))
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
                return try SHA256.hash(data: Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
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
                                         "size": "1 1", "alpha": ["value": 0, "script": script]]] + extraObjects
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
        var general: [String: Any] = ["orthogonalprojection": ["width": 48, "height": 32, "auto": false], "clearcolor": "0 0 0",
                                      "bloom": false, "supportsaudioprocessing": withSound]
        general["precache"] = precache
        let data = try JSONSerialization.data(withJSONObject: ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                                               "general": general, "objects": objects], options: [.sortedKeys])
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:])
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
