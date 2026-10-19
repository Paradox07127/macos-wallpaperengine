import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

final class ParityParticlePeriodicRestartTests: XCTestCase {
    private typealias Support = ParityParticleTestSupport

    private struct Loaded {
        var scene: WPEParityParticleScene
        var diagnostics: [WPEParitySceneDiagnostic]
    }

    private static func load(_ particles: [String: String], override: [String: Any]? = nil, seed: UInt32 = 7) throws -> Loaded {
        var object: [String: Any] = ["id": 5, "name": "fx", "particle": "particles/fx.json"]
        object["instanceoverride"] = override
        var files: [String: Data] = ["materials/plain.json": Data(#"{"passes": [{"shader": "genericparticle"}]}"#.utf8)]
        for (path, text) in particles {
            files[path] = Data(text.utf8)
        }
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: [
                "camera": ["center": "0 0 0"],
                "general": ["orthogonalprojection": ["width": 1920, "height": 1080]], "objects": [object],
            ]),
            userValues: [:]
        )
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(URL(fileURLWithPath: "/")) { snapshot[$0] }])
        var diagnostics: [WPEParitySceneDiagnostic] = []
        _ = WPEParityProgramScene.particleDraws(objectID: "5", path: "particles/fx.json", assets: assets,
                                                diagnostics: &diagnostics)
        let scene = WPEParityParticleScene(document: document, assets: assets, engineFlags: WPEEngineComboFlags(),
                                           seed: seed)
        return Loaded(scene: scene, diagnostics: diagnostics)
    }

    private static func root(_ scene: WPEParityParticleScene) throws -> WPEParityParticleSystem {
        try XCTUnwrap(scene.objects.first { $0.id == "5" }?.system)
    }

    /// The lightning preset's follow spawner: system flags 248, a periodic emitter and a restarting static beam.
    private static let lightning: [String: String] = [
        "particles/fx.json": """
        {"maxcount": 1, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}],
         "renderer": [{"name": "sprite"}],
         "children": [{"name": "spawner", "type": "eventfollow", "flags": 1, "probability": 1}]}
        """,
        "spawner": """
        {"maxcount": 4, "flags": 248, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0, "flags": 4,
                      "minperiodicduration": 0.2, "maxperiodicduration": 0.2,
                      "minperiodicdelay": 0.2, "maxperiodicdelay": 0.2}],
         "initializer": [{"name": "lifetimerandom", "min": 2, "max": 2}],
         "renderer": [],
         "children": [{"name": "beam", "type": "static", "flags": 2}]}
        """,
        "beam": """
        {"maxcount": 16, "material": "materials/plain.json",
         "emitter": [{"name": "sphererandom", "rate": 100, "distancemax": 0, "flags": 4,
                      "delay": 0.01, "duration": 0.1, "maxtoemitperperiod": 3,
                      "minperiodicduration": 10, "maxperiodicduration": 10,
                      "minperiodicdelay": 9999, "maxperiodicdelay": 9999}],
         "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10},
                         {"name": "mapsequencebetweencontrolpoints", "count": 8}],
         "renderer": [{"name": "sprite"}]}
        """,
    ]

    func testLightningSpawnerShapedFollowChildParsesAndItsStaticChildBirths() throws {
        var loaded = try Self.load(Self.lightning)
        let unsupported = loaded.diagnostics.filter {
            if case .particleChildUnsupported = $0 {
                return true
            }
            return false
        }
        XCTAssertEqual(unsupported.count, 0, "\(unsupported)")
        for _ in 0 ..< 3 {
            loaded.scene.advance(dt: 0.05, frames: ["5": .init()])
        }
        let spawner = try XCTUnwrap(Self.root(loaded.scene).eventChildren.first?.first)
        XCTAssertEqual(spawner.config.flags, 248)
        XCTAssertGreaterThan(spawner.liveCount, 0)
        XCTAssertEqual(spawner.children.first?.liveCount, 3, "the beam's first period births its maxtoemitperperiod")
        let paths = Support.drawBatches(&loaded.scene, "5").map(\.key.path)
        XCTAssertTrue(paths.contains([.eventGroup(0), .staticChild(0)]), "\(paths)")
    }

    func testPeriodOnEntryRestartsTheStaticChildButKeepsItsLiveParticles() throws {
        var loaded = try Self.load(Self.lightning)
        let dt: Float = 0.05
        var previousTimer: Float = 0
        var liveBefore = 0
        var restarted = false
        for frame in 1 ... 40 {
            loaded.scene.advance(dt: dt, frames: ["5": .init()])
            let spawner = try XCTUnwrap(Self.root(loaded.scene).eventChildren.first?.first)
            let beam = try XCTUnwrap(spawner.children.first)
            let timer = spawner.emitterStates[0].periodTimer
            defer {
                previousTimer = timer
                liveBefore = beam.liveCount
            }
            guard frame > 1, previousTimer <= 0, timer > 0 else { continue }
            restarted = true
            XCTAssertEqual(liveBefore, 3)
            XCTAssertFalse(beam.emitterStates[0].disabled, "restart re-enables an expired emitter")
            XCTAssertEqual(beam.liveCount, liveBefore, "restart keeps live particles")
            XCTAssertEqual(beam.simulationTime, dt, accuracy: 1e-6)
            XCTAssertEqual(beam.emitterStates[0].periodTimer, 0, "the restored delay gates the clock this frame")
            XCTAssertEqual(beam.emitterStates[0].emittedThisPeriod, 0)
            XCTAssertEqual(beam.emitterStates[0].accumulator, 0)
            XCTAssertEqual(beam.emitterStates[0].durationLeft, 0.1)
            XCTAssertEqual(beam.emitterStates[0].delayLeft, 0.01 - dt, accuracy: 1e-6)
            XCTAssertEqual(beam.sequenceStates[1].t, 0)
            loaded.scene.advance(dt: dt, frames: ["5": .init()])
            let next = try XCTUnwrap(Self.root(loaded.scene).eventChildren.first?.first?.children.first)
            XCTAssertEqual(next.liveCount, liveBefore + 3, "the new period births again on top of the kept slots")
            break
        }
        XCTAssertTrue(restarted, "the spawner never re-entered its on phase")
    }

    func testCountFlagIgnoresTheInstanceCountForTheRate() {
        func live(flags: Int, count: Double) -> Int {
            var system = WPEParityParticleSystem(json: Support.json("""
            {"maxcount": 40, "flags": \(flags),
             "emitter": [{"name": "sphererandom", "rate": 20, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 10, "max": 10}]}
            """), instanceOverride: .init(count: count), rng: WPEParityMT19937(seed: 7))
            system.advance(dt: 0.1)
            return system.liveCount
        }
        XCTAssertEqual(live(flags: 0, count: 1), 2)
        XCTAssertEqual(live(flags: 0, count: 3), 6)
        XCTAssertEqual(live(flags: 0x20, count: 3), 2)
    }

    func testSystemFlagsSkipTheirInstanceMultipliers() {
        func born(flags: Int) -> WPEParityParticleSystem {
            var system = WPEParityParticleSystem(json: Support.json("""
            {"maxcount": 1, "flags": \(flags),
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
             "initializer": [{"name": "lifetimerandom", "min": 4, "max": 4}, {"name": "sizerandom", "min": 10, "max": 10},
                             {"name": "velocityrandom", "min": "5 0 0", "max": "5 0 0"}],
             "operator": [{"name": "sizechange", "startvalue": 1, "endvalue": 1}]}
            """), instanceOverride: .init(lifetime: 3, size: 2, speed: 4), rng: WPEParityMT19937(seed: 7))
            system.advance(dt: 0.01)
            return system
        }
        let plain = born(flags: 0)
        XCTAssertEqual(plain.velocity[0].x, 20)
        XCTAssertEqual(plain.lifetime[0], 12)
        XCTAssertEqual(plain.initialSize[0], 10)
        XCTAssertEqual(plain.size[0], 20, "sizechange also scales by the instance size")
        XCTAssertEqual(born(flags: 0x10).velocity[0].x, 5)
        XCTAssertEqual(born(flags: 0x40).lifetime[0], 4)
        let unsized = born(flags: 0x80)
        XCTAssertEqual(unsized.initialSize[0], 5)
        XCTAssertEqual(unsized.size[0], 5)
        XCTAssertEqual(born(flags: 0x100 | 0x10).config.flags, 0x10, "only the low byte of the system flags is kept")
    }

    /// Systems using none of these features keep their exact draw bytes and RNG stream.
    func testSceneWithoutTheseFeaturesKeepsItsDrawBytes() throws {
        let particles: [String: String] = [
            "particles/fx.json": """
            {"maxcount": 24, "material": "materials/plain.json",
             "emitter": [{"name": "sphererandom", "rate": 30, "speedmax": 40, "flags": 4,
                          "minperiodicduration": 0.3, "maxperiodicduration": 0.5,
                          "minperiodicdelay": 0.1, "maxperiodicdelay": 0.2, "maxtoemitperperiod": 9}],
             "initializer": [{"name": "lifetimerandom", "min": 0.3, "max": 0.6}, {"name": "sizerandom"},
                             {"name": "mapsequencebetweencontrolpoints", "count": 5, "flags": 32}],
             "operator": [{"name": "movement", "drag": 1}, {"name": "sizechange", "startvalue": 1, "endvalue": 0.5}],
             "renderer": [{"name": "sprite"}],
             "children": [{"name": "leaf", "flags": 2}, {"name": "spark", "type": "eventdeath", "maxcount": 4}]}
            """,
            "leaf": """
            {"maxcount": 8, "material": "materials/plain.json",
             "emitter": [{"name": "boxrandom", "rate": 12, "duration": 0.4}],
             "initializer": [{"name": "lifetimerandom", "min": 0.5, "max": 0.5}],
             "renderer": [{"name": "sprite"}]}
            """,
            "spark": """
            {"maxcount": 2, "material": "materials/plain.json",
             "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 2, "speedmax": 20}],
             "initializer": [{"name": "lifetimerandom", "min": 0.2, "max": 0.2}],
             "renderer": [{"name": "sprite"}]}
            """,
        ]
        var loaded = try Self.load(particles, override: ["count": 1.5, "speed": 2, "size": 0.5, "lifetime": 1.5])
        var checksum: UInt64 = 0xCBF2_9CE4_8422_2325
        for _ in 0 ..< 90 {
            loaded.scene.advance(dt: 1.0 / 30, frames: ["5": .init()])
            for batch in Support.drawBatches(&loaded.scene, "5") {
                for byte in batch.vertices.bytes {
                    checksum = (checksum ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
                }
            }
        }
        let next = try Self.root(loaded.scene).rng.next()
        checksum = (checksum ^ UInt64(next)) &* 0x0000_0100_0000_01B3
        XCTAssertEqual(checksum, 8_717_294_165_642_755_569)
    }
}
