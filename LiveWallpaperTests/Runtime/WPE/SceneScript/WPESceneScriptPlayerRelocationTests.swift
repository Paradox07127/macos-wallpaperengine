#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

/// Regression coverage for workshop 2955378002, not a Windows behavior oracle.
/// The embedded metadata projection keeps the control bindings verbatim and
/// related player/parent transforms; unrelated assets, effects and bindings are omitted.
@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct WPESceneScriptPlayerRelocationTests {
    private static let referenceName = "----MUSIC PLAYER---- (DO NOT TOUCH ME)"
    private static let seeds = [
        "2442": SIMD3<Double>(541.76160, 343.36475, 0),
        "2454": SIMD3<Double>(95.58306, 343.36475, 0),
    ]

    @Test("Hidden mover with a missing reference leaves control origins intact across frames")
    func hiddenMoverRendererLoadPreservesOrigins() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        try Self.sceneData().write(to: fixture.root.appendingPathComponent("scene.json"))
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64),
            device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        try await renderer.load()
        #expect(renderer.dynamicOriginScriptInstances["2224"] != nil)
        #expect(renderer.liveLayerVisibility["2224"] == false)
        for id in Self.seeds.keys {
            let key = WPESceneScriptTransformMutationJournal.Key(objectID: id, generation: renderer.loadGeneration)
            #expect(renderer.layerTransformMutationJournal.entries[key]?.origin == nil)
        }
        for _ in 0 ..< 3 {
            _ = try renderer.renderCurrentFrame(inputs: renderer.makeFrameInputs())
            // Let completed lane jobs be consumed on the following frame.
            try await Task.sleep(for: .milliseconds(5))
            let resolved = renderer.layerTransformMutationJournal.applying(
                to: .init(origins: Self.seeds), generation: renderer.loadGeneration
            )
            for (id, seed) in Self.seeds {
                try expectOrigin(#require(resolved.origins[id]), seed)
                let live = try #require(renderer.sceneScriptSharedState?.layerTransform(id: id))
                expectOrigin(live.transform.origin ?? SIMD3(live.info.origin.x, live.info.origin.y, live.info.originZ), seed)
            }
        }
    }

    private func expectOrigin(_ actual: SIMD3<Double>, _ expected: SIMD3<Double>) {
        #expect(abs(actual.x - expected.x) < 0.00001)
        #expect(abs(actual.y - expected.y) < 0.00001)
        #expect(abs(actual.z - expected.z) < 0.00001)
    }

    private static func sceneData() throws -> Data {
        var scene = try #require(JSONSerialization.jsonObject(with: Data(metadataProjection.utf8)) as? [String: Any])
        var objects = try #require(scene["objects"] as? [[String: Any]])
        #expect(!objects.contains { $0["name"] as? String == referenceName })
        for index in objects.indices {
            // Builtin geometry avoids the workshop's external assets; the text row renders as a solid quad.
            objects[index]["image"] = "models/util/solidlayer.json"
        }
        scene["objects"] = objects
        return try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])
    }

    /// Selected raw entry metadata in original authored order. Other player bindings are omitted.
    private static let metadataProjection = #"""
    {
      "camera": {
        "center": "1195.19995 364.79999 -1.00000",
        "eye": "1195.19995 364.79999 0.00000",
        "up": "0.00000 1.00000 0.00000"
      },
      "general": { "orthogonalprojection": { "height": 2160, "width": 3840 } },
      "objects": [
        {
          "id": 3668, "name": "----MUSIC PLAYER ----", "origin": "2942.89648 1554.58691 0.00000",
          "scale": "0.88642 0.88642 0.88642", "size": "1.00000 1.00000"
        },
        { "id": 2261, "name": "--------AUTO--------------", "parallaxDepth": "0.00000 0.00000", "visible": true },
        {
          "angles": "0.00000 -0.00000 3.14159", "id": 2442, "name": "playerskip", "parent": 2261,
          "origin": {
            "script": "'use strict';\n// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '3248335727';\n// Please note: Do not remove this line or asset references may break.\n\n/**\n * @param {ICursorEvent} event\n */\nexport function cursorClick(event) {\n\tshared.skip = true;\n}\n",
            "value": "541.76160 343.36475 0.00000"
          },
          "scale": {
            "script": "'use strict';\n// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '3248335727';\n// Please note: Do not remove this line or asset references may break.\n\n/**\n * @param {Vec3} value - for property 'scale'\n * @return {Vec3} - update current property value\n */\nexport function update(value) {\n\t\n\treturn value;\n}\n",
            "value": "0.09102 0.09102 0.17083"
          },
          "size": "512.00000 512.00000",
          "visible": {
            "script": "// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '3248335727';\nexport function cursorClick(event) {\nthisScene.getLayer('dial.wav').play();\n}\n",
            "value": true
          }
        },
        {
          "angles": "0.00000 -0.00000 0.00000", "id": 2454, "name": "playerback", "parent": 2261,
          "origin": {
            "script": "'use strict';\n// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '3248335727';\n// Please note: Do not remove this line or asset references may break.\n\n/**\n * @param {Vec3} value - for property 'origin'\n * @return {Vec3} - update current property value\n */\nexport function update(value) {\n\t\n\treturn value;\n}\n\nexport function cursorClick(event) {\n\tshared.prevtrack = true;\n}\n\n",
            "value": "95.58306 343.36475 0.00000"
          },
          "scale": "0.08513 0.08513 0.11084",
          "size": "512.00000 512.00000",
          "visible": {
            "script": "// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '3248335727';\nexport function cursorClick(event) {\nthisScene.getLayer('dial.wav').play();\n}\n",
            "value": true
          }
        },
        {
          "angles": "0.00000 -0.00000 0.00000", "id": 2470, "name": "playertracknameexception", "parent": 2261,
          "origin": "624.36163 334.70486 0.00000", "scale": "0.41314 0.41314 0.41314", "size": "872.00000 176.00000"
        },
        {
          "angles": "0.00000 -0.00000 0.00000", "id": 2479, "name": "playershufflebutton", "parent": 2261,
          "origin": "1222.27283 212.90790 0.00000", "scale": "0.44686 0.44686 0.44686", "size": "150.00000 150.00000",
          "visible": true
        },
        {
          "angles": "0.00000 -0.00000 0.00000", "id": 2167, "name": "----MUSIC PLAYER ----",
          "origin": "3147.71899 1785.46436 0.00000", "scale": "0.88642 0.88642 0.88642", "size": "1.00000 1.00000"
        },
        {
          "alignment": "bottomleft", "alpha": 0.13, "angles": "0.00000 -0.00000 0.00000", "id": 2224,
          "name": "PLAYER ASSET MOVER. DRAG TO REPOSITION",
          "origin": {
            "script": "'use strict';\n// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '3248335727';\n// Please note: Do not remove this line or asset references may break.\n\n/**\n * @param {Vec3} value - for property 'origin'\n * @return {Vec3} - update current property value\n */\nexport function update(value) {\n\n\treturn value;\n}\n/**\n * @param {Vec3} value - for property 'origin'\n * @return {Vec3} - update current property value\n */\nexport function init(value) {\n\tlet origlayers = [];\n\tthisScene.enumerateLayers().map((element) => element.name.startsWith(\"player\") ? element : null).forEach((layer) => {\n\t\tif (layer != null) {\n\t\t\t//Using as reference point to align other layers\n\t\t\tlet origoffset = layer.origin.subtract(thisScene.getLayer(\"----MUSIC PLAYER---- (DO NOT TOUCH ME)\").origin);\n\t\t\tlayer.origin = thisLayer.origin;\n\t\t\tlayer.origin = layer.origin.add(origoffset);\n\n\t\t}\n\t});\n}\n",
            "value": "1260.04468 743.52643 0.00000"
          },
          "scale": "2.81488 1.27817 1.09714",
          "size": "256.00000 256.00000",
          "visible": {
            "script": "'use strict';\n// Please note: Do not remove this line or asset references may break.\nexport let __workshopId = '3248335727';\n// Please note: Do not remove this line or asset references may break.\nlet bars = []\n/**\n * @param {Boolean} value - for property 'visible'\n * @return {Boolean} - update current property value\n */\nexport function update(value) {\n\tbars.forEach((bar,x)=>{\n\t\tbar.scale = new Vec3(bar.scale.x,Math.sin(engine.runtime*2-x*5)/3+0.5,bar.scale.z);\n\t\t\n\t})\n\treturn value;\n}\n\n/**\n * @param {Vec3} value - for property 'origin'\n * @return {Vec3} - update current property value\n */\nexport function init(value) {\n\n\nreturn false;\n}\n",
            "value": false
          }
        }
      ]
    }
    """#
}
#endif
