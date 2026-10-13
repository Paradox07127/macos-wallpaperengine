#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

/// Workshop 3448877775 (sprite, spritetrail, rope and ropetrail systems, eventdeath children, REFRACT) compiled by
/// wpe-shaderc and rendered end to end.
final class WPEParityParticleSceneTests: XCTestCase {
    private static let sceneID = "3448877775"
    private static let width = 1920
    private static let height = 1080

    private var scratch: URL!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory.appending(path: "parity-particles-\(UUID().uuidString)",
                                                                   directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testEveryRendererKindDrawsAndRenderVarCarries() async throws {
        let (plan, renderer, _) = try await makeRenderer()
        for (index, skip) in renderer.skipped.sorted(by: { $0.key < $1.key }) {
            XCTFail("operation \(index): \(skip)")
        }
        print("scene \(Self.sceneID): draws \(renderer.drawCount) total, \(renderer.executedDrawCount) executed, "
            + "\(renderer.skipped.count) skipped")
        print("scene \(Self.sceneID): transparent fallback textures "
            + "\(renderer.fallbackTextures.sorted { $0.key < $1.key }.map { "\(plan.programs[$0.key]?.shader ?? "?") \($0.value)" })")
        XCTAssertEqual(renderer.executedDrawCount, renderer.drawCount)

        var drawn: [String: Int] = [:]
        var lastSpriteTrail: [Float]?
        var carried = 0
        var encode = Duration.zero
        let frames = 120
        for frame in 1 ... frames {
            let start = ContinuousClock.now
            let submission = try renderer.encodeFrame(elapsed: 1.0 / 60)
            encode += ContinuousClock.now - start
            guard case let .committed(commandBuffer) = submission else { return XCTFail("frame \(frame) was skipped") }
            await commandBuffer.completed()
            XCTAssertNil(commandBuffer.error, "frame \(frame)")
            for (operation, draw) in renderer.lastFrameDraws {
                guard let entry = renderer.particleRenderer(operation) else {
                    // Bloom and combine_hdr write the same store.
                    if draw.constants.values.contains(where: { $0["g_RenderVar0"] != nil }) {
                        lastSpriteTrail = nil
                    }
                    continue
                }
                if frame <= 60, draw.vertexCount > 0 {
                    drawn["\(entry.kind)", default: 0] += 1
                }
                let rv0 = try XCTUnwrap(Self.vector(draw.constants[.geometry]?["g_RenderVar0"]))
                switch entry.kind {
                case .spriteTrail:
                    lastSpriteTrail = rv0
                case .rope, .ropeTrail:
                    // R16 Q3: rope and ropetrail write only z and w (ropetrail x too with uvscrolling).
                    guard let trail = lastSpriteTrail else { continue }
                    XCTAssertEqual(rv0[1], trail[1], "frame \(frame) operation \(operation)")
                    if !(entry.kind == .ropeTrail && entry.uvScrolling) {
                        XCTAssertEqual(rv0[0], trail[0], "frame \(frame) operation \(operation)")
                    }
                    carried += 1
                default:
                    break
                }
            }
        }
        print("scene \(Self.sceneID): particle draws with vertices over 60 frames by renderer kind \(drawn.sorted { $0.key < $1.key })")
        XCTAssertEqual(Set(drawn.keys), ["sprite", "spriteTrail", "rope", "ropeTrail"])
        XCTAssertGreaterThan(carried, 0, "no rope or ropetrail draw followed a spritetrail draw")
        let milliseconds = Double(encode.components.attoseconds) / 1e15 + Double(encode.components.seconds) * 1000
        print("scene \(Self.sceneID): encodeFrame CPU mean \(String(format: "%.3f", milliseconds / Double(frames))) ms "
            + "over \(frames) frames")
        print("scene \(Self.sceneID): particle share of a frame \(particleShare(plan, frames: frames))")
    }

    /// The scene's particle systems advanced and packed on their own, as `encodeFrame` drives them.
    private func particleShare(_ plan: WPEParityFramePlan, frames: Int) -> String {
        var scene = WPEParityParticleScene(document: plan.document, assets: plan.scene.assets,
                                           engineFlags: plan.scene.engineFlags, seed: 1)
        var ids: [String] = []
        var keys: [WPEParityParticleDrawKey] = []
        for object in plan.scene.scene.objects where object.visible {
            if case let .particle(particle) = object.kind {
                ids.append(object.id)
                keys += particle.draws.map(\.key)
            }
        }
        let clock = ContinuousClock()
        var (advance, pack) = (Duration.zero, Duration.zero)
        for frame in 1 ... frames {
            let contexts = Dictionary(uniqueKeysWithValues: ids.map {
                ($0, WPEParityParticleFrameContext(time: Float(frame) / 60))
            })
            var start = clock.now
            scene.advance(dt: 1.0 / 60, frames: contexts)
            advance += clock.now - start
            start = clock.now
            for key in keys {
                _ = scene.batches(for: key)
            }
            pack += clock.now - start
        }
        func mean(_ duration: Duration) -> String {
            let milliseconds = Double(duration.components.attoseconds) / 1e15
                + Double(duration.components.seconds) * 1000
            return String(format: "%.3f", milliseconds / Double(frames))
        }
        return "advance \(mean(advance)) ms, batches \(mean(pack)) ms over \(keys.count) keys"
    }

    func testTinyParticleArenaDropsBatchesAndKeepsOtherDraws() async throws {
        let (plan, renderer, _) = try await makeRenderer(particleArenaBytes: 256)
        // Objects hidden at load are planned but not encoded.
        let others = plan.frames[0].draws.keys.count { index in
            guard renderer.skipped[index] == nil, renderer.particleRenderer(index) == nil else { return false }
            guard case let .scene(draw)? = plan.frames[0].draws[index] else { return true }
            return plan.state.isVisible(draw.objectID)
        }
        XCTAssertGreaterThan(others, 0)
        for frame in 1 ... 30 {
            guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
                return XCTFail("frame \(frame) was skipped")
            }
            await commandBuffer.completed()
            XCTAssertNil(commandBuffer.error, "frame \(frame)")
            let encoded = renderer.lastFrameDraws.count { renderer.particleRenderer($0.operation) == nil }
            XCTAssertEqual(encoded, others, "frame \(frame)")
        }
        print("scene \(Self.sceneID): \(renderer.droppedParticleBatches) particle batches dropped with a 256-byte share")
        XCTAssertGreaterThan(renderer.droppedParticleBatches, 0)
    }

