#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("SceneScript IModelData")
struct WPESceneScriptModelDataTests {
    private static let material = "materials/particles/emitter_00.json"

    @Test("engine.registerAsset returns a handle carrying its asset path")
    @MainActor
    func registerAssetReturnsPathHandle() throws {
        let store = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: """
        const material = engine.registerAsset('\(Self.material)', true);
        export function init() { shared.path = material.__assetPath; }
        export function update() {}
        """, shared: store)
        #expect(store.get("path") as? String == Self.material)
        withExtendedLifetime(instance) {}
    }

    @Test("A particle-format quad publishes 36 floats and 6 indices after applyData")
    @MainActor
    func particleQuadSnapshot() throws {
        let instance = try WPELayerScriptInstance(script: Self.quadScript + """
        export function init() { createQuad(); }
        export function update() {
            const v = new Float32Array(36);
            for (let i = 0; i < 36; i++) v[i] = i + 0.5;
            model.applyData({vertexBuffer: v});
        }
        """)
        let output = try #require(instance.tick())
        let model = try #require(output.created.first?.model)
        let shape = try #require(model.shapes.first)
        #expect(shape.vertexFormat == [.position, .uv, .color])
        #expect(shape.floatsPerVertex == 9)
        #expect(shape.vertices.count == 36)
        #expect(shape.vertices.last == 35.5)
        #expect(shape.indices == [0, 1, 2, 0, 2, 3])
        #expect(model.perspective == false)
    }

    @Test("createLayer accepts {model} and bare IModelData within the registered material subset")
    @MainActor
    func createLayerCarriesModelAndMaterial() throws {
        let store = WPESharedScriptState(layers: Self.parentLayers)
        let instance = try WPELayerScriptInstance(script: Self.quadScript + """
        const unregistered = engine.registerAsset('materials/particles/emitter_99.json', true);
        export function init() {
            createQuad();
            thisScene.createLayer(model);
            const stray = thisScene.createModelData({shapes: [{vertexBuffer: new Float32Array(27),
                vertexFormat: [IModelData.POSITION, IModelData.UV, IModelData.COLOR], material: unregistered}]});
            const detached = thisScene.createLayer({model: stray});
            detached.setParent(thisScene.getLayerByID('92001'), false);
            shared.ok = detached !== null;
        }
        export function update() {}
        """, shared: store, createdLayerBridge: .init(
            imagePaths: [], orderedLayerNames: [], allowsSorting: false, materialPaths: [Self.material]
        ))
        #expect(store.get("ok") as? Bool == true)
        let created = instance.initialOutput.created
        #expect(created.count == 2)
        let models = created.compactMap(\.model)
        #expect(models.count == 2)
        #expect(Set(models.map(\.modelID)).count == 1)
        #expect(models.allSatisfy { $0.shapes.first?.materialPath == Self.material })
    }

    @Test("setParent publishes the parent object id and a failed entry rolls it back")
    @MainActor
    func setParentRollsBack() throws {
        let token = WPESceneScriptInstanceLimitToken(generation: 31)
        #expect(token.prepare(.init(text: 0, layer: 1, transform: 0)))
        let store = WPESharedScriptState(sceneScriptLoadToken: token, layers: Self.parentLayers)
        let instance = try WPELayerScriptInstance(script: Self.quadScript + """
        export function init() {
            createQuad();
            layer.setParent(thisScene.getLayerByID('92001'), false);
            shared.parentName = layer.getParent().name;
        }
        export function update() {
            const extra = thisScene.createLayer({model: model, name: 'extra'});
            extra.setParent(thisScene.getLayerByID('92002'), false);
            layer.setParent(undefined);
            throw new Error('rejected entry');
        }
        """, shared: store)
        #expect(store.get("parentName") as? String == "kv1")
        #expect(instance.initialOutput.created.map(\.parentObjectID) == ["92001"])
        let output = try #require(instance.tick())
        #expect(output.created.count == 1)
        #expect(output.created.map(\.parentObjectID) == ["92001"])
        #expect(output.created.first?.model != nil)
        #expect(token.resourceSnapshot.createdLayers == 1)
    }

    @Test("replaceData throws inside update but not inside init")
    @MainActor
    func replaceDataThrowsInUpdate() throws {
        let store = WPESharedScriptState()
        let instance = try WPELayerScriptInstance(script: Self.quadScript + """
        export function init() {
            createQuad();
            model.replaceData({vertexBuffer: new Float32Array(27), indexBuffer: null});
            shared.initReplaced = true;
        }
        export function update() {
            try { model.replaceData({vertexBuffer: new Float32Array(27)}); shared.threw = false; }
            catch (error) { shared.threw = true; }
        }
        """, shared: store)
        #expect(store.get("initReplaced") as? Bool == true)
        _ = instance.tick()
        #expect(store.get("threw") as? Bool == true)
        let shape = try #require(instance.initialOutput.created.first?.model?.shapes.first)
        #expect(shape.vertices.count == 27)
        #expect(shape.indices.isEmpty)
    }

    private static let parentLayers: [WPESceneScriptLayerInfo] = [
        .init(id: "92001", name: "kv1", size: SIMD2(1920, 1080), origin: .zero, index: 0, parentName: nil),
        .init(id: "92002", name: "kv2", size: SIMD2(1920, 1080), origin: .zero, index: 1, parentName: nil),
    ]

    /// Mirrors 3798688689 particle.js createMesh: one quad in [POSITION, UV, COLOR].
    private static let quadScript = """
    const material = engine.registerAsset('\(material)', true);
    let model, layer;
    function createQuad() {
        const vertices = new Float32Array(36), indices = new Uint16Array([0, 1, 2, 0, 2, 3]);
        model = thisScene.createModelData({boundingBoxMins: new Vec3(-1800, -1600, -1), boundingBoxMaxs: new Vec3(1800, 1600, 1),
            shapes: [{vertexBuffer: vertices, indexBuffer: indices,
                vertexFormat: [IModelData.POSITION, IModelData.UV, IModelData.COLOR],
                material: material, isVertexBufferDynamic: true}]});
        layer = thisScene.createLayer({model: model, name: 'quad', origin: new Vec3(0, 0, 0), perspective: false});
    }

    """
}
#endif
