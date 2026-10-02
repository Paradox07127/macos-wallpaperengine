import Foundation
import JavaScriptCore
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite(.serialized)
@MainActor
struct WPESceneScriptInitialLayerConfigurationTests {
    private let configuration: WPESceneJSONValue = .object([
        "id": .number(42),
        "name": .string("source"),
        "origin": .string("0.5 12 0"),
        "alpha": .object(["value": .number(0.19), "user": .string("probealpha")]),
        "unknown": .array([.null, .bool(false), .object(["nested": .number(7)])]),
    ])

    private func sharedState() -> WPESharedScriptState {
        WPESharedScriptState(layers: [
            .init(id: "42", name: "source", size: SIMD2(8, 8), origin: SIMD2(0.5, 12), index: 0,
                  parentName: nil, initialConfiguration: wpeInitialLayerConfiguration(from: configuration)),
            .init(id: "43", name: "other", size: .zero, origin: .zero, index: 1,
                  parentName: nil, initialConfiguration: .object(["name": .string("other")])),
        ])
    }

    @Test("Cloneable configuration strips only the top-level identity")
    func authoredConfigurationRemovesOnlyTopLevelID() throws {
        let source = WPESceneJSONValue.object(["id": .number(1), "parent": .number(2), "unknown": .object(["id": .number(3)])])
        let result = try #require(wpeInitialLayerConfiguration(from: source))
        #expect(result["id"] == nil)
        #expect(result["unknown"]?["id"] == .number(3))
        #expect(source["id"] == .number(1))
    }

