import Foundation
import LiveWallpaperProWPE

/// Scenes built the way the parity pipeline reads them: a `scene.json` plus the effect, material and model files of a
/// wallpaper directory. Every pass material is `materials/<shader>.json` with translucent blending.
enum ParitySceneDocuments {
    struct Effect {
        let id: String
        var visible = true
        var fbos: [[String: Any]] = []
        var passes: [[String: Any]]
    }

    struct Layer {
        let id: String
        var json: [String: Any]
        var effects: [Effect]
        /// Model file written for the layer's `image`.
        var model: [String: Any] = ["material": "materials/genericimage2.json"]
    }

    static func pass(_ shader: String, target: String? = nil, binds: [Int: String] = [:],
                     extra: [String: Any] = [:]) -> [String: Any] {
        var pass: [String: Any] = ["material": "materials/\(shader).json"]
        pass["target"] = target
        if !binds.isEmpty {
            pass["bind"] = binds.sorted { $0.key < $1.key }.map { ["name": $0.value, "index": $0.key] }
        }
        return pass.merging(extra) { _, new in new }
    }

    static func command(_ command: String, source: String? = nil, target: String) -> [String: Any] {
        var pass: [String: Any] = ["command": command, "target": target]
        pass["source"] = source
        return pass
    }

    static func fbo(_ name: String, scale: Double = 1, fit: Double? = nil,
                    format: String = "rgba8888") -> [String: Any] {
        var fbo: [String: Any] = ["name": name, "scale": scale, "format": format]
        fbo["fit"] = fit
        return fbo
    }

    static func effect(_ id: String = "1", visible: Bool = true, fbos: [[String: Any]] = [],
                       passes: [[String: Any]]) -> Effect {
        Effect(id: id, visible: visible, fbos: fbos, passes: passes)
    }

    static func layer(_ id: String = "7", width: Double = 400, height: Double = 200, image: String? = nil,
                      json: [String: Any] = [:], effects: [Effect] = []) -> Layer {
        var object: [String: Any] = ["id": Int(id) ?? 0, "name": id, "image": image ?? "models/\(id).json",
                                     "size": "\(width) \(height)"]
        object.merge(json) { _, new in new }
        return Layer(id: id, json: object, effects: effects)
    }

    static func effectFile(_ layer: Layer, _ effect: Effect) -> String {
        "effects/\(layer.id)_\(effect.id).json"
    }

    /// `objects` go into `scene.json` ahead of the layers; `files` (path → text, or bytes in `binaries`) are written
    /// last and win.
    static func programScene(_ layers: [Layer], general: [String: Any] = [:], objects: [[String: Any]] = [],
                             files: [String: String] = [:], binaries: [String: Data] = [:],
                             settings: WPEParityProgramSettings = WPEParityProgramSettings()) throws
        -> WPEParityProgramScene {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity-scene-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ json: Any) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json).write(to: url)
        }
        var materials: Set<String> = []
        var sceneObjects = objects
        for layer in layers {
            var object = layer.json
            if let image = object["image"] as? String, !image.hasSuffix(".mdl") {
                try write(image, layer.model)
                if let material = layer.model["material"] as? String {
                    materials.insert(material)
                }
            }
            var authored: [[String: Any]] = []
            for effect in layer.effects {
                let file = effectFile(layer, effect)
                try write(file, ["fbos": effect.fbos, "passes": effect.passes])
                materials.formUnion(effect.passes.compactMap { $0["material"] as? String })
                authored.append(["id": Int(effect.id) ?? 0, "file": file, "visible": effect.visible])
            }
            object["effects"] = authored
            sceneObjects.append(object)
        }
        for path in materials {
            let shader = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            try write(path, ["passes": [["shader": shader, "blending": "translucent"]]])
        }
        for (path, data) in files.mapValues({ Data($0.utf8) }).merging(binaries, uniquingKeysWith: { _, new in new }) {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let scene: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]].merging(general) { _, new in new },
            "objects": sceneObjects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        return WPEParityProgramScene(document: document,
                                     assets: WPEParityProgramAssets(sceneDirectory: root, assetRoots: []),
                                     settings: settings)
    }

    static func convert(_ layers: [Layer], general: [String: Any] = [:], objects: [[String: Any]] = [],
                        files: [String: String] = [:],
                        settings: WPEParityProgramSettings = WPEParityProgramSettings()) throws
        -> WPEParitySceneDescription {
        try programScene(layers, general: general, objects: objects, files: files, settings: settings).scene
    }

    /// The converted FBOs of the single effect that writes `fbo`.
    static func converted(_ fbo: [String: Any], width: Double = 400, height: Double = 200) throws
        -> [WPEParitySceneFBO] {
        let name = fbo["name"] as? String
        let layer = layer(width: width, height: height,
                          effects: [effect(fbos: [fbo], passes: [pass("p", target: name)])])
        return try convert([layer]).objects[0].effects[0].fbos
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
