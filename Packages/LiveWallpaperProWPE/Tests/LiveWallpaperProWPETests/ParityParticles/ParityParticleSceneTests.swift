import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticleSceneTests: XCTestCase {
    private typealias Support = ParityParticleTestSupport

    private static let sprite = #"{"name": "sprite"}"#

    /// `count` particles born on the first frame at the emitter origin, living `lifetime` seconds.
    private static func burst(_ count: Int, lifetime: Float = 10, origin: String = "0 0 0",
                              renderer: String = sprite, extra: String = "") -> String {
        """
        {"maxcount": \(max(count, 1)), "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": \(count), "distancemax": 0,
                      "origin": "\(origin)"}],
         "initializer": [{"name": "lifetimerandom", "min": \(lifetime), "max": \(lifetime)}],
         "renderer": [\(renderer)]\(extra)}
        """
    }

    /// A wallpaper held in memory: particle objects by id and JSON path, plus particle and material files.
    private static func scene(_ objects: [[String: Any]], particles: [String: String], seed: UInt32 = 7,
                              flags: WPEEngineComboFlags = WPEEngineComboFlags()) throws -> WPEParityParticleScene {
        var texture = Array("TEXV0005\0TEXI0001\0".utf8)
        // RG88 spritesheet, 64×64 texture holding a 48×48 image.
        for value: UInt32 in [8, 4, 64, 64, 48, 48] {
            withUnsafeBytes(of: value.littleEndian) { texture.append(contentsOf: $0) }
        }
        var files: [String: Data] = [
            "materials/plain.json": Data(#"{"passes": [{"shader": "genericparticle"}]}"#.utf8),
            "materials/sheet.json": Data(#"{"passes": [{"shader": "genericparticle", "textures": ["p/sheet"]}]}"#.utf8),
            "materials/p/sheet.tex": Data(texture),
        ]
        for (path, text) in particles {
            files[path] = Data(text.utf8)
        }
        let sceneJSON: [String: Any] = ["camera": ["center": "0 0 0"],
                                        "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
                                        "objects": objects]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: sceneJSON),
                                                        userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(URL(fileURLWithPath: "/")) { snapshot[$0] }])
        return WPEParityParticleScene(document: document, assets: assets, engineFlags: flags, seed: seed)
    }

    private static func root(_ scene: WPEParityParticleScene, _ id: String = "5") -> WPEParityParticleSystem? {
        scene.objects.first { $0.id == id }?.system
    }

    private static var five: [[String: Any]] {
        [["id": 5, "name": "fx", "particle": "particles/fx.json"]]
    }

    private static func state(hdr: Bool = false) throws -> WPEParitySceneState {
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: [
                "camera": ["center": "0 0 0"],
                "general": ["orthogonalprojection": ["width": 1920, "height": 1080]], "objects": five,
            ]),
            userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        return WPEParitySceneState(document: document, hdr: hdr)
    }

    func testTypedInstanceUpdateAffectsNewbornsWhileLiveSlotsAndRNGSurvive() throws {
        let particle = """
        {"maxcount": 8, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 10, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"}],
         "renderer": [{"name": "sprite"}], "children": [{"name": "particles/child.json"}]}
        """
        let child = particle.replacingOccurrences(of: #", "children": [{"name": "particles/child.json"}]"#,
                                                  with: #", "hascolor": true"#)
        let objects: [[String: Any]] = [["id": 5, "name": "fx", "particle": "particles/fx.json",
                                         "instanceoverride": ["color": "255 0 0", "brightness": 2, "alpha": 0.5]]]
        var flags = WPEEngineComboFlags()
        flags.hdr = true
        let files = ["particles/fx.json": particle, "particles/child.json": child]
        var scene = try Self.scene(objects, particles: files, flags: flags)
        var control = try Self.scene(objects, particles: files, flags: flags)
        scene.advance(dt: 0.1, frames: ["5": .init()])
        control.advance(dt: 0.1, frames: ["5": .init()])
        let before = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(before.liveCount, 1)
        let oldBytes = try XCTUnwrap(scene.batches(for: .init(objectID: "5", renderer: 0)).first).bytes
        XCTAssertEqual(Support.floats(oldBytes, at: 28, count: 4), [2, 0, 0, 0.5])
        var state = try Self.state(hdr: true)
        let fields: [(String, Float)] = [
            ("alpha", 0.25), ("brightness", 3), ("count", 2), ("size", 2), ("speed", 3), ("lifetime", 0.5),
        ]
        for (name, value) in fields {
            state.setScriptField("instance.\(name)", of: "5", to: .vector(SIMD4(value, 0, 0, 0)),
                                 invalidating: .particleInstance)
        }
        state.setScriptField("instance.colorn", of: "5", to: .vector(SIMD4(0, 0, 1, 0)),
                             invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), [])
        let applied = try XCTUnwrap(Self.root(scene))
        XCTAssertTrue(applied.rng === before.rng)
        XCTAssertEqual(applied.rng.next(), try XCTUnwrap(Self.root(control)).rng.next(), "the hook draws no RNG")
        XCTAssertEqual(applied.emitterStates.map(\.accumulator), before.emitterStates.map(\.accumulator))
        XCTAssertEqual(applied.capacity, before.capacity)
        XCTAssertEqual(applied.highWater, before.highWater)
        XCTAssertEqual(applied.birthHead, before.birthHead)
        XCTAssertEqual(applied.birthTail, before.birthTail)
        XCTAssertEqual(applied.initialColor[0], SIMD3(2, 0, 0))
        XCTAssertEqual(applied.lifetime[0], 10)

        scene.advance(dt: 0.1, frames: ["5": .init()])
        let after = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(after.liveCount, 3, "count changes emission, without replacing the live particle")
        XCTAssertEqual(after.capacity, 8)
        XCTAssertEqual(after.lifetime[0], 10)
        XCTAssertEqual(after.initialSize[0], 0.5)
        XCTAssertEqual(after.velocity[0], SIMD3(10, 0, 0))
        for slot in 1 ... 2 {
            XCTAssertEqual(after.age[slot], 0)
            XCTAssertEqual(after.lifetime[slot], 5)
            XCTAssertEqual(after.initialSize[slot], 1)
            XCTAssertEqual(after.velocity[slot], SIMD3(30, 0, 0))
        }
        let bytes = try XCTUnwrap(scene.batches(for: .init(objectID: "5", renderer: 0)).first).bytes
        XCTAssertEqual(Support.floats(bytes, at: 28, count: 4), [2, 0, 0, 0.5], "old packed colour stays unchanged")
        XCTAssertEqual(Support.floats(bytes, at: 44 + 28, count: 4), [0, 0, 3, 0.25])
        let childBytes = try XCTUnwrap(scene.batches(for: .init(objectID: "5", node: [0], renderer: 0)).first).bytes
        XCTAssertEqual(Support.floats(childBytes, at: 28, count: 4), [1, 1, 1, 1])
        XCTAssertEqual(Support.floats(childBytes, at: 44 + 28, count: 4), [3, 3, 3, 0.25],
                       "child brightness changes at birth while hascolor keeps its own colour gate")
    }

    func testRateWithoutDirtyHookChangesTheNextObjectUpdate() throws {
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": Self.burst(1, lifetime: 100)])
        var state = try Self.state()
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let generation = state.generation(.particleInstance)
        state.setScriptField("instance.rate", of: "5", to: .vector(SIMD4(2, 0, 0, 0)), invalidating: .none)
        XCTAssertEqual(state.generation(.particleInstance), generation)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        XCTAssertEqual(try XCTUnwrap(Self.root(scene)).age[0], 0, "the hook does not itself step the system")
        scene.advance(dt: 0.1, frames: ["5": .init()])
        XCTAssertEqual(try XCTUnwrap(Self.root(scene)).age[0], 0.2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(Self.root(scene)).objectTime, 0.3, accuracy: 1e-6)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), [])
    }

    func testAlphaOnlyHotUpdatePreservesRemappedCurrentControlPointForTheNextBirth() throws {
        let particle = """
        {"maxcount": 2, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 16, "instantaneous": 0,
                      "origin": "1 0 0", "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
         "operator": [{"name": "remapvalue", "input": "runtime", "output": "controlpoint",
                       "outputcontrolpoint0": 0, "operation": "remap",
                       "outputrangemin": "9 0 0", "outputrangemax": "9 0 0"}],
         "renderer": [{"name": "sprite"}]}
        """
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": particle])
        // Binary dt and rate16 emit exactly one particle per step. The genuine remap operator produces CP9.
        scene.advance(dt: 0.0625, frames: ["5": .init(time: 0.0625)])
        let before = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(before.liveCount, 1)
        XCTAssertEqual(before.position[0], SIMD3(1, 0, 0), "The first birth precedes the operator's CP write")
        XCTAssertEqual(before.controlPointTranslation(0), SIMD3(9, 0, 0))
        XCTAssertEqual(before.previousControlPointTranslation(0), SIMD3(9, 0, 0), "Frame-end history stores the remap write")

        var state = try Self.state()
        state.setScriptField("instance.alpha", of: "5", to: .vector(SIMD4(0.5, 0, 0, 0)),
                             invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        let hooked = try XCTUnwrap(Self.root(scene))
        // 22bd40: absent offset AND angle overrides skip this CP, even though another instance field changed.
        XCTAssertEqual(hooked.controlPointTranslation(0), SIMD3(9, 0, 0), "Alpha must not restore the authored CP0")
        XCTAssertEqual(hooked.previousControlPointTranslation(0), SIMD3(9, 0, 0), "The hot hook does not commit history")
        XCTAssertEqual(hooked.position[0], SIMD3(1, 0, 0))
        XCTAssertEqual(hooked.liveCount, 1)
        XCTAssertEqual(hooked.objectTime, before.objectTime)

        scene.advance(dt: 0.0625, frames: ["5": .init(time: 0.125)])
        let after = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(after.liveCount, 2)
        XCTAssertEqual(after.position[0], SIMD3(1, 0, 0), "Existing SoA is not rebaked")
        XCTAssertEqual(after.position[1], SIMD3(10, 0, 0), "The new birth consumes preserved current9 plus emitter origin1")
        XCTAssertEqual(after.initialAlpha[0], 1)
        XCTAssertEqual(after.initialAlpha[1], 0.5, "The unrelated alpha update still reaches the new birth")
        XCTAssertEqual(after.controlPointTranslation(0), SIMD3(9, 0, 0))
        XCTAssertEqual(after.previousControlPointTranslation(0), SIMD3(9, 0, 0))
        // The frame-end remap would hide a lost current if only the final CP were checked. Check its real draw data too.
        let batch = try XCTUnwrap(scene.drawBatches(for: "5").first)
        XCTAssertEqual(batch.vertices.count, 2)
        XCTAssertEqual(Support.floats(batch.vertices.bytes, at: 44, count: 3), [10, 0, 0])
        XCTAssertEqual(Support.floats(batch.vertices.bytes, at: 44 + 28, count: 4), [1, 1, 1, 0.5])
    }

    func testWorldStaticBulkHotOverrideUsesConditionalStackAndRestoresNormalContextForNextBirth() throws {
        let parent = """
        {"maxcount": 0, "material": "materials/plain.json", "renderer": [],
         "children": [{"name": "particles/child.json", "type": "static", "origin": "5 0 0",
                       "flags": 1, "controlpointstartindex": 0}]}
        """
        let child = """
        {"flags": 1, "maxcount": 2, "material": "materials/plain.json",
         "controlpoint": [{"offset": "5 0 0"}],
         "emitter": [{"name": "sphererandom", "controlpoint": 0, "rate": 16, "instantaneous": 0,
                      "origin": "1 0 0", "cone": 1, "directions": "1 0 0",
                      "distancemin": 1, "distancemax": 1, "speedmin": 0, "speedmax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
         "renderer": [{"name": "sprite"}]}
        """
        let owner = simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0),
                                  SIMD4(0, 0, 1, 0), SIMD4(100, 0, 0, 1))
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "particles/child.json": child])
        scene.advance(dt: 0.0625, frames: ["5": .init(time: 0.0625, objectMatrix: owner)])
        let beforeRoot = try XCTUnwrap(Self.root(scene))
        let before = try XCTUnwrap(beforeRoot.children.first)
        XCTAssertEqual(beforeRoot.liveCount, 0, "No parent live slot may fill the child's bulk CP")
        XCTAssertEqual(before.liveCount, 1)
        XCTAssertEqual(before.instanceTransform.columns.3.x, 5)
        XCTAssertEqual(before.frameContext.objectMatrix.columns.3.x, 105, "Normal static update uses Up*E")
        // Fresh and normal bulk suppression preserve the explicit authored CP5, not a private injected matrix.
        XCTAssertEqual(before.controlPointTranslation(0), SIMD3(5, 0, 0))
        XCTAssertEqual(before.previousControlPointTranslation(0), SIMD3(5, 0, 0))
        XCTAssertEqual(before.position[0], SIMD3(7, 0, 0))

        var state = try Self.state()
        state.setScriptField("instance.controlpoint0", of: "5", to: .vector(SIMD4(2, 0, 0, 0)),
                             invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        let hooked = try XCTUnwrap(Self.root(scene)?.children.first)
        // 22bd40 pushes conditional229760: world U=E5, so current=E5*offset2=7, not normalU105*2=107.
        XCTAssertEqual(hooked.controlPointBase(0).columns.3.x, 2)
        XCTAssertEqual(hooked.controlPointTranslation(0), SIMD3(7, 0, 0))
        XCTAssertEqual(hooked.previousControlPointTranslation(0), SIMD3(5, 0, 0), "Hot writes do not commit history")
        XCTAssertEqual(hooked.frameContext.objectMatrix.columns.3.x, 105, "The temporary hot stack must be restored")
        XCTAssertEqual(hooked.position[0], SIMD3(7, 0, 0), "Existing world SoA is not rebaked")
        XCTAssertEqual(hooked.liveCount, 1)
        XCTAssertEqual(hooked.objectTime, before.objectTime)

        scene.advance(dt: 0.0625, frames: ["5": .init(time: 0.125, objectMatrix: owner)])
        let after = try XCTUnwrap(Self.root(scene)?.children.first)
        XCTAssertEqual(after.liveCount, 2)
        XCTAssertEqual(after.frameContext.objectMatrix.columns.3.x, 105)
        XCTAssertEqual(after.position[0], SIMD3(7, 0, 0))
        XCTAssertEqual(after.position[1], SIMD3(9, 0, 0), "No bulk source or ordinary overwrite hides the hot CP7")
        XCTAssertEqual(after.controlPointTranslation(0), SIMD3(7, 0, 0))
        XCTAssertEqual(after.previousControlPointTranslation(0), SIMD3(7, 0, 0))
        let batch = try XCTUnwrap(scene.drawBatches(for: "5").first)
        XCTAssertEqual(batch.vertices.count, 2)
        XCTAssertEqual(Support.floats(batch.vertices.bytes, at: 44, count: 3), [9, 0, 0])
        let expected = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 12 {
            _ = expected.next()
        } // Two sphere births: shape3 + speed + birthU + lifetime.
        XCTAssertEqual(after.rng.next(), expected.next(), "A hot transform push consumes no RNG words")
    }

    func testInstanceControlPointReachesTheOperatorWithRadiansAndSentinelPreservesAuthoredOffset() throws {
        // Native births now include CP translation. A unit z offset avoids the operator's zero-radius case.
        let particle = Self.burst(1, origin: "0 0 1", extra: """
        , "controlpoint": [{"id": 0, "offset": "1 2 3"}, {"id": 1, "flags": 1}],
          "operator": [{"name": "maintaindistancetocontrolpoint", "controlpoint": 0, "distance": 1}]
        """)
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": particle])
        var state = try Self.state()
        let sentinel = Float.greatestFiniteMagnitude
        state.setScriptField("instance.controlpoint0", of: "5", to: .vector(SIMD4(sentinel, sentinel, sentinel, 0)),
                             invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), [])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let before = try XCTUnwrap(Self.root(scene)).position[0]
        let initial = SIMD3<Float>(1, 2, 4)
        for axis in 0 ..< 3 {
            XCTAssertEqual(before[axis], initial[axis], accuracy: 1e-5)
        }

        state.setScriptField("instance.controlpoint0", of: "5", to: .vector(SIMD4(4, 5, 6, 0)),
                             invalidating: .particleInstance)
        state.setScriptField("instance.controlpointangle0", of: "5", to: .vector(SIMD4(0, 0, .pi / 2, 0)),
                             invalidating: .particleInstance)
        state.setScriptField("instance.controlpoint1", of: "5", to: .vector(SIMD4(100, 200, 300, 0)),
                             invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        XCTAssertEqual(try XCTUnwrap(Self.root(scene)).position[0], before)
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let root = try XCTUnwrap(Self.root(scene))
        for axis in 0 ..< 3 {
            XCTAssertEqual(root.position[0][axis], before[axis] + 3, accuracy: 1e-5,
                           "the actual operator consumes the translated CP next update")
        }
        XCTAssertEqual(root.controlPointTranslation(0), SIMD3(4, 5, 6))
        XCTAssertEqual(root.controlPointBasis(0).columns.0.x, 0, accuracy: 1e-6)
        XCTAssertEqual(root.controlPointBasis(0).columns.0.y, 1, accuracy: 1e-6)
        XCTAssertEqual(root.controlPointTranslation(1), .zero, "cursor-following points ignore instance overrides")
    }

    func testTypedOrdinaryPointChangesOnlyTheNextBirthAndKeepsEmitterOriginUnrotated() throws {
        for point in [0, 1] {
            let particle = """
            {"maxcount": 3, "material": "materials/plain.json",
             "emitter": [{"name": "sphererandom", "rate": 10, "distancemax": 0, "origin": "2 0 0",
                          "controlpoint": \(point), "directions": "1 0 0", "speedmin": 3, "speedmax": 3}],
             "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
             "renderer": [{"name": "sprite"}]}
            """
            var scene = try Self.scene(Self.five, particles: ["particles/fx.json": particle])
            scene.advance(dt: 0.1, frames: ["5": .init()])
            let before = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(before.liveCount, 1)
            XCTAssertEqual(before.position[0], SIMD3(2, 0, 0))
            XCTAssertEqual(abs(before.velocity[0].x), 3, accuracy: 1e-5)
            XCTAssertEqual(before.velocity[0].y, 0)
            var state = try Self.state()
            state.setScriptField("instance.controlpoint\(point)", of: "5", to: .vector(SIMD4(10, 5, 0, 0)),
                                 invalidating: .particleInstance)
            state.setScriptField("instance.controlpointangle\(point)", of: "5", to: .vector(SIMD4(0, 0, .pi / 2, 0)),
                                 invalidating: .particleInstance)
            XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
            let hooked = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(hooked.position[0], before.position[0])
            XCTAssertEqual(hooked.velocity[0], before.velocity[0])
            XCTAssertTrue(hooked.rng === before.rng)
            scene.advance(dt: 0.1, frames: ["5": .init()])
            let after = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(after.liveCount, 2)
            XCTAssertEqual(after.position[0], SIMD3(2, 0, 0), "existing slots do not follow a CP without an operator")
            XCTAssertEqual(after.velocity[0], before.velocity[0])
            XCTAssertEqual(after.position[1], SIMD3(12, 5, 0), "origin 2 is added after CP translation, not rotated")
            let axis = point == 0 ? 0 : 1
            XCTAssertEqual(abs(after.velocity[1][axis]), 3, accuracy: 1e-5)
            XCTAssertEqual(after.velocity[1][1 - axis], 0, accuracy: 1e-5)
            XCTAssertEqual(after.velocity[1].z, 0)
            let batch = try XCTUnwrap(scene.drawBatches(for: "5").first)
            XCTAssertEqual(Support.floats(batch.vertices.bytes, at: 0, count: 3), [2, 0, 0])
            XCTAssertEqual(Support.floats(batch.vertices.bytes, at: 44, count: 3), [12, 5, 0])
            // 22bd40 writes only supplied base fields: an offset with angle sentinel keeps the existing basis.
            let sentinel = Float.greatestFiniteMagnitude
            state.setScriptField("instance.controlpoint\(point)", of: "5", to: .vector(SIMD4(20, 15, 0, 0)),
                                 invalidating: .particleInstance)
            state.setScriptField("instance.controlpointangle\(point)", of: "5",
                                 to: .vector(SIMD4(sentinel, sentinel, sentinel, 0)), invalidating: .particleInstance)
            XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
            scene.advance(dt: 0.1, frames: ["5": .init()])
            let partial = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(partial.liveCount, 3)
            XCTAssertEqual(partial.position[2], SIMD3(22, 15, 0))
            XCTAssertEqual(abs(partial.velocity[2][axis]), 3, accuracy: 1e-5)
            XCTAssertEqual(partial.velocity[2][1 - axis], 0, accuracy: 1e-5)
            XCTAssertEqual(partial.controlPointBasis(point).columns.0.y, 1, accuracy: 1e-6)
            let partialBatch = try XCTUnwrap(scene.drawBatches(for: "5").first)
            XCTAssertEqual(Support.floats(partialBatch.vertices.bytes, at: 88, count: 3), [22, 15, 0])
            let expected = WPEParityMT19937(seed: 7)
            for _ in 0 ..< 27 {
                _ = expected.next()
            } // three (u + shape3 + fallback3 + speed + lifetime) births
            XCTAssertEqual(partial.rng.next(), expected.next(), "the typed hooks must not draw additional words")
        }
    }

    func testParticleDrawKeysAndContainerNodesAgreeOnCaptureAndWorkshopScenes() throws {
        let install = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let capture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WPE_HLSL_CAPTURE_DIR"]
            ?? "/Users/example/Developer/wpe-fixtures/hlsl-capture-2026-10-12")
        var checked = 0
        for sceneID in ["3509243656", "3660962877"] {
            let directory = capture.appendingPathComponent("scene-sources/\(sceneID)")
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("scene.json").path) else {
                continue
            }
            checked += try Self.assertKeysAlign(
                directory, assets: [capture.appendingPathComponent("wpeassets"), install], label: sceneID
            )
        }
        let package = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/workshop/content/431960/3448877775/scene.pkg"
        )
        if FileManager.default.fileExists(atPath: package.path) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-particles-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            try ParityProgramPuppetTests.unpack(package, into: root)
            checked += try Self.assertKeysAlign(root, assets: [install], label: "3448877775")
        }
        guard checked > 0 else { throw XCTSkip("No capture fixture or workshop 3448877775 scene.pkg") }
    }

    /// Returns the number of particle objects compared.
    private static func assertKeysAlign(_ directory: URL, assets roots: [URL], label: String) throws -> Int {
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: directory.appendingPathComponent("scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        let assets = WPEParityProgramAssets(sceneDirectory: directory, assetRoots: roots)
        let scene = WPEParityParticleScene(document: document, assets: assets, engineFlags: WPEEngineComboFlags(),
                                           seed: 1)
        for particle in document.particleObjects {
            var diagnostics: [WPEParitySceneDiagnostic] = []
            let draws = WPEParityProgramScene.particleDraws(objectID: particle.id, path: particle.particleRelativePath,
                                                            assets: assets, diagnostics: &diagnostics)
            var nodes: [WPEParityParticleDrawKey] = []
            if let system = root(scene, particle.id) {
                keys(system, at: WPEParityParticleDrawKey(objectID: particle.id, renderer: 0), into: &nodes)
            }
            XCTAssertEqual(draws.map(\.key), nodes, "\(label) \(particle.id) \(particle.particleRelativePath)")
            for key in nodes {
                XCTAssertNotNil(scene.childLocal(for: key), "\(label) \(key)")
            }
        }
        return document.particleObjects.count
    }

    /// The container's renderer entries in W32a's order: entries, static children depth first, event groups.
    private static func keys(_ system: WPEParityParticleSystem, at node: WPEParityParticleDrawKey,
                             into keys: inout [WPEParityParticleDrawKey]) {
        for index in system.renderers.indices {
            var key = node
            key.renderer = index
            keys.append(key)
        }
        for (index, child) in system.children.enumerated() {
            var key = node
            key.path.append(.staticChild(index))
            Self.keys(child, at: key, into: &keys)
        }
        for (group, child) in system.config.children.filter({ $0.trigger != .always }).enumerated() {
            XCTAssertTrue(child.config.children.isEmpty)
            for index in child.config.renderers.indices {
                var key = node
                key.path.append(.eventGroup(group))
                key.renderer = index
                keys.append(key)
            }
        }
    }

    /// Native prewarm does not recursively update event children (14022ebe0 → 140236cd0). The old checksum
    /// recorded Mac's earlier recursive prewarm/RNG behavior; retain it as a diagnostic, not a native oracle.
    /// Still parse, advance, pack and copy every batch of Workshop 3448877775 for 300 frames.
    func testWorkshopScenePrewarmAndBatchesFollowTheOwnerUpdateContract() throws {
        let install = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        let package = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Steam/steamapps/workshop/content/431960/3448877775/scene.pkg"
        )
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw XCTSkip("No workshop 3448877775 scene.pkg")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-particles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: root.appendingPathComponent("scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        let assets = WPEParityProgramAssets(sceneDirectory: root, assetRoots: [install])
        var scene = WPEParityParticleScene(document: document, assets: assets, engineFlags: WPEEngineComboFlags(),
                                           seed: 1)
        do {
            let shooting = try XCTUnwrap(Self.root(scene, "15706"))
            XCTAssertEqual(shooting.config.startTime, 9)
            XCTAssertGreaterThan(shooting.prewarmStepCount, 0)
            XCTAssertEqual(shooting.simulationTime, 0)
            XCTAssertEqual(shooting.objectTime, 0)
            let death = try XCTUnwrap(shooting.config.children.first)
            XCTAssertEqual(death.trigger, .death)
            XCTAssertEqual(death.maxCount, 10)
            XCTAssertEqual(death.config.startTime, 0)
            XCTAssertEqual(shooting.eventChildren.count, 1)
            XCTAssertEqual(shooting.eventChildren[0].count, 10)
            for child in shooting.eventChildren[0] {
                // The parent has prewarmed past several deaths, but these starttime=0 children have not updated.
                XCTAssertEqual(child.liveCount, 0)
                XCTAssertEqual(child.prewarmStepCount, 0)
                XCTAssertEqual(child.simulationTime, 0)
                XCTAssertEqual(child.objectTime, 0)
                XCTAssertTrue(child.emitterStates[0].burstPending)
            }
        }
        let visible = document.particleObjects.filter(\.visible)
        let keys = visible.flatMap { particle in
            var diagnostics: [WPEParitySceneDiagnostic] = []
            return WPEParityProgramScene.particleDraws(objectID: particle.id, path: particle.particleRelativePath,
                                                       assets: assets, diagnostics: &diagnostics).map(\.key)
        }
        let clock = ContinuousClock()
        var (simulate, pack, copy) = (Duration.zero, Duration.zero, Duration.zero)
        var arena = [UInt8](repeating: 0, count: 16 << 20)
        var checksum: UInt64 = 0xCBF2_9CE4_8422_2325
        var vertexCount = 0
        let frames = 300
        for frame in 1 ... frames {
            var contexts: [String: WPEParityParticleFrameContext] = [:]
            for particle in visible {
                contexts[particle.id] = WPEParityParticleFrameContext(time: Float(frame) / 60)
            }
            var start = clock.now
            scene.advance(dt: 1.0 / 60, frames: contexts)
            simulate += clock.now - start
            if frame == 1 {
                let shooting = try XCTUnwrap(Self.root(scene, "15706"))
                for child in shooting.eventChildren[0] {
                    XCTAssertEqual(child.liveCount, 1, "The first normal owner update emits each pending burst")
                    XCTAssertEqual(child.age[0], 0)
                    XCTAssertEqual(child.simulationTime, shooting.objectTime, accuracy: 1e-6)
                    XCTAssertEqual(child.objectTime, shooting.objectTime)
                }
            }
            var offset = 0
            for key in keys {
                start = clock.now
                let batches = scene.batches(for: key)
                vertexCount += batches.reduce(0) { $0 + $1.count }
                pack += clock.now - start
                start = clock.now
                for batch in batches {
                    offset = offset + batch.bytes.count > arena.count ? 0 : offset
                    arena.withUnsafeMutableBytes { target in
                        let tail = UnsafeMutableRawBufferPointer(rebasing: target[offset...])
                        batch.bytes.withUnsafeBytes { tail.copyMemory(from: $0) }
                    }
                    offset += batch.bytes.count
                }
                copy += clock.now - start
                for byte in batches.flatMap(\.bytes) {
                    checksum = (checksum ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
                }
            }
        }
        func mean(_ duration: Duration) -> String {
            let milliseconds = Double(duration.components.attoseconds) / 1e15
                + Double(duration.components.seconds) * 1000
            return String(format: "%.3f", milliseconds / Double(frames))
        }
        print("scene 3448877775: \(keys.count) draw keys, checksum \(checksum); per frame advance \(mean(simulate)) ms, "
            + "batches \(mean(pack)) ms, copy \(mean(copy)) ms")
        XCTAssertGreaterThan(vertexCount, 0, "The real scene must still produce and copy particle batches")
    }

    func testChildNamingItsOwnFileIsSkipped() throws {
        let loop = Self.burst(1, extra: #", "children": [{"name": "particles/fx.json"}]"#)
        let scene = try Self.scene(Self.five, particles: ["particles/fx.json": loop])
        let root = try XCTUnwrap(Self.root(scene))
        XCTAssertTrue(root.children.isEmpty)
        XCTAssertTrue(root.config.children.isEmpty)
        XCTAssertTrue(root.diagnostics.contains { $0.contains("particles/fx.json") })
    }

    func testSameSeedRepeatsTheBytesAndAnotherSeedDiffers() throws {
        let json = """
        {"maxcount": 50, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 40, "speedmax": 30}],
         "initializer": [{"name": "lifetimerandom", "min": 1, "max": 2}, {"name": "sizerandom"}],
         "operator": [{"name": "movement"}], "renderer": [{"name": "sprite"}]}
        """
        func bytes(_ seed: UInt32) throws -> [UInt8] {
            var scene = try Self.scene(Self.five, particles: ["particles/fx.json": json], seed: seed)
            for _ in 0 ..< 10 {
                scene.advance(dt: 1.0 / 30, frames: ["5": .init()])
            }
            return scene.batches(for: WPEParityParticleDrawKey(objectID: "5", renderer: 0)).first?.bytes ?? []
        }
        let first = try bytes(42)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(try bytes(42), first)
        XCTAssertNotEqual(try bytes(43), first)
    }

    func testStaticChildUsesItsOwnMaterialForStride() throws {
        let parent = Self.burst(2, extra: #", "children": [{"name": "particles/child.json"}]"#)
        let child = Self.burst(2).replacingOccurrences(of: "materials/plain.json", with: "materials/sheet.json")
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "particles/child.json": child])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let root = scene.batches(for: WPEParityParticleDrawKey(objectID: "5", renderer: 0))
        let sheet = scene.batches(for: WPEParityParticleDrawKey(objectID: "5", node: [0], renderer: 0))
        XCTAssertEqual(root.map(\.stride), [44])
        XCTAssertEqual(sheet.map(\.stride), [60])
        XCTAssertEqual(sheet.first?.count, 2)
    }

    func testObjectAndStaticChildOriginsStayOutOfPositions() throws {
        let parent = Self.burst(1, origin: "3 4 0", extra: #", "children": [{"name": "particles/child.json", "origin": "10 0 0"}]"#)
        let objects: [[String: Any]] = [["id": 5, "name": "fx", "particle": "particles/fx.json", "origin": "100 50 0"]]
        var scene = try Self.scene(objects, particles: ["particles/fx.json": parent,
                                                        "particles/child.json": Self.burst(1, origin: "1 2 0")])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let root = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(root.position[0], SIMD3(3, 4, 0))
        XCTAssertEqual(root.children.first?.position[0], SIMD3(1, 2, 0))
        XCTAssertEqual(scene.childLocal(for: WPEParityParticleDrawKey(objectID: "5", renderer: 0)),
                       matrix_identity_float4x4)
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(10, 0, 0, 1)
        XCTAssertEqual(scene.childLocal(for: WPEParityParticleDrawKey(objectID: "5", node: [0], renderer: 0)),
                       translation)
    }

    func testWorldSpaceSystemBornThroughTheObjectMatrix() throws {
        let json = Self.burst(1, origin: "3 4 0", extra: #", "flags": 1"#)
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": json])
        var frame = WPEParityParticleFrameContext()
        frame.objectMatrix.columns.3 = SIMD4(100, 50, 0, 1)
        scene.advance(dt: 0.1, frames: ["5": frame])
        XCTAssertEqual(Self.root(scene)?.position[0], SIMD3(103, 54, 0))
    }

    func testEachDeathEventCompletesItsRendererEntriesBeforeTheNextInstance() throws {
        let parent = """
        {"maxcount": 2, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1,
                      "distancemax": 0, "origin": "-20 0 0"},
                     {"name": "sphererandom", "rate": 0, "instantaneous": 1,
                      "distancemax": 0, "origin": "20 0 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05}],
         "renderer": [{"name": "sprite"}],
         "children": [{"name": "particles/glow.json", "type": "eventdeath"}]}
        """
        let glow = Self.burst(1, renderer: #"{"name": "sprite"}, {"name": "spritetrail"}"#)
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent,
                                                          "particles/glow.json": glow])
        var control = try Self.scene(Self.five, particles: ["particles/fx.json": parent,
                                                            "particles/glow.json": glow])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        control.advance(dt: 0.1, frames: ["5": .init()])
        control.advance(dt: 0.1, frames: ["5": .init()])
        let actual = scene.drawBatches(for: "5")
        XCTAssertEqual(actual.map(\.key), [
            .init(objectID: "5", path: [.eventGroup(0)], renderer: 0),
            .init(objectID: "5", path: [.eventGroup(0)], renderer: 1),
            .init(objectID: "5", path: [.eventGroup(0)], renderer: 0),
            .init(objectID: "5", path: [.eventGroup(0)], renderer: 1),
        ])
        XCTAssertEqual(actual.map { Support.float($0.vertices.bytes, at: 0) }, [0, 0, 0, 0])
        XCTAssertEqual(actual.map(\.modelMatrix.columns.3.x), [-20, -20, 20, 20])
        XCTAssertEqual(actual.map(\.vertices.count), [1, 1, 1, 1])
        XCTAssertEqual(actual.map(\.vertices.renderVar0), [
            .init(), .init(x: 0.05, y: 10, z: 0), .init(), .init(x: 0.05, y: 10, z: 0),
        ])
        let key = WPEParityParticleDrawKey(objectID: "5", renderer: 0, eventGroup: 0)
        XCTAssertEqual(scene.batches(for: key), actual.filter { $0.key == key }.map(\.vertices))
        XCTAssertEqual(try XCTUnwrap(Self.root(scene)).rng.next(), try XCTUnwrap(Self.root(control)).rng.next(),
                       "Neither object packing nor compatibility lookup consumes the shared RNG")
        XCTAssertEqual(scene.batches(for: WPEParityParticleDrawKey(objectID: "5", renderer: 0)), [])
        XCTAssertTrue(scene.drawBatches(for: "missing").isEmpty)
    }

    /// 1402366f0 snapshots at a live system before renderer dispatch; one rope particle cannot draw but still
    /// captures before the non-FFB child B. The callback is the external compiled base-material fact boundary.
    func testSnapshotBoundaryPrecedesChildrenWhenTheTriggeringRopeCannotDraw() throws {
        let children = #", "children": [{"name": "B"}, {"name": "C"}]"#
        let files = ["particles/fx.json": Self.burst(1, renderer: #"{"name": "rope"}"#, extra: children),
                     "B": Self.burst(1, origin: "10 0 0"), "C": Self.burst(1, origin: "20 0 0")]
        let objects: [[String: Any]] = Self.five + [["id": 6, "name": "other owner", "particle": "particles/fx.json"]]
        var scene = try Self.scene(objects, particles: files)
        var control = try Self.scene(objects, particles: files)
        let frames: [String: WPEParityParticleFrameContext] = ["5": .init(), "6": .init()]
        scene.advance(dt: 0.1, frames: frames)
        control.advance(dt: 0.1, frames: frames)
        var visited: [[WPEParityParticlePathElement]] = []
        let stream = scene.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                      worldModel: matrix_identity_float4x4) { path in
            visited.append(path)
            return path.isEmpty || path == [.staticChild(1)]
        }
        XCTAssertEqual(stream.snapshotBoundary, 0)
        XCTAssertEqual(stream.batches.map(\.key.path), [[.staticChild(0)], [.staticChild(1)]])
        XCTAssertEqual(stream.batches.map { Support.float($0.vertices.bytes, at: 0) }, [10, 20])
        XCTAssertEqual(visited, [[], [.staticChild(0)], [.staticChild(1)]],
                       "the first trigger fixes the boundary, but every later system still checks material availability")
        XCTAssertEqual(scene.drawStream(objectID: "6", ownerModel: matrix_identity_float4x4,
                                        worldModel: matrix_identity_float4x4,
                                        needsFullFrameBuffer: { _ in true }).snapshotBoundary, 0,
                       "the preceding owner does not consume this owner's snapshot")
        XCTAssertEqual(scene.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                        worldModel: matrix_identity_float4x4,
                                        needsFullFrameBuffer: { _ in true }).snapshotBoundary, 0,
                       "the next owner draw entry resets the one-shot condition")
        XCTAssertEqual(scene.drawBatches(for: "5").map(\.vertices), stream.batches.map(\.vertices))
        XCTAssertEqual(try XCTUnwrap(Self.root(scene)).rng.next(), try XCTUnwrap(Self.root(control)).rng.next())
        XCTAssertEqual(scene.drawStream(objectID: "missing", ownerModel: matrix_identity_float4x4,
                                        worldModel: matrix_identity_float4x4, needsFullFrameBuffer: { _ in
            XCTFail("an unknown owner has no systems to inspect")
            return true
        }).snapshotBoundary, nil)
    }

    func testSnapshotBoundaryUsesOwnLiveCountAndCanFollowEveryBatch() throws {
        let children = #", "children": [{"name": "B"}, {"name": "C"}]"#
        var scene = try Self.scene(Self.five, particles: [
            "particles/fx.json": Self.burst(0, extra: children), "B": Self.burst(1), "C": Self.burst(1),
        ])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        var visited: [[WPEParityParticlePathElement]] = []
        let stream = scene.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                      worldModel: matrix_identity_float4x4) { path in
            visited.append(path)
            return path.isEmpty || path == [.staticChild(1)]
        }
        XCTAssertEqual(visited, [[], [.staticChild(0)], [.staticChild(1)]],
                       "an empty ready root passes the material gate but cannot trigger the snapshot")
        XCTAssertEqual(stream.snapshotBoundary, 1)
        XCTAssertEqual(stream.batches.count, 2)
        XCTAssertNil(scene.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                      worldModel: matrix_identity_float4x4,
                                      needsFullFrameBuffer: { _ in false }).snapshotBoundary)

        var tail = try Self.scene(Self.five, particles: [
            "particles/fx.json": Self.burst(1, extra: #", "children": [{"name": "rope"}]"#),
            "rope": Self.burst(1, renderer: #"{"name": "rope"}"#),
        ])
        tail.advance(dt: 0.1, frames: ["5": .init()])
        let late = tail.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                   worldModel: matrix_identity_float4x4,
                                   needsFullFrameBuffer: { $0 == [.staticChild(0)] })
        XCTAssertEqual(late.batches.count, 1)
        XCTAssertEqual(late.snapshotBoundary, 1, "a late live rope triggers even with no following actual batch")

        enum MissingFact: Error { case material }
        XCTAssertThrowsError(try tail.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                                 worldModel: matrix_identity_float4x4,
                                                 needsFullFrameBuffer: { _ in throw MissingFact.material }))
    }

    /// 1402366f0's outer material gate prunes just that recursive system, even after the owner's snapshot fired.
    func testUnavailableChildMaterialPrunesItsSubtreeWhileParentAndSiblingDraw() throws {
        var scene = try Self.scene(Self.five, particles: [
            "particles/fx.json": Self.burst(1, origin: "1 0 0",
                                            extra: #", "children": [{"name": "bad"}, {"name": "healthy"}]"#),
            "bad": Self.burst(1, origin: "10 0 0", extra: #", "children": [{"name": "grandchild"}]"#),
            "grandchild": Self.burst(1, origin: "11 0 0"),
            "healthy": Self.burst(1, origin: "20 0 0"),
        ])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        XCTAssertEqual(scene.liveCount("5"), 4)
        var visited: [[WPEParityParticlePathElement]] = []
        let stream = scene.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                      worldModel: matrix_identity_float4x4) { path -> Bool? in
            visited.append(path)
            return path == [.staticChild(0)] ? nil : true
        }
        XCTAssertEqual(visited, [[], [.staticChild(0)], [.staticChild(1)]])
        XCTAssertEqual(stream.snapshotBoundary, 0)
        XCTAssertEqual(stream.batches.map(\.key.path), [[], [.staticChild(1)]])
        XCTAssertEqual(stream.batches.map { Support.float($0.vertices.bytes, at: 0) }, [1, 20])
        XCTAssertEqual(scene.liveCount("5"), 4, "a render material failure does not reset simulation")
    }

    func testEmptyUnavailableParentPrunesLiveChildrenBeforeInspectingTheirMaterials() throws {
        var scene = try Self.scene(Self.five, particles: [
            "particles/fx.json": Self.burst(0, extra: #", "children": [{"name": "child"}]"#),
            "child": Self.burst(1),
        ])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        XCTAssertEqual(Self.root(scene)?.liveCount, 0)
        XCTAssertEqual(scene.liveCount("5"), 1)
        var visited: [[WPEParityParticlePathElement]] = []
        let stream = scene.drawStream(objectID: "5", ownerModel: matrix_identity_float4x4,
                                      worldModel: matrix_identity_float4x4) { path -> Bool? in
            visited.append(path)
            return nil
        }
        XCTAssertEqual(visited, [[]])
        XCTAssertTrue(stream.batches.isEmpty)
        XCTAssertNil(stream.snapshotBoundary)
        XCTAssertEqual(scene.drawBatches(for: "5").map(\.key.path), [[.staticChild(0)]],
                       "the compatibility API assumes ready materials, proving the child is drawable")
    }

    func testNoLiveParticlesOrALoneRopeParticleYieldNoBatch() throws {
        let empty = Self.burst(0)
        let rope = Self.burst(1, renderer: #"{"name": "rope"}"#)
        var scene = try Self.scene(
            [["id": 5, "name": "a", "particle": "particles/empty.json"],
             ["id": 6, "name": "b", "particle": "particles/rope.json"]],
            particles: ["particles/empty.json": empty, "particles/rope.json": rope]
        )
        scene.advance(dt: 0.1, frames: ["5": .init(), "6": .init()])
        XCTAssertEqual(Self.root(scene, "6")?.liveCount, 1)
        XCTAssertEqual(scene.batches(for: WPEParityParticleDrawKey(objectID: "5", renderer: 0)), [])
        XCTAssertEqual(scene.batches(for: WPEParityParticleDrawKey(objectID: "6", renderer: 0)), [])
    }

    func testInvisibleObjectIsNotAdvancedAndHoldsNoParticles() throws {
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": Self.burst(3)])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        XCTAssertEqual(Self.root(scene)?.liveCount, 3)
        scene.advance(dt: 0.1, frames: [:])
        XCTAssertEqual(Self.root(scene)?.liveCount, 0)
        XCTAssertEqual(Self.root(scene)?.age[0], 0)
    }

    func testFreshNestedStaticPrewarmReceivesTheExistingHotSnapshot() throws {
        let parent = Self.burst(1, lifetime: 0.005,
                                extra: #", "children": [{"name": "event", "type": "eventdeath"}]"#)
        let event = Self.burst(1, extra: #", "starttime": 0.05, "children": [{"name": "leaf"}]"#)
        let leaf = Self.burst(1, extra: #", "starttime": 0.05"#)
        var flags = WPEEngineComboFlags()
        flags.hdr = true
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "event": event, "leaf": leaf],
                                   flags: flags)
        scene.advance(dt: 0.01, frames: ["5": .init()])
        var state = try Self.state(hdr: true)
        for (name, value) in [("alpha", Float(0.25)), ("brightness", 3), ("lifetime", 2)] {
            state.setScriptField("instance.\(name)", of: "5", to: .vector(SIMD4(value, 0, 0, 0)), invalidating: .particleInstance)
        }
        state.setScriptField("instance.colorn", of: "5", to: .vector(SIMD4(0, 0, 1, 0)), invalidating: .particleInstance)
        state.setScriptField("instance.controlpoint0", of: "5", to: .vector(SIMD4(4, 5, 6, 0)), invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        scene.advance(dt: 0.01, frames: ["5": .init()])
        let spawned = try XCTUnwrap(Self.root(scene)?.eventChildren[0].first)
        let staticLeaf = try XCTUnwrap(spawned.children.first)
        for system in [spawned, staticLeaf] {
            XCTAssertEqual(system.initialAlpha[0], 0.25, "the existing hot snapshot must apply before the prewarm birth")
            XCTAssertEqual(system.initialColor[0], SIMD3(0, 0, 3))
            XCTAssertEqual(system.lifetime[0], 20)
            XCTAssertEqual(system.controlPointTranslation(0), SIMD3(4, 5, 6))
            XCTAssertEqual(system.position[0], SIMD3(4, 5, 6), "the hot CP snapshot reaches the prewarm birth")
            XCTAssertEqual(system.age[0], 0.01, accuracy: 1e-6)
        }
        let batches = scene.drawBatches(for: "5")
        XCTAssertEqual(batches.map(\.key.path), [[.eventGroup(0)], [.eventGroup(0), .staticChild(0)]])
    }

    func testN1QualificationRejectsNewBranchesWithoutChangingHealthySiblings() throws {
        let plain = Self.burst(1)
        let periodic = plain.replacingOccurrences(of: #""instantaneous": 1"#, with: #""instantaneous": 1, "flags": 4"#)
        let cases: [(text: String, edge: String, field: String)] = [
            (periodic, "", "emitter"),
            (plain.replacingOccurrences(of: "lifetimerandom", with: "inheritcontrolpointvelocity"), "", "component"),
            (plain, #", "angles": "invalid""#, "angles"),
            (plain, #", "angles": "1e40 0 0""#, "angles"),
            (plain, #", "origin": "1e40 0 0""#, "origin"),
            (plain, #", "scale": "2 0 1""#, "scale"),
            (plain, #", "scale": "1e40 1 1""#, "scale"),
            (plain, #", "scale": "invalid""#, "scale"),
            (plain, #", "type": "static", "flags": 2"#, "child.flags"),
        ]
        for (bad, edge, field) in cases {
            let parent = Self.burst(1, lifetime: 0.005, extra: #", "children": [{"name": "legacy"}, {"name": "event", "type": "eventdeath"}]"#)
            let event = Self.burst(0, renderer: "", extra: """
            , "children": [{"name": "bad"\(edge)}, {"name": "good", "controlpointstartindex": 7}]
            """)
            var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "legacy": plain,
                                                              "event": event, "bad": bad, "good": plain, "leaf": plain])
            let root = try XCTUnwrap(Self.root(scene))
            let eventConfig = try XCTUnwrap(root.config.children.first { $0.trigger == .death }?.config)
            XCTAssertEqual(root.children.count, 1)
            XCTAssertEqual(eventConfig.children.count, 1, field)
            XCTAssertEqual(eventConfig.children[0].controlPointStartIndex, 7, "flags0 does not read startindex")
            XCTAssertTrue(eventConfig.unsupportedChildren.contains { $0.field.contains(field) && !$0.reason.isEmpty }, field)
            scene.advance(dt: 0.01, frames: ["5": .init()])
            scene.advance(dt: 0.01, frames: ["5": .init()])
            XCTAssertEqual(scene.drawBatches(for: "5").map(\.key.path),
                           [[.staticChild(0)], [.eventGroup(0), .staticChild(0)]], field)
        }
        // A rejected grandchild is already absent: retain its healthy static ancestor and that ancestor's sibling.
        for rejectedType in ["eventspawn", "eventfollow"] {
            let parent = Self.burst(1, lifetime: 0.005, extra: #", "children": [{"name": "event", "type": "eventdeath"}]"#)
            let event = Self.burst(0, renderer: "", extra: #", "children": [{"name": "ancestor"}, {"name": "sibling"}]"#)
            let ancestor = Self.burst(1, extra: """
            , "children": [{"name": "leaf", "type": "\(rejectedType)"}, {"name": "leaf"}]
            """)
            var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "event": event,
                                                              "ancestor": ancestor, "sibling": plain, "leaf": plain])
            let eventConfig = try XCTUnwrap(Self.root(scene)?.config.children.first?.config)
            XCTAssertEqual(eventConfig.children.count, 2)
            XCTAssertEqual(eventConfig.children[0].config.children.count, 1)
            XCTAssertTrue(eventConfig.children[0].config.unsupportedChildren.contains { $0.field == "type" })
            scene.advance(dt: 0.01, frames: ["5": .init()])
            scene.advance(dt: 0.01, frames: ["5": .init()])
            XCTAssertEqual(scene.drawBatches(for: "5").map(\.key.path),
                           [[.eventGroup(0), .staticChild(0)], [.eventGroup(0), .staticChild(0), .staticChild(0)],
                            [.eventGroup(0), .staticChild(1)]])
        }
        // 22a360/229760/22e3e0/236cd0 close world, parent-copy and CP-history ancestry.
        for ancestorExtra in [#", "flags": 1"#,
                              #", "controlpoint": [{"flags": 4}]"#,
                              #", "operator": [{"name": "maintaindistancetocontrolpoint"}]"#] {
            let parent = Self.burst(1, lifetime: 0.005, origin: "0 0 1", extra: ancestorExtra + #", "children": [{"name": "legacy"}, {"name": "event", "type": "eventdeath"}]"#)
            let event = Self.burst(0, extra: #", "children": [{"name": "good"}]"#)
            var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "legacy": plain,
                                                              "event": event, "good": plain])
            let root = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(root.children.count, 1)
            let eventConfig = try XCTUnwrap(root.config.children.first { $0.trigger == .death }?.config)
            XCTAssertEqual(eventConfig.children.count, 1)
            XCTAssertTrue(eventConfig.unsupportedChildren.isEmpty)
            scene.advance(dt: 0.01, frames: ["5": .init()])
            scene.advance(dt: 0.01, frames: ["5": .init()])
            XCTAssertEqual(scene.drawBatches(for: "5").map(\.key.path),
                           [[.staticChild(0)], [.eventGroup(0), .staticChild(0)]])
        }
    }

    /// These fields used to reject the new nested edge. Native 22a360/229760/22e3e0/22a580/236cd0
    /// now have consumers; both death and follow must instantiate and draw their accepted static subtree.
    func testProvedSpaceCPHistoryAndBulkFieldsReachDeathAndFollowDescendants() throws {
        let plain = Self.burst(1)
        let candidates: [(String, String)] = [
            (Self.burst(1, extra: #", "flags": 1"#), ""),
            (Self.burst(1, origin: "0 0 1", extra: #", "operator": [{"name": "maintaindistancetocontrolpoint", "distance": 1}]"#), ""),
            (Self.burst(1, origin: "0 0 1", extra: """
            , "controlpoint": [{"id": 1, "offset": "4 0 0"}],
              "operator": [{"name": "maintaindistancebetweencontrolpoints"}]
            """), ""),
            (Self.burst(1, extra: #", "controlpoint": [{"flags": 1}]"#), ""),
            (Self.burst(1, extra: #", "controlpoint": [{"flags": 2}]"#), ""),
            (Self.burst(1, extra: #", "controlpoint": [{"flags": 4}]"#), ""),
            (Self.burst(1, extra: #", "controlpoint": [{"flags": 65536}]"#), ""),
            (plain, #", "flags": 1"#),
        ]
        for trigger in ["eventdeath", "eventfollow"] {
            for (candidate, edge) in candidates {
                let parent = Self.burst(1, lifetime: trigger == "eventdeath" ? 0.005 : 10, renderer: "", extra: """
                , "children": [{"name": "event", "type": "\(trigger)"}]
                """)
                let event = Self.burst(0, renderer: "", extra: """
                , "children": [{"name": "candidate"\(edge)}, {"name": "good"}]
                """)
                var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent,
                                                                  "event": event, "candidate": candidate, "good": plain])
                let config = try XCTUnwrap(Self.root(scene)?.config.children.first?.config)
                XCTAssertEqual(config.children.count, 2, "\(trigger): \(candidate) \(edge)")
                XCTAssertTrue(config.unsupportedChildren.isEmpty)
                let frame = WPEParityParticleFrameContext(cursor: SIMD2(0.5, 0.5))
                scene.advance(dt: 0.01, frames: ["5": frame])
                if trigger == "eventdeath" {
                    scene.advance(dt: 0.01, frames: ["5": frame])
                }
                let batches = scene.drawBatches(for: "5")
                XCTAssertEqual(batches.map(\.key.path), [[.eventGroup(0), .staticChild(0)],
                                                         [.eventGroup(0), .staticChild(1)]])
                XCTAssertEqual(batches.map(\.vertices.count), [1, 1])
                XCTAssertTrue(batches.allSatisfy { Support.floats($0.vertices.bytes, at: 0, count: 3).allSatisfy(\.isFinite) })
                let spawned = try XCTUnwrap(Self.root(scene)?.eventChildren[0].first)
                if !edge.isEmpty {
                    XCTAssertEqual(spawned.children[0].controlPointCount, 8, "22c3c0 bulk flag forces eight CP slots")
                }
            }
        }
    }

    func testHotZeroCountLetsTheNestedTreeFinishAfterLiveSlotsAndDurationExpire() throws {
        let parent = Self.burst(1, lifetime: 0.005, extra: #", "children": [{"name": "event", "type": "eventdeath"}]"#)
        let event = Self.burst(0, renderer: "", extra: #", "children": [{"name": "leaf"}]"#)
        let leaf = """
        {"maxcount": 1, "material": "materials/plain.json",
         "emitter": [{"name": "boxrandom", "rate": 100, "duration": 0.045, "distancemax": "0 0 0"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.015, "max": 0.015}]}
        """
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "event": event, "leaf": leaf])
        scene.advance(dt: 0.01, frames: ["5": .init()])
        scene.advance(dt: 0.01, frames: ["5": .init()])
        let oldLeaf = try XCTUnwrap(Self.root(scene)?.eventChildren[0].first?.children.first)
        XCTAssertEqual(oldLeaf.liveCount, 1)
        var state = try Self.state()
        state.setScriptField("instance.count", of: "5", to: .vector(.zero), invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        let applied = try XCTUnwrap(Self.root(scene)?.eventChildren[0].first?.children.first)
        XCTAssertEqual(applied.capacity, oldLeaf.capacity)
        XCTAssertEqual(applied.position, oldLeaf.position)
        XCTAssertEqual(applied.liveCount, 1, "count=0 must not kill the existing slot")
        scene.advance(dt: 0.01, frames: ["5": .init()])
        scene.advance(dt: 0.01, frames: ["5": .init()])
        let pending = try XCTUnwrap(Self.root(scene)?.eventChildren[0].first)
        XCTAssertEqual(pending.children[0].liveCount, 0)
        XCTAssertGreaterThan(pending.children[0].emitterStates[0].durationLeft, 0)
        XCTAssertFalse(pending.isFinished, "native active emitter remains until its duration ends")
        scene.advance(dt: 0.01, frames: ["5": .init()])
        scene.advance(dt: 0.01, frames: ["5": .init()])
        let finished = try XCTUnwrap(Self.root(scene))
        XCTAssertTrue(finished.eventChildren[0].isEmpty)
        XCTAssertEqual(finished.finishedEventChildren[0].count, 1)
    }

    func testLocalFollowHotSnapshotAndZeroCountPreserveOldLiveWhileTheRawSlotIsReused() throws {
        let parent = """
        {"maxcount": 1, "material": "materials/plain.json",
         "emitter": [{"name": "boxrandom", "rate": 10,
                      "distancemin": "0 0 0", "distancemax": "0 0 0", "directions": "1 1 1"}],
         "initializer": [{"name": "lifetimerandom", "min": 0.15, "max": 0.15},
                         {"name": "velocityrandom", "min": "100 0 0", "max": "100 0 0"}],
         "operator": [{"name": "movement"}],
         "children": [{"name": "follow", "type": "eventfollow", "origin": "3 0 0", "maxcount": 2}]}
        """
        let follow = Self.burst(1, lifetime: 0.25, extra: """
        , "operator": [{"name": "inheritvaluefromevent", "input": "setcolor"}],
          "children": [{"name": "leaf", "origin": "5 0 0"}]
        """)
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "follow": follow,
                                                          "leaf": Self.burst(1, lifetime: 0.25, origin: "2 0 0")])
        var state = try Self.state()
        state.setScriptField("instance.colorn", of: "5", to: .vector(SIMD4(1, 0, 0, 0)), invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        state.setScriptField("instance.colorn", of: "5", to: .vector(SIMD4(0, 0, 1, 0)), invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let root = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(root.eventChildren[0].count, 2)
        let old = root.eventChildren[0][0], new = root.eventChildren[0][1]
        XCTAssertEqual(old.parentSlot, -1)
        XCTAssertNil(old.parentSample)
        XCTAssertEqual(old.instanceTransform.columns.3.x, 23)
        XCTAssertEqual(old.children[0].instanceTransform.columns.3.x, 5)
        XCTAssertEqual(new.instanceTransform.columns.3.x, 13)
        XCTAssertEqual(new.children[0].instanceTransform.columns.3.x, 5)
        XCTAssertEqual(old.children[0].frameContext.objectMatrix.columns.3.x, 28)
        XCTAssertEqual(new.children[0].frameContext.objectMatrix.columns.3.x, 18)
        for child in [old, old.children[0]] {
            XCTAssertEqual(child.initialColor[0], SIMD3(1, 0, 0))
            XCTAssertEqual(child.color[0], SIMD3(1, 0, 0), "detached live cannot inherit the reborn blue raw slot")
        }
        for child in [new, new.children[0]] {
            XCTAssertEqual(child.initialColor[0], SIMD3(0, 0, 1), "fresh follow/static births see the existing hot snapshot")
        }
        state.setScriptField("instance.count", of: "5", to: .vector(.zero), invalidating: .particleInstance)
        XCTAssertEqual(scene.applyScriptInstanceFields(state: state), ["5"])
        let applied = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(applied.capacity, 1)
        XCTAssertEqual(applied.eventChildren[0].map(\.liveCount), [1, 1], "hot count zero does not kill live follow slots")
        XCTAssertEqual(applied.eventChildren[0].map(\.capacity), [1, 1])
        for _ in 0 ..< 3 {
            scene.advance(dt: 0.1, frames: ["5": .init()])
        }
        let finished = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(finished.eventChildConstructions, 2)
        XCTAssertTrue(finished.eventChildren[0].isEmpty)
        XCTAssertEqual(finished.finishedEventChildren[0].count, 2)
        XCTAssertTrue(finished.followReferences.isEmpty)
        XCTAssertTrue(scene.drawBatches(for: "5").isEmpty)
    }

    func testN2RejectsAnUnprovedFollowEdgeWithFieldReasonsWithoutPruningHealthySiblings() throws {
        let plain = Self.burst(1)
        let periodic = plain.replacingOccurrences(of: #""instantaneous": 1"#, with: #""instantaneous": 1, "flags": 4"#)
        let cases: [(child: String, edge: String, field: String)] = [
            (periodic, #""type": "eventfollow""#, "emitter"),
            (plain, #""type": "eventfollow", "angles": "invalid""#, "angles"),
            (plain, #""type": "eventfollow", "scale": "2 0 1""#, "scale"),
            (plain, #""type": "eventfollow", "flags": 2"#, "child.flags"),
            (plain, #""flags": 2"#, "type"),
        ]
        for (bad, edge, field) in cases {
            let parent = Self.burst(1, extra: """
            , "children": [{"name": "legacy"}, {"name": "bad", \(edge)}, {"name": "good", "type": "eventspawn"}]
            """)
            let scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "legacy": plain,
                                                              "bad": bad, "good": plain])
            let root = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(root.config.children.map(\.trigger), [.always, .spawn], field)
            XCTAssertEqual(root.children.count, 1)
            XCTAssertEqual(root.eventChildren.count, 1)
            XCTAssertTrue(root.config.unsupportedChildren.contains {
                $0.path == [.eventGroup(0)] && $0.asset == "bad" && $0.field.contains(field) && !$0.reason.isEmpty
            }, field)
        }
        // Closed native world/history/parent-copy ancestry must not retain the old N2 rejection.
        for ancestor in [#", "flags": 1"#,
                         #", "operator": [{"name": "maintaindistancetocontrolpoint"}]"#,
                         #", "controlpoint": [{"flags": 4}]"#] {
            let parent = Self.burst(1, origin: "0 0 1", extra: ancestor + """
            , "children": [{"name": "legacy"}, {"name": "follow", "type": "eventfollow"},
                           {"name": "good", "type": "eventspawn"}]
            """)
            var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "legacy": plain,
                                                              "follow": plain, "good": plain])
            let root = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(root.config.children.map(\.trigger), [.always, .follow, .spawn])
            XCTAssertTrue(root.config.unsupportedChildren.isEmpty)
            scene.advance(dt: 0.1, frames: ["5": .init()])
            XCTAssertEqual(scene.drawBatches(for: "5").map(\.key.path),
                           [[], [.staticChild(0)], [.eventGroup(0)], [.eventGroup(1)]])
        }
        // A finite nonsingular local TRS ancestor now admits the follow branch as well as its healthy sibling.
        let parent = Self.burst(1, extra: #", "children": [{"name": "ancestor", "angles": "0 0 1"}, {"name": "good"}]"#)
        let ancestor = Self.burst(1, extra: #", "children": [{"name": "bad", "type": "eventfollow"}, {"name": "good"}]"#)
        let scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "ancestor": ancestor,
                                                          "bad": plain, "good": plain])
        let root = try XCTUnwrap(Self.root(scene))
        XCTAssertEqual(root.children.count, 2)
        XCTAssertEqual(root.children[0].children.count, 1)
        XCTAssertEqual(root.children[0].eventChildren.count, 1)
        XCTAssertFalse(root.children[0].config.unsupportedChildren.contains { $0.field == "angles" })
        let periodicParent = Self.burst(1, extra: #", "children": [{"name": "bad", "type": "eventfollow"}, {"name": "good"}]"#)
            .replacingOccurrences(of: #""instantaneous": 1"#, with: #""instantaneous": 1, "flags": 4"#)
        let periodicScene = try Self.scene(Self.five, particles: ["particles/fx.json": periodicParent,
                                                                  "bad": plain, "good": plain])
        let periodicRoot = try XCTUnwrap(Self.root(periodicScene))
        XCTAssertEqual(periodicRoot.children.count, 1)
        XCTAssertTrue(periodicRoot.eventChildren.isEmpty)
        XCTAssertTrue(periodicRoot.config.unsupportedChildren.contains { $0.field == "emitter[0].flags" })
    }

    func testLocalStaticChildUsesRadianXYZRotationAndNegativeScaleOnlyInItsBatchModel() throws {
        let parent = Self.burst(0, renderer: "", extra: """
        , "children": [{"name": "leaf", "origin": "5 7 11", "angles": "1.5707963267948966 1.5707963267948966 1.5707963267948966",
                        "scale": "-2 3 4"}]
        """)
        let leaf = """
        {"maxcount": 1, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0, "origin": "2 1 3"}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "velocityrandom", "min": "4 5 6", "max": "4 5 6"}],
         "renderer": [{"name": "sprite"}]}
        """
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent, "leaf": leaf])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let root = try XCTUnwrap(Self.root(scene))
        let child = try XCTUnwrap(root.children.first)
        XCTAssertEqual(child.position[0], SIMD3(2, 1, 3))
        XCTAssertEqual(child.velocity[0], SIMD3(4, 5, 6), "TRS must not rotate raw SoA velocity a second time")
        let batch = try XCTUnwrap(scene.drawBatches(for: "5").first)
        XCTAssertEqual(batch.key.path, [.staticChild(0)])
        // Rx90 -> Ry90 -> Rz90 maps (x,y,z) to (z,y,-x); scale applies first.
        let expected = simd_float4x4(SIMD4(0, 0, 2, 0), SIMD4(0, 3, 0, 0), SIMD4(4, 0, 0, 0), SIMD4(5, 7, 11, 1))
        for column in 0 ..< 4 {
            for row in 0 ..< 4 {
                XCTAssertEqual(batch.modelMatrix[column][row], expected[column][row], accuracy: 2e-6)
            }
        }
        let placed = batch.modelMatrix * SIMD4<Float>(2, 1, 3, 1)
        for axis in 0 ..< 3 {
            XCTAssertEqual(placed[axis], SIMD3<Float>(17, 10, 15)[axis], accuracy: 5e-6)
        }
        let oracle = WPEParityMT19937(seed: 7)
        for _ in 0 ..< 12 {
            _ = oracle.next()
        } // shape3/fallback3/speed/birthU/life/velocity3; TRS adds no words.
        XCTAssertEqual(root.rng.next(), oracle.next())
    }

    func testUnsafeStaticTRSEdgeReportsItsPathWithoutPruningHealthySiblings() throws {
        for (edge, field) in [(#""angles": "invalid""#, "angles"),
                              (#""scale": "1 0 1""#, "scale"),
                              (#""origin": "1e40 0 0""#, "origin")] {
            let parent = Self.burst(0, renderer: "", extra: """
            , "children": [{"name": "bad", \(edge)}, {"name": "good", "scale": "-1 1 1"}]
            """)
            var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent,
                                                              "bad": Self.burst(1), "good": Self.burst(1)])
            let root = try XCTUnwrap(Self.root(scene))
            XCTAssertEqual(root.children.count, 1)
            XCTAssertTrue(root.config.unsupportedChildren.contains {
                $0.path == [.staticChild(0)] && $0.asset == "bad" && $0.field == field && !$0.reason.isEmpty
            })
            scene.advance(dt: 0.1, frames: ["5": .init()])
            XCTAssertEqual(scene.drawBatches(for: "5").map(\.key.path), [[.staticChild(0)]])
        }
    }

    func testOverrideColorNeedsNoHasColorAndBrightnessNeedsHDR() throws {
        let override: [String: Any] = ["color": "255 0 0", "brightness": 2, "alpha": 0.5]
        let objects: [[String: Any]] = [
            ["id": 5, "name": "a", "particle": "particles/fx.json", "instanceoverride": override],
            ["id": 6, "name": "b", "particle": "particles/hascolor.json", "instanceoverride": override],
        ]
        let files = ["particles/fx.json": Self.burst(1),
                     "particles/hascolor.json": Self.burst(1, extra: #", "hascolor": true"#)]
        var hdr = WPEEngineComboFlags()
        hdr.hdr = true
        for (flags, brightness) in [(WPEEngineComboFlags(), Float(1)), (hdr, 2)] {
            var scene = try Self.scene(objects, particles: files, flags: flags)
            scene.advance(dt: 0.1, frames: ["5": .init(), "6": .init()])
            for (id, color) in [("5", SIMD3<Float>(1, 0, 0)), ("6", SIMD3<Float>(1, 1, 1))] {
                let bytes = scene.batches(for: WPEParityParticleDrawKey(objectID: id, renderer: 0)).first?.bytes ?? []
                XCTAssertEqual(Support.floats(bytes, at: 28, count: 4),
                               [color.x * brightness, color.y * brightness, color.z * brightness, 0.5], id)
            }
        }
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
