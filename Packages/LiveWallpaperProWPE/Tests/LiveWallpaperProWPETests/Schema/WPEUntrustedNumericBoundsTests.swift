import Foundation
import JavaScriptCore
@testable import LiveWallpaperProWPE
import Testing

/// `1e100`/`1e300` are *finite*: an `isFinite` guard passes them and `Int(_:)` still traps.
@Suite("Untrusted numeric bounds")
struct WPEUntrustedNumericBoundsTests {
    /// Values as `JSONSerialization` actually produces them (`__NSCFNumber`),
    /// which is the path real scene data takes.
    private func jsonValues(_ text: String) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(
            with: Data(text.utf8)
        ) as? [String: Any] else {
            fatalError("Failed to parse fixture JSON")
        }
        return object
    }

    // MARK: - WPEAuthoredInteger

    @Test("Authored integer conversion rejects NaN, infinity and out-of-domain values instead of trapping")
    func authoredIntegerRejectsUnrepresentable() {
        for value in [Double.nan, .infinity, -.infinity, 1e300, -1e300] {
            #expect(WPEAuthoredInteger.truncated(value, as: Int.self) == nil)
            #expect(WPEAuthoredInteger.rounded(value, as: Int.self) == nil)
            #expect(WPEAuthoredInteger.exact(value, as: Int.self) == nil)
        }
        #expect(WPEAuthoredInteger.rounded(16384.4, as: Int.self, in: WPEAuthoredInteger.pixelExtent) == 16384)
        #expect(WPEAuthoredInteger.rounded(16384.5, as: Int.self, in: WPEAuthoredInteger.pixelExtent) == nil)
        #expect(WPEAuthoredInteger.truncated(3e9, as: Int32.self) == nil)
        #expect(WPEAuthoredInteger.exact(1.5, as: Int.self) == nil)
    }

    @Test("Authored integer conversion matches Int(_:) and rounded() in range")
    func authoredIntegerMatchesStandardConversionInRange() {
        #expect(WPEAuthoredInteger.truncated(42.7, as: Int.self) == 42)
        #expect(WPEAuthoredInteger.truncated(-42.7, as: Int.self) == -42)
        #expect(WPEAuthoredInteger.rounded(1919.5, as: Int.self) == 1920)
        #expect(WPEAuthoredInteger.exact(2.0, as: Int.self) == 2)
    }

    // MARK: - WPEValueParser.int

    @Test("int saturates an out-of-range JSON number that as? Int rejects")
    func intSaturatesWhereAsIntFails() {
        let json = jsonValues(#"{"big":1e300,"small":-1e300,"ok":5}"#)
        #expect(json["big"] as? Int == nil)
        #expect(WPEValueParser.int(json["big"]) == Int.max)
        #expect(WPEValueParser.int(json["small"]) == Int.min)
        #expect(WPEValueParser.int(json["ok"]) == 5)
    }

    // MARK: - Scene load

    private func sceneData(width: String = "1920", objects: String = "[]") -> Data {
        Data(#"{"camera":{},"general":{"orthogonalprojection":{"width":\#(width),"height":1080}},"objects":\#(objects)}"#.utf8)
    }

    private func assets(_ files: [String: String] = [:]) throws -> WPEParityProgramAssets {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return WPEParityProgramAssets(sceneDirectory: root, assetRoots: [])
    }

    /// A parser that accepts the document hands it to program building, which is where an unchecked conversion traps.
    private func expectLoadError(_ data: Data, field: String) throws {
        let assets = try assets()
        do {
            let document = try WPESceneDocumentParser.parse(data: data)
            _ = WPEParityProgramScene(document: document, assets: assets, settings: .init())
            Issue.record("scene with an out-of-range \(field) loaded")
        } catch let error as WPESceneDocumentError {
            #expect(error == .malformedField(field))
        }
    }

    @Test("A scene width beyond any texture fails the load instead of trapping")
    func hugeSceneWidthFailsLoad() throws {
        try expectLoadError(sceneData(width: "1e100"), field: "general.orthogonalprojection.width")
        try expectLoadError(sceneData(width: "-1"), field: "general.orthogonalprojection.width")
    }

    @Test("A numeric object id outside Int fails the load instead of trapping")
    func hugeObjectIDFailsLoad() throws {
        try expectLoadError(sceneData(objects: #"[{"id":1e100}]"#), field: "objects[0].id")
    }

    @Test("A fractional object id fails the load instead of aliasing a truncated id")
    func fractionalObjectIDFailsLoad() throws {
        try expectLoadError(sceneData(objects: #"[{"id":1},{"id":1.5}]"#), field: "objects[1].id")
    }

    @Test("A property-bound object id is checked after the envelope resolves")
    func envelopeObjectIDFailsLoad() throws {
        try expectLoadError(sceneData(objects: #"[{"id":1},{"id":{"user":"k","value":1.5}}]"#), field: "objects[1].id")
        try expectLoadError(sceneData(objects: #"[{"id":0},{"id":{"user":"k","value":18446744073709551616}}]"#),
                            field: "objects[1].id")
    }

    @Test("An object id that Double cannot hold exactly fails the load")
    func doubleRoundedObjectIDFailsLoad() throws {
        try expectLoadError(sceneData(objects: #"[{"id":9007199254740993}]"#), field: "objects[0].id")
    }

    @Test("A fractional parent fails the load instead of attaching to a truncated id")
    func fractionalParentFailsLoad() throws {
        try expectLoadError(sceneData(objects: #"[{"id":1},{"id":2,"parent":1.5}]"#), field: "objects[1].parent")
    }

    @Test("A numeric dependency outside Int fails the load instead of trapping")
    func hugeDependencyFailsLoad() throws {
        try expectLoadError(sceneData(objects: #"[{"id":1,"dependencies":[1e100]}]"#),
                            field: "objects[0].dependencies[0]")
    }

    @Test("A layer size outside the pixel range fails the load instead of trapping")
    func hugeLayerSizeFailsLoad() throws {
        try expectLoadError(sceneData(objects: #"[{"id":1,"image":"models/a.json","size":"1e100 10"}]"#),
                            field: "objects[0].size")
    }

    @Test("Legal integral ids, dependencies and extents still load")
    func legalNumbersLoad() throws {
        let document = try WPESceneDocumentParser.parse(data: sceneData(
            objects: #"[{"id":1,"image":"models/a.json","size":"640 480"},{"id":2.0,"dependencies":[1]}]"#
        ))
        let assets = try assets()
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        #expect(scene.scene.width == 1920)
        #expect(scene.scene.height == 1080)
    }

    private let particleScene = #"[{"id":1,"particle":"particles/probe.json"}]"#

    @Test("A particle maxcount that overflows Float drops the asset instead of trapping")
    func hugeParticleMaxCountDropsAsset() throws {
        let assets = try assets(["particles/probe.json": #"{"maxcount":1e100}"#])
        let document = try WPESceneDocumentParser.parse(data: sceneData(objects: particleScene))
        #expect(document.particleObjects.count == 1)
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        #expect(WPEParityParticleConfig(path: "particles/probe.json", assets: assets, is3D: false) == nil)
        let particles = scene.scene.objects.compactMap { object -> WPEParitySceneParticle? in
            guard case let .particle(particle) = object.kind else { return nil }
            return particle
        }
        #expect(particles.map(\.draws.isEmpty) == [true])
        let simulated = WPEParityParticleScene(document: document, assets: assets, engineFlags: scene.engineFlags, seed: 1)
        #expect(simulated.objects.isEmpty)
    }

    @Test("Particle emitter and renderer integers outside 32 bits drop the asset instead of trapping")
    func hugeParticleComponentIntegersDropAsset() throws {
        let fields = [
            #"{"maxcount":10,"flags":1e100}"#,
            #"{"maxcount":10,"emitter":[{"name":"sphererandom","instantaneous":1e100}]}"#,
            #"{"maxcount":10,"emitter":[{"name":"boxrandom","maxtoemitperperiod":"nan"}]}"#,
            #"{"maxcount":10,"emitter":[{"name":"boxrandom","flags":-1e100}]}"#,
            #"{"maxcount":10,"renderer":[{"name":"ropetrail","segments":1e100}]}"#,
            #"{"maxcount":10,"renderer":[{"name":"rope","subdivision":1e100}]}"#,
            #"{"maxcount":10,"renderer":[{"name":"sprite","orientation":1e100}]}"#,
            #"{"maxcount":10,"renderer":[{"name":"sprite","flags":1e100}]}"#,
            #"{"maxcount":10,"children":[{"name":"particles/child.json","type":"eventspawn","flags":1e100}]}"#,
        ]
        for json in fields {
            let assets = try assets(["particles/probe.json": json, "particles/child.json": #"{"maxcount":1}"#])
            #expect(WPEParityParticleConfig(path: "particles/probe.json", assets: assets, is3D: false) == nil, "\(json)")
        }
    }

    @Test("A child system with an out-of-range maxcount is an unsupported edge, not a trap")
    func hugeChildMaxCountRejectsEdge() throws {
        let assets = try assets([
            "particles/probe.json": #"{"maxcount":10,"children":[{"name":"particles/child.json"}]}"#,
            "particles/child.json": #"{"maxcount":1e100}"#,
        ])
        let config = try #require(WPEParityParticleConfig(path: "particles/probe.json", assets: assets, is3D: false))
        #expect(config.children.isEmpty)
        #expect(config.unsupportedChildren.map(\.field) == ["maxcount"])
    }

    @Test("A legal particle maxcount still loads with its authored value")
    func legalParticleMaxCountLoads() throws {
        let assets = try assets(["particles/probe.json": #"{"maxcount":10,"flags":257}"#])
        let config = try #require(WPEParityParticleConfig(path: "particles/probe.json", assets: assets, is3D: false))
        #expect(config.maxCount == 10)
        #expect(config.flags == 1)
    }

    @Test("A script-created layer size that overflows Float is refused instead of trapping")
    func hugeCreatedLayerSizeIsRefused() throws {
        let assets = try assets(["models/a.json": "{}"])
        let document = try WPESceneDocumentParser.parse(data: sceneData())
        let scene = WPEParityProgramScene(document: document, assets: assets, settings: .init())
        for size in [SIMD2<Float>(.infinity, 1), SIMD2<Float>(.nan, 1), SIMD2<Float>(1, 1e30)] {
            let image = WPEParitySceneState.CreatedImage(model: "models/a.json", size: size, perspective: false)
            #expect(scene.createdImageObject(id: "9", image: image) == nil)
        }
        let legal = WPEParitySceneState.CreatedImage(model: "models/a.json", size: SIMD2(64, 32), perspective: false)
        #expect(scene.createdImageObject(id: "9", image: legal).map { SIMD2($0.width, $0.height) } == SIMD2(64, 32))
    }

    // MARK: - Script runtime

    @Test("setFrame ignores NaN, infinite and out-of-range frames instead of trapping")
    func setFrameIgnoresUnrepresentableFrames() {
        var animation = WPEParityTextureAnimation()
        for value in [Double.nan, .infinity, -.infinity, 1e100] {
            _ = animation.perform(.setFrame, value: value, shared: (0, 0), durations: [1, 1])
        }
        #expect(animation.frame == 0)
        #expect(!animation.individual)
        _ = animation.perform(.setFrame, value: 1.7, shared: (0, 0), durations: [1, 1])
        #expect(animation.frame == 1)
    }

    @Test("A script layer id that is not an exact integer matches no object")
    func unrepresentableScriptIDMatchesNothing() {
        for value in [Double.nan, .infinity, 1e100, 1.5] {
            #expect(WPEParitySceneAnimations.id(.object(["id": .number(value), "name": .string("n")])) == nil)
        }
        #expect(WPEParitySceneAnimations.id(.object(["id": .number(7)])) == "7")
    }

    // MARK: - Script-created model layers

    private static let extremeJSONNumbers = ["1.5", "1e300", "-1", "18446744073709551616", "true"]
    private static let extremeJSNumbers = ["1e300", "-1", "NaN", "Infinity", "9007199254740993"]

    @Test("A createLayer model token that is not an exact UInt32 is refused instead of trapping")
    func unrepresentableModelTokenIsRefused() {
        for raw in Self.extremeJSONNumbers {
            let config = jsonValues(#"{"model":\#(raw),"id":5}"#)
            #expect(WPESceneDocumentParser.parseModelDataLayerConfiguration(config) == nil, "model \(raw)")
        }
        let legal = WPESceneDocumentParser.parseModelDataLayerConfiguration(jsonValues(#"{"model":3,"id":5}"#))
        #expect(legal?.modelDataToken == 3)
    }

    @Test("Extreme createLayer ids and 1e300 vectors parse without trapping")
    func extremeLayerIDsAndVectorsDoNotTrap() {
        for raw in Self.extremeJSONNumbers {
            let descriptor = WPESceneDocumentParser.parseModelDataLayerConfiguration(jsonValues(#"{"model":3,"id":\#(raw)}"#))
            #expect(descriptor.map { Int($0.id) != nil } ?? true, "id \(raw)")
        }
        for raw in [#""1e300 1 1""#, "[1e300,1,1]", #"{"x":1e300,"y":1,"z":1}"#] {
            let config = jsonValues(#"{"model":3,"id":5,"origin":\#(raw),"scale":\#(raw)}"#)
            let descriptor = WPESceneDocumentParser.parseModelDataLayerConfiguration(config)
            #expect(descriptor?.origin == SIMD3(1e300, 1, 1), "origin \(raw)")
            #expect(descriptor?.scale == SIMD3(1e300, 1, 1), "scale \(raw)")
        }
    }

    private func convert(_ context: JSContext, _ script: String) throws -> WPEParityModelDataPatch {
        let value = try #require(context.evaluateScript(script))
        return try WPEModelDataConverter.convert(value, requireFields: false, maximumArrayEntries: 16,
                                                 maximumBufferBytes: 1 << 20) { _ in Data() }
    }

    @Test("ModelData counts cannot carry an extreme length past the entry limit")
    func extremeModelDataCountsAreBounded() throws {
        let context = try #require(JSContext())
        for raw in Self.extremeJSNumbers {
            let assigned = context.evaluateScript("(() => { try { [].length = \(raw); } catch (e) { return e.name; } })()")
            #expect(assigned?.toString() == "RangeError", "a real array cannot take length \(raw)")
            // isArray is false for a Proxy, so the converter reads the input itself as the one shape.
            let fake = "new Proxy([], {get: (t, k) => k === 'length' ? \(raw) : t[k]})"
            #expect(try convert(context, "({shapes: \(fake)})").shapes.count == 1, "shapes length \(raw)")
            #expect(try convert(context, "({vertexFormat: \(fake)})").shapes.map(\.vertexFormat) == [0], "format length \(raw)")
        }
        for field in ["shapes", "vertexFormat"] {
            #expect(throws: WPEModelDataConverter.Failure.shapeLimitExceeded) {
                try convert(context, "({\(field): new Array(4294967295)})")
            }
        }
    }

    @Test("Extreme ModelData bounding boxes convert without trapping")
    func extremeModelDataBoundsDoNotTrap() throws {
        let context = try #require(JSContext())
        for raw in Self.extremeJSNumbers {
            let script = "({boundingBoxMins: {x: \(raw), y: \(raw), z: \(raw)}, boundingBoxMaxs: {x: \(raw), y: 0, z: -(\(raw))}})"
            let bounds = try #require(try convert(context, script).bounds, "bounds \(raw)")
            let expected = try #require(context.evaluateScript(raw)).toDouble()
            #expect(bounds.minimum.x.bitPattern == Float(expected).bitPattern, "bounds \(raw)")
        }
    }
}

@Suite("Authored zero vectors")
struct WPEVectorZeroDictionaryTests {
    private func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    @Test("A dictionary spelling of the zero vector parses like the string spelling")
    func zeroDictionaryParses() {
        #expect(WPEValueParser.vector3(json(#"{"x":0,"y":0,"z":0}"#)) == SIMD3(0, 0, 0))
        #expect(WPEValueParser.vector3("0 0 0") == SIMD3(0, 0, 0))
        #expect(WPEValueParser.vector3(json(#"{"x":0,"y":2,"z":0}"#)) == SIMD3(0, 2, 0))
    }

    @Test("A dictionary with none of the axis keys is still unparsed, not zero")
    func keylessDictionaryStaysNil() {
        #expect(WPEValueParser.vector3(json(#"{"foo":1}"#)) == nil)
        #expect(WPEValueParser.vector3(json(#"{}"#)) == nil)
    }

    @Test("Numeric vectors reject nonfinite components without clamping finite HDR values")
    func vectorsRejectNonfiniteComponents() {
        for value in ["nan 0 0", "0 inf 0", "0 0 -infinity"] {
            #expect(WPEValueParser.numberVector(value) == nil)
        }
        #expect(WPEValueParser.numberVector([Double.nan, 0, 0]) == nil)
        #expect(WPEValueParser.numberVector([0, Double.infinity, 0]) == nil)
        #expect(WPEValueParser.numberVector("-2 4 1e100") == [-2, 4, 1e100])
        #expect(WPEValueParser.numberVector([-2, 4, 1e100]) == [-2, 4, 1e100])
    }

    @Test("Scalar values and animation frames reject nonfinite data")
    func scalarAndAnimationFramesRejectNonfiniteData() throws {
        for value: Any in [Double.nan, Double.infinity, -Double.infinity, "nan", "inf", "-infinity"] {
            #expect(WPEValueParser.double(value) == nil)
        }
        #expect(WPEValueParser.double(-2) == -2)
        #expect(WPEValueParser.double("1e100") == 1e100)
        #expect(WPEValueParser.double(true, boolAsNumber: true) == 1)
        let raw = try JSONSerialization.jsonObject(with: Data(#"{"value":0,"animation":{"c0":[{"frame":"nan","value":1},{"frame":0,"value":"inf"},{"frame":1,"value":2}],"options":{"fps":30,"length":1}}}"#.utf8))
        let animation = try #require(WPEValueParser.animatedValue(raw))
        let track = try #require(animation.animation.tracks.first)
        #expect(track.count == 1)
        #expect(track.first?.frame == 1)
        #expect(track.first?.value == 2)
    }
}
