import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("WPE parallax binding inference")
struct WPESceneParallaxBindingInferenceTests {
    /// Workshop 3810519013 / 3811736073 shape: the author declared 镜头视差 /
    /// 鼠标影响 sliders and a parallaxDepth init() that reads
    /// `thisScene.cameraparallax*`, but the authoring tool dropped the
    /// {"user"} envelopes, so the sliders are dead even in WPE.
    private let sceneJSON: [String: Any] = [
        "camera": ["center": "1280 720 0"],
        "general": [
            "orthogonalprojection": ["width": 2560, "height": 1440, "auto": true],
            "cameraparallax": true,
            "cameraparallaxamount": 1,
            "cameraparallaxmouseinfluence": 1,
        ],
        "objects": [[
            "id": "img", "name": "img", "type": "image",
            "image": "models/util/solidlayer.json", "visible": true,
            "parallaxDepth": [
                "value": "0.8 0",
                "script": """
                export function init(value) {
                    var amount = Math.max(thisScene.cameraparallaxamount, 0.0001);
                    var influence = Math.max(Math.abs(thisScene.cameraparallaxmouseinfluence), 0.0001);
                    var padX = thisLayer.size.x * thisLayer.scale.x - engine.canvasSize.x;
                    return new Vec2(padX > 1 ? padX / (engine.canvasSize.x * amount * influence) : 0, 0);
                }
                """,
            ],
        ]],
    ]

    private let manifest = """
    {
      "file": "scene.json",
      "type": "Scene",
      "general": {
        "properties": {
          "newproperty":  { "type": "slider", "text": "镜头视差", "value": 0.8, "min": 0, "max": 1, "order": 0 },
          "newproperty1": { "type": "slider", "text": "鼠标影响", "value": 0.4, "min": 0, "max": 1, "order": 1 },
          "schemecolor":  { "type": "color", "text": "Scheme color", "value": "1 1 1", "order": 2 }
        }
      }
    }
    """

    private func schema(_ manifest: String? = nil) throws -> WallpaperEngineProjectPropertySchema {
        try WallpaperEngineProjectPropertySchema.parse(
            data: Data((manifest ?? self.manifest).utf8),
            includeSchemeColor: true
        )
    }

    private func repair(_ scene: [String: Any]? = nil) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: scene ?? sceneJSON)
        return try WPESceneParallaxBindingInference.applying(to: data, schema: schema())
    }

    @Test("Recognized slider labels bind the intended parallax fields")
    func infersDroppedEnvelopes() throws {
        let doc = try WPESceneDocumentParser.parse(
            data: repair(),
            userValues: ["newproperty": .number(0.8), "newproperty1": .number(0.4)]
        )
        #expect(abs(doc.general.cameraParallax.amount - 0.8) < 1e-9)
        #expect(abs(doc.general.cameraParallax.mouseInfluence - 0.4) < 1e-9)
        // propertyBindings: property key → bound targets
        #expect(doc.propertyBindings["newproperty"]?.map(\.target) == [.generalField(name: "cameraparallaxamount")])
        #expect(doc.propertyBindings["newproperty1"]?.map(\.target) == [.generalField(name: "cameraparallaxmouseinfluence")])
        #expect(doc.propertyBindings["newproperty"]?.allSatisfy { $0.action == .incremental } == true)
        // schemecolor (type color) is never a candidate.
        #expect(doc.propertyBindings["schemecolor"] == nil)
    }

    @Test("No script references leave sliders unbound")
    func noScriptReferenceNoInference() throws {
        var scene = sceneJSON
        var objects = scene["objects"] as? [[String: Any]]
        objects?[0]["parallaxDepth"] = "0.8 0"
        scene["objects"] = objects
        let doc = try WPESceneDocumentParser.parse(data: repair(scene))
        #expect(doc.propertyBindings.isEmpty == true)
        // Literal general values still parse.
        #expect(abs(doc.general.cameraParallax.amount - 1) < 1e-9)
    }

    @Test("Matching slider counts cannot bind unrelated settings")
    func unrelatedSlidersStayUnbound() throws {
        let unrelated = manifest
            .replacingOccurrences(of: "镜头视差", with: "Animation speed")
            .replacingOccurrences(of: "鼠标影响", with: "Particle size")
        let data = try JSONSerialization.data(withJSONObject: sceneJSON)
        #expect(try WPESceneParallaxBindingInference.applying(to: data, schema: schema(unrelated)) == data)
    }

    @Test("Slider display order cannot swap parallax bindings")
    func sliderOrderDoesNotChangeMeaning() throws {
        let reversed = manifest
            .replacingOccurrences(of: "\"order\": 0", with: "\"order\": 9")
        let data = try JSONSerialization.data(withJSONObject: sceneJSON)
        let repaired = try WPESceneParallaxBindingInference.applying(to: data, schema: schema(reversed))
        let doc = try WPESceneDocumentParser.parse(
            data: repaired, userValues: ["newproperty": .number(0.8), "newproperty1": .number(0.4)]
        )
        #expect(doc.general.cameraParallax.amount == 0.8)
        #expect(doc.general.cameraParallax.mouseInfluence == 0.4)
    }

    @Test("A field already bound by a real envelope is not re-paired")
    func boundFieldStaysBound() throws {
        var scene = sceneJSON
        var general = scene["general"] as? [String: Any]
        general?["cameraparallaxamount"] = ["user": "newproperty", "value": 0.8]
        scene["general"] = general
        let doc = try WPESceneDocumentParser.parse(
            data: repair(scene),
            userValues: ["newproperty": .number(0.3), "newproperty1": .number(0.6)]
        )
        // Real envelope wins for amount; its label identifies the remaining influence slider.
        #expect(abs(doc.general.cameraParallax.amount - 0.3) < 1e-9)
        #expect(abs(doc.general.cameraParallax.mouseInfluence - 0.6) < 1e-9)
    }
}
