import Foundation
@testable import LiveWallpaperProWPE
import simd
import XCTest

extension ParityParticleSceneTests {
    func testParticleDrawKeysAndContainerNodesAgreeOnCaptureAndWorkshopScenes() throws {
        let install = try CorpusFixtures.url("WPE_ASSETS_DIR")
        let capture = try CorpusFixtures.url("WPE_HLSL_CAPTURE_DIR")
        var checked = 0
        for sceneID in ["3509243656", "3660962877"] {
            let directory = capture.appendingPathComponent("scene-sources/\(sceneID)")
            checked += try Self.assertKeysAlign(
                directory, assets: [capture.appendingPathComponent("wpeassets"), install], label: sceneID
            )
        }
        let package = try CorpusFixtures.workshopPackage("3448877775")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-particles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        checked += try Self.assertKeysAlign(root, assets: [install], label: "3448877775")
        XCTAssertGreaterThan(checked, 0, "corpus must exercise particle objects")
    }

    private static func assertKeysAlign(_ directory: URL, assets roots: [URL], label: String) throws -> Int {
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: directory.appendingPathComponent("scene.json")), userValues: [:]
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
        }
        return document.particleObjects.count
    }

    private static func keys(_ system: WPEParityParticleSystem, at node: WPEParityParticleDrawKey,
                             into keys: inout [WPEParityParticleDrawKey]) {
        Self.keys(system.config, at: node, into: &keys)
    }

    private static func keys(_ config: WPEParityParticleConfig, at node: WPEParityParticleDrawKey,
                             into keys: inout [WPEParityParticleDrawKey]) {
        for index in config.renderers.indices {
            var key = node
            key.renderer = index
            keys.append(key)
        }
        for (index, child) in config.children.filter({ $0.trigger == .always }).enumerated() {
            var key = node
            key.path.append(.staticChild(index))
            Self.keys(child.config, at: key, into: &keys)
        }
        for (group, child) in config.children.filter({ $0.trigger != .always }).enumerated() {
            var key = node
            key.path.append(.eventGroup(group))
            Self.keys(child.config, at: key, into: &keys)
        }
    }

    func testWorkshopScenePrewarmAndBatchesFollowTheOwnerUpdateContract() throws {
        let install = try CorpusFixtures.url("WPE_ASSETS_DIR")
        let package = try CorpusFixtures.workshopPackage("3448877775")
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw CorpusFixtures.MissingInput("No workshop 3448877775 scene.pkg")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parity-particles-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try ParityProgramPuppetTests.unpack(package, into: root)
        let document = try WPESceneDocumentParser.parse(
            data: Data(contentsOf: root.appendingPathComponent("scene.json")), userValues: [:]
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
}