    @Test("Script table uses logical source order and preserves configuration before property resolution")
    func scriptTablePreservesSourceProvenanceWithoutSyntheticDuplicates() throws {
        let source = #"""
        {"camera":{"center":"0 0 0"},"general":{"orthogonalprojection":{"width":64,"height":64}},
         "objects":[{"id":2,"name":"title","text":"text","origin":"8 8 0"},
                    {"id":1,"name":"image","image":"models/util/solidlayer.json","alpha":{"value":0.19,"user":"probealpha"}}]}
        """#
        let parsed = try WPESceneDocumentParser.parse(data: Data(source.utf8), userValues: ["probealpha": .number(0.37)])
        let textImage = WPESceneImageObject(id: "2", name: "title", imageRelativePath: "synthetic-text",
                                            materialRelativePath: nil, origin: .zero, scale: SIMD3(repeating: 1), angles: .zero,
                                            visible: true, alpha: 1, color: SIMD3(repeating: 1), brightness: 1,
                                            blendMode: .normal, alignment: .center, size: nil, effects: [], animationLayers: [])
        let table = WPEMetalSceneRenderer.scriptLayerTable(for: parsed.appendingImageObjects([textImage]))
        #expect(table.map(\.id) == ["2", "1"])
        #expect(table.map(\.index) == [0, 1])
        #expect(table[0].initialConfiguration?["text"] == .string("text"))
        #expect(table[1].initialConfiguration?["alpha"]?["value"] == .number(0.19))
        #expect(table[1].initialConfiguration?["alpha"]?["user"] == .string("probealpha"))
        #expect(table[1].initialConfiguration?["id"] == nil)
        #expect(parsed.imageObjects.first?.alpha == 0.37)
    }

    @Test("Configuration conversion preserves authored types and returns detached storage")
    func conversionPreservesTypesAndCopiesNestedValues() throws {
        let context = try #require(JSContext())
        let first = try #require(wpeInitialLayerConfigurationValue(configuration, in: context))
        let second = try #require(wpeInitialLayerConfigurationValue(configuration, in: context))
        context.setObject(first, forKeyedSubscript: "first" as NSString)
        context.setObject(second, forKeyedSubscript: "second" as NSString)
        #expect(context.evaluateScript("""
        first !== second && first.unknown !== second.unknown &&
        first.id === 42 && first.origin === '0.5 12 0' &&
        first.alpha.user === 'probealpha' && first.alpha.value === 0.19 &&
        first.unknown[0] === null && first.unknown[1] === false
        """)?.toBool() == true)
        context.evaluateScript("first.unknown[2].nested = 99; first.alpha.value = 0.8;")
        #expect(context.evaluateScript("second.unknown[2].nested === 7 && second.alpha.value === 0.19")?.toBool() == true)
        #expect(configuration["unknown"]?[2]?["nested"] == .number(7))
    }

    @Test("Configuration objects are independent across script contexts")
    func conversionDoesNotShareJSStorageAcrossContexts() throws {
        let firstContext = try #require(JSContext())
        let secondContext = try #require(JSContext())
        firstContext.setObject(wpeInitialLayerConfigurationValue(configuration, in: firstContext), forKeyedSubscript: "config" as NSString)
        secondContext.setObject(wpeInitialLayerConfigurationValue(configuration, in: secondContext), forKeyedSubscript: "config" as NSString)
        firstContext.evaluateScript("config.unknown[2].nested = 81")
        #expect(secondContext.evaluateScript("config.unknown[2].nested")?.toDouble() == 7)
    }

    @Test("Layer API returns authored configuration by name, index and real handle")
    func layerLookupPreservesInitialConfiguration() throws {
        let shared = sharedState()
        _ = try WPELayerScriptInstance(script: """
        export function init() {
            const a = thisScene.getInitialLayerConfig('source');
            const b = thisScene.getInitialLayerConfig(0);
            const c = thisScene.getInitialLayerConfig(thisLayer);
            shared.identities = a.name === b.name && b.name === c.name && a !== b;
            shared.noID = a.id === undefined;
            a.unknown[2].nested = 99;
            thisLayer.origin = new Vec3(70,80,90);
            thisLayer.alpha = 0.8;
            const unchanged = thisScene.getInitialLayerConfig(thisLayer);
            shared.immutable = unchanged.unknown[2].nested === 7 && unchanged.origin === '0.5 12 0';
            shared.wrapper = unchanged.alpha.user === 'probealpha' && unchanged.alpha.value === 0.19;
            shared.other = thisScene.getInitialLayerConfig(thisScene.getLayer('other')).name === 'other';
            shared.fractionalIndex = thisScene.getInitialLayerConfig(1.5).name === 'other';
            shared.coercion = [-0.5, NaN, Infinity].every(v => thisScene.getInitialLayerConfig(v).name === 'source');
            shared.invalidTypes = [null,undefined,true,false,{name:'source'}].every(v => thisScene.getInitialLayerConfig(v) === null);
            shared.invalid = thisScene.getInitialLayerConfig('missing') === null && thisScene.getInitialLayerConfig(-1) === null;
        }
        """, shared: shared, ownLayerName: "source", ownObjectID: "42")
        for key in ["identities", "noID", "immutable", "wrapper", "other", "fractionalIndex", "coercion", "invalidTypes", "invalid"] {
            #expect(shared.get(key) as? Bool == true, "\(key)")
        }
    }

    @Test("Transform and text script families expose the same configuration query")
    func transformAndTextShareConfigurationContract() throws {
        let shared = sharedState()
        let transform = try WPEDynamicTransformScriptInstance(script: """
        export function init(value) {
            shared.transformOwn = thisScene.getInitialLayerConfig(thisLayer).name === 'source';
            shared.transformIndex = thisScene.getInitialLayerConfig(1.5).name === 'other';
            return value;
        }
        """, seed: .zero, canvasSize: SIMD2(256, 128), ownLayerName: "source", ownObjectID: "42", shared: shared)
        #expect(shared.get("transformOwn") as? Bool == true)
        #expect(shared.get("transformIndex") as? Bool == true)
        _ = transform
        let text = try WPESceneScriptInstance(script: """
        export function init(value) {
            shared.textName = thisScene.getInitialLayerConfig('source').origin;
            shared.textIndex = thisScene.getInitialLayerConfig(1).name;
            return value;
        }
        """, initialValue: "seed", shared: shared)
        #expect(shared.get("textName") as? String == "0.5 12 0")
        #expect(shared.get("textIndex") as? String == "other")
        _ = text
    }

    @Test("Created configuration is detached and destruction publishes a persistent tombstone")
    func createdConfigurationAndDestructionLifetime() throws {
        let shared = sharedState()
        let instance = try WPELayerScriptInstance(script: """
        let made;
        export function init() {
            const spec = {image:'models/bar.json',name:'created',origin:new Vec3(1,2,3),marker:{n:7}};
            made = thisScene.createLayer(spec);
            spec.marker.n = 99;
            made.origin = new Vec3(40,50,60);
            shared.snapshot = thisScene.getInitialLayerConfig(made).marker.n === 7 &&
                              thisScene.getInitialLayerConfig('created').origin === '1 2 3';
            shared.destroyed = thisScene.destroyLayer(made);
            shared.repeat = thisScene.destroyLayer(made);
            shared.immediate = thisScene.getInitialLayerConfig(made).marker.n === 7 &&
                               thisScene.getInitialLayerConfig('created') === null;
            shared.authoredDestroyRejected = !thisScene.destroyLayer(thisLayer);
        }
        export function update() {
            shared.retired = thisScene.getInitialLayerConfig(made) === null &&
                             thisScene.getInitialLayerConfig('created') === null;
        }
        """, shared: shared, ownLayerName: "source", ownObjectID: "42", createdLayerBridge: .init(
            imagePaths: ["models/bar.json"], orderedLayerNames: ["source", "other"], allowsSorting: false
        ))
        #expect(shared.get("snapshot") as? Bool == true)
        #expect(shared.get("destroyed") as? Bool == true)
        #expect(shared.get("repeat") as? Bool == true)
        #expect(shared.get("immediate") as? Bool == true)
        #expect(shared.get("authoredDestroyRejected") as? Bool == true)
        #expect(instance.initialOutput.created.isEmpty)
        #expect(instance.initialOutput.destroyedCreatedKeys == ["__created_0"])
        let tick = try #require(instance.tick())
        #expect(shared.get("retired") as? Bool == false)
        #expect(tick.destroyedCreatedKeys == ["__created_0"])
        #expect(tick.created.isEmpty)
        _ = try #require(instance.tick())
        #expect(shared.get("retired") as? Bool == true)
    }

    @Test("Duplicate and empty names preserve numeric, named and own-handle identities")
    func duplicateAndEmptyNameIdentity() throws {
        let layers: [WPESceneScriptLayerInfo] = [
            .init(id: "A", name: "dup", size: .zero, origin: .zero, index: 0, parentName: nil,
                  initialConfiguration: .object(["marker": .string("A")])),
            .init(id: "B", name: "dup", size: .zero, origin: .zero, index: 1, parentName: nil,
                  initialConfiguration: .object(["marker": .string("B")])),
            .init(id: "U", name: "", size: .zero, origin: .zero, index: 2, parentName: nil,
                  initialConfiguration: .object(["marker": .string("U")])),
        ]
        let shared = WPESharedScriptState(layers: layers)
        shared.set("mutate", true)
        let script = """
        export function init(value) {
            shared.direct = thisScene.getInitialLayerConfig(0).marker === 'A' && thisScene.getInitialLayerConfig(1).marker === 'B';
            shared.handles = thisScene.getInitialLayerConfig(thisScene.getLayer(0)).marker === 'A' &&
                             thisScene.getInitialLayerConfig(thisScene.getLayer(1)).marker === 'B';
            shared.same = thisScene.getLayer('dup') === thisScene.getLayer(0) && thisScene.getLayer(1) === thisLayer;
            shared.empty = thisScene.getInitialLayerConfig('').marker === 'U' &&
                           thisScene.getInitialLayerConfig(thisScene.getLayer(2)).marker === 'U';
            if (shared.mutate) thisScene.getLayer(0).origin = new Vec3(1,2,3);
            return value;
        }
        """
        let instance = try WPELayerScriptInstance(script: script, shared: shared, ownLayerName: "dup", ownObjectID: "B")
        for key in ["direct", "handles", "same", "empty"] {
            #expect(shared.get(key) as? Bool == true, "\(key)")
        }
        #expect(instance.initialOutput.otherTransforms[wpeScriptLayerIDKey("A")]?.origin == SIMD3(1, 2, 3))
        let transformShared = WPESharedScriptState(layers: layers)
        _ = try WPEDynamicTransformScriptInstance(script: script, seed: .zero, canvasSize: SIMD2(256, 128),
                                                  ownLayerName: "dup", ownObjectID: "B", shared: transformShared)
        for key in ["direct", "handles", "same", "empty"] {
            #expect(transformShared.get(key) as? Bool == true, "\(key)")
        }
    }
}