    func testEventInstancesBeyondTheShareAreDroppedWithoutLosingOtherDraws() async throws {
        // Fits every instance's vertices (about 1500 × 256 bytes) but not their argument tables and cbuffers.
        let (plan, renderer, _) = try await makeRenderer(particleArenaBytes: 1 << 20, eventChildFixture: true)
        let others = plan.frames[0].draws.keys.count {
            renderer.skipped[$0] == nil && renderer.particleRenderer($0) == nil
        }
        XCTAssertGreaterThan(others, 0)
        var particleDraws = 0
        for frame in 1 ... 120 {
            guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
                return XCTFail("frame \(frame) was skipped")
            }
            await commandBuffer.completed()
            XCTAssertNil(commandBuffer.error, "frame \(frame)")
            let encoded = renderer.lastFrameDraws.count { renderer.particleRenderer($0.operation) == nil }
            XCTAssertEqual(encoded, others, "frame \(frame)")
            particleDraws += renderer.lastFrameDraws.count - encoded
        }
        print("event-child fixture: \(renderer.drawCount) planned draws, \(particleDraws) particle draws, "
            + "\(renderer.droppedParticleBatches) dropped with a 1 MiB share")
        XCTAssertGreaterThan(particleDraws, 0)
        XCTAssertGreaterThan(renderer.droppedParticleBatches, 0)
    }

    func testParticleShareGrowsUntilEventOnlyRenderersStopDropping() async throws {
        let (_, renderer, _) = try await makeRenderer(eventChildFixture: true)
        var early = 0
        var last = 0
        var droppedAtFrame120 = 0
        for frame in 1 ... 180 {
            guard case let .committed(commandBuffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
                return XCTFail("frame \(frame) was skipped")
            }
            await commandBuffer.completed()
            XCTAssertNil(commandBuffer.error, "frame \(frame)")
            last = renderer.lastFrameDraws.count { renderer.particleRenderer($0.operation) != nil }
            if frame <= 10 {
                early += last
            }
            if frame == 120 {
                droppedAtFrame120 = renderer.droppedParticleBatches
            }
        }
        print("event-child fixture: \(early) instance draws in frames 1-10, \(last) in frame 180, "
            + "\(renderer.droppedParticleBatches) dropped")
        XCTAssertGreaterThan(early, 0)
        XCTAssertGreaterThan(last, 60)
        XCTAssertEqual(renderer.droppedParticleBatches, droppedAtFrame120)
    }

    private static func vector(_ value: WPECBufferValue?) -> [Float]? {
        if case let .vector(components)? = value {
            components
        } else {
            nil
        }
    }

    private func makeRenderer(particleArenaBytes: Int? = nil, eventChildFixture: Bool = false) async throws
        -> (WPEParityFramePlan, WPEParityFrameRenderer, MTLDevice) {
        let compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "shaderc"))
        let plan = try makePlan(eventChildFixture: eventChildFixture)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Shared between the tests of this class, so only the first compiles cold.
        let cache = FileManager.default.temporaryDirectory.appending(path: "parity-particles-\(Self.sceneID)-cache",
                                                                     directoryHint: .isDirectory)
        let store = WPEParityShaderStore(compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: cache))
        let renderer = try await WPEParityFrameRenderer(
            plan: plan, device: device, queue: XCTUnwrap(device.makeCommandQueue()),
            shaders: WPEParityFrameShaderSource(store: store, compilerIdentity: compiler.compilerIdentity,
                                                bindingABIVersion: 1),
            particleSeed: 1, particleArenaBytes: particleArenaBytes
        )
        return (plan, renderer, device)
    }

    private func makePlan(eventChildFixture: Bool) throws -> WPEParityFramePlan {
        // The sandboxed test host's home is its container; Steam lives in the account's real home.
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let steam = home.appending(path: "Library/Application Support/Steam/steamapps")
        let folder = steam.appending(path: "workshop/content/431960/\(Self.sceneID)", directoryHint: .isDirectory)
        let package = folder.appending(path: "scene.pkg")
        let engineRoot = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? steam.appending(path: "common/wallpaper_engine")
        guard FileManager.default.fileExists(atPath: package.path),
              FileManager.default.fileExists(atPath: engineRoot.appending(path: "assets/materials/util").path) else {
            throw XCTSkip("Needs Workshop \(Self.sceneID) and WPE's assets (or WPE_ASSETS_DIR)")
        }
        var assets = try WPEParitySceneAssets.make(provider: WPEPackageSceneAssetProvider(packageURL: package),
                                                   projectRoot: folder, dependencyMounts: [],
                                                   engineAssetsRootURL: engineRoot)
        if eventChildFixture {
            let files = try Self.eventChildFiles(sceneJSON: XCTUnwrap(assets.data("scene.json")))
            assets = WPEParityProgramAssets(sources: [.lookup(folder) { files[$0] }] + assets.sources)
        }
        let document = try WPESceneDocumentParser.parse(
            data: XCTUnwrap(assets.data("scene.json")), userValues: [:],
            makeTransformScriptResolver: { _, _ in NoScripts() }
        )
        return try WPEParityFramePlan(document: document, assets: assets, settings: WPEParityProgramSettings(),
                                      width: Self.width, height: Self.height)
    }

    /// The scene's railing layer (1266) and one particle object whose only renderer sits in an eventdeath child:
    /// the parent's 0.05 s particles die 1000 times a second, so about 1500 one-particle instances live at once.
    /// An explicit 2000-instance cap exercises arena pressure independently of the native default cap of 10.
    private static func eventChildFiles(sceneJSON: Data) throws -> [String: Data] {
        var scene = try XCTUnwrap(JSONSerialization.jsonObject(with: sceneJSON) as? [String: Any])
        let objects = try XCTUnwrap(scene["objects"] as? [[String: Any]])
        let railing = try XCTUnwrap(objects.first { $0["id"] as? Int == 1266 })
        var particle = try XCTUnwrap(objects.first { $0["id"] as? Int == 1775 })
        particle["id"] = 9001
        particle["particle"] = "particles/w35/parent.json"
        particle["instanceoverride"] = nil
        particle["visible"] = true
        scene["objects"] = [railing, particle]
        let material = "materials/workshop/2829005144/presets/fireworks_halo.json"
        let parent = """
        {"maxcount": 64, "material": "\(material)",
         "emitter": [{"name": "sphererandom", "rate": 1000, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 0.05, "max": 0.05}],
         "children": [{"name": "particles/w35/child.json", "type": "eventdeath", "maxcount": 2000}]}
        """
        let child = """
        {"maxcount": 1, "material": "\(material)",
         "emitter": [{"name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0}],
         "initializer": [{"name": "lifetimerandom", "min": 1.5, "max": 1.5},
                         {"name": "sizerandom", "min": 20, "max": 20}],
         "renderer": [{"name": "sprite"}]}
        """
        return try [
            "scene.json": JSONSerialization.data(withJSONObject: scene),
            "particles/w35/parent.json": Data(parent.utf8),
            "particles/w35/child.json": Data(child.utf8),
        ]
    }
}

extension WPEParityHelperShaderCompiler {
    /// This machine's wpe-shaderc, DXC and Metal Shader Converter, or a skip naming the one that is missing.
    static func local(workDirectory: URL) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        func path(_ key: String, _ fallback: String) -> URL {
            URL(fileURLWithPath: environment[key] ?? fallback)
        }
        let helper = path("WPE_SHADERC", "/Users/example/Developer/wpe-shaderc-build/wpe-shaderc")
        let dxcompiler = path("WPE_DXCOMPILER",
                              "/Users/example/Developer/DirectXShaderCompiler/build-14.6/lib/libdxcompiler.dylib")
        let converter = path("WPE_METALIRCONVERTER", "/usr/local/lib/libmetalirconverter.dylib")
        for url in [helper, dxcompiler, converter] where !FileManager.default.fileExists(atPath: url.path) {
            throw XCTSkip("Missing \(url.path); set WPE_SHADERC, WPE_DXCOMPILER and WPE_METALIRCONVERTER")
        }
        return try Self(helper: helper, dxcompiler: dxcompiler, metalIRConverter: converter,
                        workDirectory: workDirectory)
    }
}

private struct NoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
