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
            key.node.append(index)
            Self.keys(child, at: key, into: &keys)
        }
        for (group, child) in system.config.children.filter({ $0.trigger != .always }).enumerated() {
            XCTAssertTrue(child.config.children.isEmpty)
            for index in child.config.renderers.indices {
                var key = node
                key.eventGroup = group
                key.renderer = index
                keys.append(key)
            }
        }
    }

    /// 300 frames of Workshop 3448877775 at seed 1: every draw key's batches hashed, simulation, packing and an
    /// arena-style copy timed apart.
    func testWorkshopSceneBatchesKeepTheirChecksum() throws {
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
        let frames = 300
        for frame in 1 ... frames {
            var contexts: [String: WPEParityParticleFrameContext] = [:]
            for particle in visible {
                contexts[particle.id] = WPEParityParticleFrameContext(time: Float(frame) / 60)
            }
            var start = clock.now
            scene.advance(dt: 1.0 / 60, frames: contexts)
            simulate += clock.now - start
            var offset = 0
            for key in keys {
                start = clock.now
                let batches = scene.batches(for: key)
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
        // Optimized builds round some float math differently and give another value.
        #if DEBUG
        XCTAssertEqual(checksum, 11_516_893_083_052_642_319)
        #endif
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

    func testEachDeathEventIsOneBatchOfItsGroup() throws {
        let parent = Self.burst(2, lifetime: 0.05,
                                extra: #", "children": [{"name": "particles/glow.json", "type": "eventdeath"}]"#)
        var scene = try Self.scene(Self.five, particles: ["particles/fx.json": parent,
                                                          "particles/glow.json": Self.burst(1)])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        scene.advance(dt: 0.1, frames: ["5": .init()])
        let group = scene.batches(for: WPEParityParticleDrawKey(objectID: "5", renderer: 0, eventGroup: 0))
        XCTAssertEqual(group.map(\.count), [1, 1])
        XCTAssertEqual(scene.batches(for: WPEParityParticleDrawKey(objectID: "5", renderer: 0)), [])
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
