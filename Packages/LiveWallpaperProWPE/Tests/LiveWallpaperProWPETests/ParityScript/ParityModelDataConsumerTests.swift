import Foundation
@testable import LiveWallpaperProWPE
import XCTest

final class ParityModelDataConsumerTests: XCTestCase {
    /// Real shipped JS and JSC conversion reach the canonical State owner. The fixture material admission below
    /// deliberately qualifies CPU protocol only; root's actual shader/u32/last-reader product guard is separate.
    func testShippedModelAPIWritesTypedStatePreservesPrefixesAndCanonicalIdentity() throws {
        let script = #"""
        let globalGuard = false;
        try { thisScene.createModelData({}); } catch(e) { globalGuard = e.message === 'createModelData cannot be called from global scope.'; }
        let model, vertices;
        const words = new Uint32Array([0x12345678, 0x80000000,0,0, 0x3f800000,0,0, 0,0x3f800000,0, 0x87654321]);
        vertices = new Float32Array(words.buffer, 4, 9);
        const index16 = new Uint16Array([99,0,1,2,99]).subarray(1,4);
        const index32 = new Uint32Array([999,2,1,0,999]).subarray(1,4);
        function shape(indices) { return {vertexBuffer:vertices,vertexFormat:[IModelData.POSITION],indexBuffer:indices,
          material:'materials/model.json',isVertexBufferDynamic:true,isIndexBufferDynamic:true}; }
        export function init(v) {
          model = thisScene.createModelData({shapes:[shape(index16),shape(index32)],
            boundingBoxMins:{x:-10,y:-20,z:-30},boundingBoxMaxs:{x:10,y:20,z:30}});
          if (!(model instanceof IModelData) || !globalGuard) throw Error('canonical wrapper/global guard');
          if (thisScene.destroyModelData(model) !== undefined) throw Error('wrapper destroy void');
          model.__modelDataToken = 999;
          if (model.toConfigString() !== 999) throw Error('shipped serialization');
          thisScene.createLayer(model);
          thisScene.createLayer({model,name:'serialized'});
          const patch = new Float32Array(vertices);
          patch[0] = 7;
          let width = false;
          try { model.applyData({vertexBuffer:patch,indexBuffer:index32}); }
          catch(e) { width = e.message === 'Incorrect index buffer type'; }
          if (!width) throw Error('width error');
          patch[0] = 8;
          let prefix = false;
          try { model.applyData({shapes:[{vertexBuffer:patch},{material:'materials/other.json'}]}); }
          catch(e) { prefix = e.message === 'Material cannot be changed in IModelData.update'; }
          if (!prefix) throw Error('ordered prefix');
          model.applyData({get vertexBuffer() {
            if (!thisScene.sortLayer(thisLayer,0)) throw Error('reentrant scene mutation');
            return patch;
          }});
          const marker = {tag:'getter-identity'};
          patch[0] = 9;
          let exact = false;
          try { model.applyData({shapes:[{vertexBuffer:patch},{get vertexBuffer(){throw marker;}}]}); }
          catch(e) { exact = e === marker; }
          if (!exact) throw Error('getter identity');
          let shortView = false;
          try { model.applyData({vertexBuffer:patch.subarray(0,6)}); }
          catch(e) { shortView = e.message.indexOf('ModelData safety admission:') === 0; }
          if (!shortView) throw Error('short-view admission');
          shared.model = model;
          return 1;
        }
        export function update(v) {
          let blocked = false;
          try { model.replaceData({}); }
          catch(e) { blocked = e.message === 'IModelData.replace cannot be called in update.'; }
          return blocked ? 2 : 99;
        }
        export function resizeScreen() {
          const patch = new Float32Array(vertices);
          new Uint32Array(patch.buffer)[8] = 0x7fc12345;
          model.replaceData({vertexBuffer:patch,vertexFormat:[IModelData.POSITION],indexBuffer:null,
            material:'',boundingBoxMins:{x:0},boundingBoxMaxs:{x:0}});
          let appended = false;
          try { model.replaceData({shapes:[{}, {}, {vertexBuffer:vertices,vertexFormat:[IModelData.POSITION],
            material:'materials/other.json'}]}); }
          catch(e) { appended = e.message === 'Invalid material'; }
          if (!appended) throw Error('append resource error');
        }
        export function destroy() { model.replaceData({shapes:[null]}); thisScene.destroyModelData(1); }
        """#
        let document = try Self.document(script)
        var state = WPEParitySceneState(document: document, hdr: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/ParityScript/baseclasses.js")
        let baseClasses = try Data(contentsOf: fixture)
        let assets = WPEParityProgramAssets(sources: [.lookup(fixture.deletingLastPathComponent()) { path in
            path == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        var serialized: [[String: Any]] = []
        var paths: [String] = []
        let provider = WPEParityScriptModelDataProvider(
            maximumArrayEntries: 16, maximumBufferBytes: 4096,
            resolveMaterial: { value, context in
                paths.append(context?.modulePath ?? "")
                return try Data(XCTUnwrap(value.toString()).utf8)
            },
            admitShape: { shape, _ in
                guard shape.material == Data("materials/model.json".utf8) else { throw WPEParityModelDataFailure.native(1) }
                guard shape.vertices.layout.format & 1 != 0 else { throw WPEParityModelDataFailure.native(2) }
                XCTAssertEqual(shape.vertices.data.count % shape.vertices.layout.stride, 0)
                return nil // This guard deliberately admits only CPU values, not a Metal draw resource.
            }
        )
        let engine = try WPEParityScriptEngine(document: document, state: state, configuration: .init(
            assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64), modelData: provider,
            createLayer: { text, _ in
                do {
                    let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
                    if let object = value as? [String: Any] {
                        serialized.append(object)
                    } else {
                        XCTFail("Expected a serialized model object")
                    }
                } catch { XCTFail("Invalid serialized model configuration: \(error)") }
                return nil
            },
            sortLayer: { id, position, state in
                guard let position = Int32(exactly: position) else { return false }
                return state.sortObject(id, to: position)
            }
        ))
        engine.start(state: &state)
        let initial = try XCTUnwrap(state.modelData(1))
        XCTAssertEqual(initial.references, 1)
        XCTAssertEqual(initial.bounds.minimum, SIMD3(-10, -20, -30))
        XCTAssertEqual(initial.bounds.maximum, SIMD3(10, 20, 30))
        XCTAssertEqual(initial.shapes.count, 2)
        XCTAssertEqual(initial.shapes[0].vertices.data.count, 36)
        XCTAssertEqual(Self.word(initial.shapes[0].vertices.data, 0), Float(8).bitPattern)
        XCTAssertEqual(initial.shapes[0].indices?.elementWidth, .uint16)
        XCTAssertEqual(initial.shapes[0].indices?.data, Self.bytes([UInt16(0), 1, 2]))
        XCTAssertEqual(initial.shapes[1].indices?.elementWidth, .uint32)
        XCTAssertEqual(initial.shapes[1].indices?.data, Self.bytes([UInt32(2), 1, 0]))
        XCTAssertEqual(Self.word(initial.shapes[1].vertices.data, 0), 0x8000_0000)
        XCTAssertEqual(serialized.compactMap { ($0["model"] as? NSNumber)?.uint32Value }, [999, 999])
        XCTAssertTrue(paths.allSatisfy { $0 == "scripts/image_alpha.js" })
        engine.tick(dt: 1 / 60, state: &state)
        XCTAssertEqual(state.object("1")?.alpha, 2)
        engine.resize(canvasSize: SIMD2(80, 80), screenResolution: SIMD2(80, 80), state: &state)
        let replaced = try XCTUnwrap(state.modelData(1))
        XCTAssertNil(replaced.shapes[0].indices)
        XCTAssertFalse(replaced.shapes[0].isVertexBufferDynamic)
        XCTAssertFalse(replaced.shapes[0].isIndexBufferDynamic)
        XCTAssertEqual(replaced.shapes[0].material, Data("materials/model.json".utf8))
        XCTAssertEqual(replaced.shapes.count, 3, "an appended native shape precedes its resource validation error")
        XCTAssertEqual(replaced.shapes[2].material, Data("materials/other.json".utf8))
        XCTAssertEqual(Self.word(replaced.shapes[0].vertices.data, 8), 0x7FC1_2345)
        XCTAssertEqual(replaced.bounds, initial.bounds, "replacement does not recompute the initial MDL bounds")
        try state.retainModelData(1, for: "1")
        XCTAssertEqual(state.modelData(1)?.references, 2)
        engine.destroy(state: &state)
        XCTAssertEqual(state.modelData(1)?.references, 1)
        XCTAssertEqual(state.modelData(1)?.shapes.count, 2)
        XCTAssertEqual(state.modelData(1)?.shapes.first?.indices?.elementWidth, .uint32)
        state.releaseLayerModelData("1")
        XCTAssertNil(state.modelData(1))
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    private static func document(_ script: String) throws -> WPESceneDocument {
        let json: [String: Any] = ["camera": ["eye": "0 0 0", "center": "0 0 -1", "up": "0 1 0"],
                                   "general": ["orthogonalprojection": ["width": 64, "height": 64]],
                                   "objects": [["id": 1, "name": "owner", "image": "models/a.json", "size": "64 64",
                                                "alpha": ["value": 1, "script": script]]]]
        return try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                makeTransformScriptResolver: { _, _ in NoScripts() })
    }

    private static func bytes(_ values: [some Any]) -> Data {
        values.withUnsafeBytes { Data($0) }
    }

    private static func word(_ data: Data, _ index: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)) }
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
