#if !LITE_BUILD && DEBUG
import CryptoKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
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
                    // Rope and ropetrail write only z and w (ropetrail x too with uvscrolling).
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
        }
        print("event-child fixture: \(early) instance draws in frames 1-10, \(last) in frame 180, "
            + "\(renderer.droppedParticleBatches) dropped, share \(renderer.particleShare) bytes")
        XCTAssertGreaterThan(early, 0)
        XCTAssertGreaterThan(last, 60)
        XCTAssertEqual(renderer.droppedParticleBatches, 0)
    }

    func testEventSpawnInstancesFitTheDefaultShareInTheFirstFrame() async throws {
        var root = Self.burstParticle(renderer: [["name": "sprite"]])
        root["maxcount"] = 64
        root["emitter"] = [["name": "sphererandom", "rate": 1000, "distancemax": 0]]
        root["children"] = [["name": "particles/child.json", "type": "eventspawn", "maxcount": 64]]
        let child = Self.burstParticle(renderer: [["name": "sprite"]])
        let (renderer, _) = try await syntheticRenderer(["particles/root.json": root, "particles/child.json": child])
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 30) else { return XCTFail("skipped") }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        let live = try XCTUnwrap(renderer.particleLiveCount("1"))
        let draws = renderer.lastFrameDraws.count { renderer.particleRenderer($0.operation) != nil }
        print("eventspawn fixture: \(live) live particles, \(draws) particle draws, "
            + "\(renderer.droppedParticleBatches) dropped, share \(renderer.particleShare) bytes")
        // Every root particle spawned one instance holding one burst particle: half the live particles are instances.
        XCTAssertGreaterThan(live, 2)
        XCTAssertEqual(draws, 1 + live / 2)
        XCTAssertEqual(renderer.droppedParticleBatches, 0)
    }

    private static func vector(_ value: WPECBufferValue?) -> [Float]? {
        if case let .vector(components)? = value {
            components
        } else {
            nil
        }
    }

    func testEventInstancesBlendInCompleteInstanceOrderThroughProductionRenderer() async throws {
        let parent: [String: Any] = ["maxcount": 2, "material": "materials/plain.json", "renderer": [],
                                     "emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 2, "distancemax": 0]],
                                     "initializer": [["name": "lifetimerandom", "min": 0.03, "max": 0.03]],
                                     "children": [["name": "particles/child.json", "type": "eventdeath", "maxcount": 2]]]
        var child = Self.burstParticle(renderer: [["name": "sprite"], ["name": "sprite"]])
        child["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                                ["name": "sizerandom", "min": 128, "max": 128], ["name": "alpharandom", "min": 0.5, "max": 0.5],
                                ["name": "colorrandom", "min": "0 0 0", "max": "255 0 0"]]
        let (renderer, queue) = try await syntheticRenderer(["particles/root.json": parent, "particles/child.json": child])
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        for _ in 0 ..< 6 {
            guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.02) else { return XCTFail("skipped") }
            await buffer.completed()
            XCTAssertNil(buffer.error)
            let particleCount = renderer.lastFrameDraws.count { renderer.particleRenderer($0.operation) != nil }
            if particleCount == 4 {
                break
            }
        }
        let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
        XCTAssertEqual(draws.count, 4)
        guard draws.count == 4 else { return }
        let colors = draws.map { entry in
            entry.draw.vertexBuffer.contents().load(fromByteOffset: entry.draw.vertexBufferOffset + 28, as: Float.self)
        }
        XCTAssertEqual(colors[0], colors[1])
        XCTAssertEqual(colors[2], colors[3])
        func blended(_ order: [Float]) -> Float {
            order.reduce(0) { $0 * 0.5 + $1 * 0.5 }
        }
        let expected = blended(colors)
        let keyMajor = blended([colors[0], colors[2], colors[1], colors[3]])
        XCTAssertGreaterThan(abs(expected - keyMajor), 3.0 / 255, "fixture must distinguish the wrong order")
        let pixel = try centerPixel(renderer.backbuffer, queue: queue)
        XCTAssertEqual(Float(pixel[0]) / 255, expected, accuracy: 3.0 / 255)
    }

    func testNestedStaticDrawsKeepLocalBirthsAndConsumeEachEventMatrixOnTheGPU() async throws {
        var parent = Self.burstParticle(renderer: [])
        parent["maxcount"] = 2
        parent["emitter"] = [-10, 10].map { x in
            ["name": "sphererandom", "origin": "\(x) 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0] as [String: Any]
        }
        parent["initializer"] = [["name": "lifetimerandom", "min": 0.03, "max": 0.03]]
        parent["children"] = [["name": "particles/event.json", "type": "eventdeath", "origin": "3 0 0", "maxcount": 2]]
        var event = Self.burstParticle(renderer: [])
        event["children"] = [["name": "particles/leaf.json", "origin": "5 0 0"]]
        var leaf = Self.burstParticle(renderer: [["name": "sprite"]])
        leaf["emitter"] = [["name": "sphererandom", "origin": "2 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0]]
        leaf["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                               ["name": "sizerandom", "min": 4, "max": 4]]
        let (renderer, queue) = try await syntheticRenderer(["particles/root.json": parent,
                                                             "particles/event.json": event, "particles/leaf.json": leaf])
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        for _ in 0 ..< 6 {
            guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.02) else { return XCTFail("skipped") }
            await buffer.completed()
            XCTAssertNil(buffer.error)
            if renderer.lastFrameDraws.count == 2 {
                break
            }
        }
        let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
        XCTAssertEqual(draws.count, 2)
        guard draws.count == 2 else { return }
        for (index, entry) in draws.enumerated() {
            let birthX = entry.draw.vertexBuffer.contents().load(fromByteOffset: entry.draw.vertexBufferOffset, as: Float.self)
            XCTAssertEqual(birthX, 2, accuracy: 0.0001, "Event displacement belongs to the model, not the local birth")
            guard case let .matrix(model)? = entry.draw.values(for: .vertex)["g_ModelMatrix"] else {
                return XCTFail("missing model matrix")
            }
            // WPE stores transposed rows. Owner32 + event(±10 + 3) + static5 = model30/50;
            // the local birth2 then lands at pixel32/52. These constants are independent of simulation helpers.
            XCTAssertEqual(model.columns[0][3], index == 0 ? 30 : 50, accuracy: 0.0001)
            XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(index == 0 ? 32 : 52, 32))[0], 255)
        }
        XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(22, 32))[0], 0)
        XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(42, 32))[0], 0)
    }

    func testOrdinaryControlPointTranslationsReachEmitterBirthsAndProductionPixels() async throws {
        var particle = Self.burstParticle(renderer: [["name": "sprite"]])
        particle["maxcount"] = 2
        particle["controlpoint"] = [["id": 0, "offset": "-8 0 0"], ["id": 1, "offset": "8 0 0"]]
        particle["emitter"] = [0, 1].map { index in
            ["name": "sphererandom", "controlpoint": index, "origin": "2 0 0", "rate": 0,
             "instantaneous": 1, "distancemax": 0] as [String: Any]
        }
        particle["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                                   ["name": "sizerandom", "min": 3, "max": 3]]
        let (renderer, queue) = try await syntheticRenderer(["particles/root.json": particle])
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.0625) else { return XCTFail("skipped") }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        XCTAssertEqual(renderer.droppedParticleBatches, 0)
        let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
        XCTAssertEqual(draws.count, 1)
        let draw = try XCTUnwrap(draws.first?.draw)
        let birthX = draw.vertexBuffer.contents().load(fromByteOffset: draw.vertexBufferOffset, as: Float.self)
        XCTAssertEqual(birthX, -6, accuracy: 0.0001, "CP0 -8 plus emitter origin2 remains a local birth")
        // Owner32 + CP(-8/+8) + emitter2 gives26/42; ignoring CP would collapse both sprites to34.
        for x in [26, 42] {
            XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(x, 32))[0], 255)
        }
        XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(34, 32))[0], 0)
    }

    func testLocalFollowMovesItsStaticLeafThenFreezesItWhenTheParentSlotIsReused() async throws {
        var parent = Self.burstParticle(renderer: [])
        parent["emitter"] = [
            ["name": "sphererandom", "origin": "-10 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0],
            ["name": "sphererandom", "origin": "10 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0, "delay": 0.25],
        ]
        parent["initializer"] = [["name": "lifetimerandom", "min": 0.1, "max": 0.1],
                                 ["name": "velocityrandom", "min": "10 0 0", "max": "10 0 0"]]
        parent["operator"] = [["name": "movement"]]
        parent["children"] = [["name": "particles/follow.json", "type": "eventfollow", "origin": "3 0 0", "maxcount": 2]]
        var follow = Self.burstParticle(renderer: [])
        follow["children"] = [["name": "particles/leaf.json", "origin": "5 0 0"]]
        var leaf = Self.burstParticle(renderer: [["name": "sprite"]])
        leaf["emitter"] = [["name": "sphererandom", "origin": "2 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0]]
        leaf["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                               ["name": "sizerandom", "min": 3, "max": 3]]
        let (renderer, queue) = try await syntheticRenderer(["particles/root.json": parent,
                                                             "particles/follow.json": follow, "particles/leaf.json": leaf], budget: 1 << 20)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        // Binary dt is exact. Births are f1/f5; age > .1 kills the first parent at f3. Follow refreshes after
        // movement, then retains the f2 placement when detached. The second parent reuses that same raw slot.
        let expectedModels: [[Float]] = [[30.625], [31.25], [31.25], [31.25], [31.25, 50.625], [31.25, 51.25]]
        for (frame, models) in expectedModels.enumerated() {
            guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.0625) else { return XCTFail("skipped") }
            await buffer.completed()
            XCTAssertNil(buffer.error)
            XCTAssertEqual(renderer.droppedParticleBatches, 0)
            let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
            XCTAssertEqual(draws.count, models.count, "frame \(frame + 1)")
            guard draws.count == models.count else { return }
            for (entry, expected) in zip(draws, models) {
                let birthX = entry.draw.vertexBuffer.contents().load(fromByteOffset: entry.draw.vertexBufferOffset, as: Float.self)
                XCTAssertEqual(birthX, 2, accuracy: 0.0001)
                guard case let .matrix(model)? = entry.draw.values(for: .vertex)["g_ModelMatrix"] else {
                    return XCTFail("missing model matrix")
                }
                XCTAssertEqual(model.columns[0][3], expected, accuracy: 0.0001)
            }
            // Authored size3 packs size1.5, leaving these pixel centers strictly inside/outside the quad.
            // The old leaf survives at x33 after detach; the new leaf moves from x52 to x53 independently.
            XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(frame == 0 ? 32 : 33, 32))[0], 255)
            if frame == 0 || frame == 4 {
                XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(frame == 0 ? 33 : 53, 32))[0], 0)
            }
            if frame >= 4 {
                XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(frame == 4 ? 52 : 53, 32))[0], 255)
            }
        }
    }

    func testNestedStaticEntriesBlendInCompleteEventInstanceOrderWithIndependentColors() async throws {
        var parent = Self.burstParticle(renderer: [])
        parent["maxcount"] = 2
        parent["emitter"] = [["name": "sphererandom", "rate": 0, "instantaneous": 2, "distancemax": 0]]
        parent["initializer"] = [["name": "lifetimerandom", "min": 0.03, "max": 0.03]]
        parent["children"] = [["name": "particles/event.json", "type": "eventdeath", "maxcount": 2]]
        var event = Self.burstParticle(renderer: [["name": "sprite"]])
        event["children"] = [["name": "particles/leaf.json"]]
        var leaf = Self.burstParticle(renderer: [["name": "sprite"]])
        leaf["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                               ["name": "sizerandom", "min": 128, "max": 128],
                               ["name": "alpharandom", "min": 0.5, "max": 0.5],
                               ["name": "colorrandom", "min": "0 0 0", "max": "0 0 0"]]
        let (renderer, queue) = try await syntheticRenderer(["particles/root.json": parent,
                                                             "particles/event.json": event, "particles/leaf.json": leaf])
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        for _ in 0 ..< 6 {
            guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.02) else { return XCTFail("skipped") }
            await buffer.completed()
            XCTAssertNil(buffer.error)
            if renderer.lastFrameDraws.count == 4 {
                break
            }
        }
        let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
        XCTAssertEqual(draws.count, 4)
        guard draws.count == 4 else { return }
        for (entry, expected) in zip(draws, [Float(1), 0, 1, 0]) {
            let red = entry.draw.vertexBuffer.contents().load(fromByteOffset: entry.draw.vertexBufferOffset + 28, as: Float.self)
            XCTAssertEqual(red, expected, accuracy: 0.0001)
        }
        // White0.5 then black0.5, twice: 0 → .5 → .25 → .625 → .3125.
        // Prototype-major order would give .1875; neither reference is derived from the observed vertex colors.
        let output = try centerPixel(renderer.backbuffer, queue: queue)
        for lane in 0 ..< 3 {
            XCTAssertEqual(Float(output[lane]) / 255, 0.3125, accuracy: 3.0 / 255)
        }
    }

    func testLocalChildTRSReachesFollowMatricesPixelsAndReflectedCulling() async throws {
        // T(40,20)*T(4,0)*Rz90*S(2,1)*T(P,0)*T(5,0)*Rz-90*S(sx,3)*T(0,2)
        // gives translation(44, 2P+42), basis diag(sx,6); the unchanged local birth(2,0) lands at44+2sx.
        for (sx, cull) in [(Float(1), "normal"), (-1, "nocull"), (-1, "normal")] {
            let root: [String: Any] = ["maxcount": 1, "material": "materials/plain.json", "renderer": [],
                                       "children": [["name": "particles/parent.json", "origin": "4 0 0",
                                                     "angles": "0 0 \(Float.pi / 2)", "scale": "2 1 1"]]]
            var parent = Self.burstParticle(renderer: [])
            parent["emitter"] = [
                ["name": "sphererandom", "origin": "3 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0],
                ["name": "sphererandom", "origin": "7 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0, "delay": 0.25],
            ]
            parent["initializer"] = [["name": "lifetimerandom", "min": 0.1, "max": 0.1],
                                     ["name": "velocityrandom", "min": "8 0 0", "max": "8 0 0"]]
            parent["operator"] = [["name": "movement"]]
            parent["children"] = [["name": "particles/follow.json", "type": "eventfollow", "origin": "5 0 0",
                                   "angles": "0 0 \(-Float.pi / 2)", "scale": "\(sx) 3 1", "maxcount": 2]]
            var follow = Self.burstParticle(renderer: [])
            follow["children"] = [["name": "particles/leaf.json", "origin": "0 2 0"]]
            var leaf = Self.burstParticle(renderer: [["name": "sprite"]])
            leaf["emitter"] = [["name": "sphererandom", "origin": "2 0 0", "rate": 0, "instantaneous": 1, "distancemax": 0]]
            leaf["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                                   ["name": "sizerandom", "min": 3, "max": 3]]
            let (renderer, queue) = try await syntheticRenderer(["particles/root.json": root, "particles/parent.json": parent,
                                                                 "particles/follow.json": follow, "particles/leaf.json": leaf],
                                                                budget: 1 << 20, ownerOrigin: "40 20 0", particleCullMode: cull)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            // Raw parent moves by .5 before each follow refresh; death on f3 freezes f2. Its slot is reused on f5.
            let expectedYs: [[Float]] = [[49], [50], [50], [50], [50, 57], [50, 58]]
            for (frame, ys) in expectedYs.enumerated() {
                guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.0625) else { return XCTFail("skipped") }
                await buffer.completed()
                XCTAssertNil(buffer.error)
                XCTAssertEqual(renderer.droppedParticleBatches, 0)
                let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
                XCTAssertEqual(draws.count, ys.count, "frame \(frame + 1)")
                guard draws.count == ys.count else { return }
                for (entry, y) in zip(draws, ys) {
                    let bytes = entry.draw.vertexBuffer.contents().advanced(by: entry.draw.vertexBufferOffset)
                    XCTAssertEqual(bytes.load(as: Float.self), 2, accuracy: 0.0001)
                    XCTAssertEqual(bytes.load(fromByteOffset: 4, as: Float.self), 0, accuracy: 0.0001)
                    guard case let .matrix(model)? = entry.draw.values(for: .vertex)["g_ModelMatrix"] else {
                        return XCTFail("missing model matrix")
                    }
                    XCTAssertEqual(model.columns[0][0], sx, accuracy: 0.0001)
                    XCTAssertEqual(model.columns[1][1], 6, accuracy: 0.0001)
                    XCTAssertEqual(model.columns[0][1], 0, accuracy: 0.0001)
                    XCTAssertEqual(model.columns[1][0], 0, accuracy: 0.0001)
                    XCTAssertEqual(model.columns[0][3], 44, accuracy: 0.0001)
                    XCTAssertEqual(model.columns[1][3], y, accuracy: 0.0001)
                    XCTAssertEqual(entry.draw.rasterizer.cullMode, cull == "nocull" ? .none : .back)
                    // Default orientation keeps right=X/up=Y here; negative model X reverses the GS strip winding.
                    let visible = sx > 0 || cull == "nocull"
                    let x = sx > 0 ? 46 : 42
                    let row = 64 - Int(y)
                    XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(x, row))[0], visible ? 255 : 0)
                    XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(sx > 0 ? 42 : 46, row))[0], 0)
                }
            }
        }
    }

    func testAllEventParentChildSpacesReachOriginalGeometryShaderWithTheirActualDrawModels() async throws {
        // 22a360 + 229760 + 2366f0: W=T(16,32), parent raw P=10 (local) or (26,32) (world), B=T3.
        // All four end at (31,32), but local child VB=(2,0), D=T(29,32); world child VB=(31,32), D=I.
        for parentWorld in [false, true] {
            for childWorld in [false, true] {
                var parent = Self.burstParticle(renderer: [])
                parent["flags"] = parentWorld ? 1 : 0
                parent["emitter"] = [["name": "sphererandom", "origin": "10 0 0", "rate": 0,
                                      "instantaneous": 1, "distancemax": 0]]
                parent["initializer"] = [["name": "lifetimerandom", "min": 0.03, "max": 0.03]]
                parent["children"] = [["name": "particles/child.json", "type": "eventdeath", "origin": "3 0 0"]]
                var child = Self.burstParticle(renderer: [["name": "sprite"]])
                child["flags"] = childWorld ? 1 : 0
                child["emitter"] = [["name": "sphererandom", "origin": "2 0 0", "rate": 0,
                                     "instantaneous": 1, "distancemax": 0]]
                child["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                                        ["name": "sizerandom", "min": 4, "max": 4]]
                let (renderer, queue) = try await syntheticRenderer(
                    ["particles/root.json": parent, "particles/child.json": child], ownerOrigin: "16 32 0",
                    requiredOriginalInputs: true
                )
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                for _ in 0 ..< 6 {
                    try await renderParticleFrame(renderer, elapsed: 0.02)
                    if renderer.lastFrameDraws.contains(where: { renderer.particleRenderer($0.operation) != nil }) {
                        break
                    }
                }
                let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
                XCTAssertEqual(draws.count, 1, "parentWorld=\(parentWorld), childWorld=\(childWorld)")
                let draw = try XCTUnwrap(draws.first?.draw)
                let rows: [[Float]] = childWorld
                    ? [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
                    : [[1, 0, 0, 29], [0, 1, 0, 32], [0, 0, 1, 0], [0, 0, 0, 1]]
                try assertParticleDraw(draw, birth: childWorld ? SIMD3(31, 32, 0) : SIMD3(2, 0, 0), modelRows: rows,
                                       right: [1, 0, 0], up: [0, 1, 0])
                XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(31, 32)), [255, 255, 255, 255])
                for x in [15, 47] {
                    XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(x, 32)), [0, 0, 0, 255])
                }
                XCTAssertEqual(renderer.droppedParticleBatches, 0)
            }
        }
    }

    func testNonuniformRadianTRSSeparatesWorldBirthFromLocalDrawAndTransposedOrientationOnTheGPU() async throws {
        // W=T(16,24)Rz(-pi/4)S(2,1), B=Rz(pi/4)S(2,1).
        // Hand multiplication gives M=[[3,-.5],[-1,1.5]]. No production transform computes this oracle.
        // CP0 local birth ignores M: origin(3,4)+shape(1,0)=(4,4), then D sends it to(26,26).
        // World CP0 uses U=W*B: origin is NOT rotated; (16,24)+(3,4)+M*(1,0)=(22,27), D=I.
        for world in [false, true] {
            let root: [String: Any] = ["maxcount": 1, "material": "materials/plain.json", "renderer": [],
                                       "children": [["name": "particles/child.json", "angles": "0 0 \(Float.pi / 4)",
                                                     "scale": "2 1 1"]]]
            var child = Self.burstParticle(renderer: [["name": "sprite"]])
            child["flags"] = world ? 1 : 0
            // Cone1 fixes cosTheta=1; distance1 and +X directions fix the offset independently of the sampled radius.
            child["emitter"] = [["name": "sphererandom", "origin": "3 4 0", "directions": "1 0 0", "sign": "1 0 0",
                                 "distancemin": 1, "distancemax": 1, "speedmin": 2, "speedmax": 2,
                                 "cone": 1, "rate": 0, "instantaneous": 1]]
            child["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                                    ["name": "sizerandom", "min": 4, "max": 4]]
            let (renderer, queue) = try await syntheticRenderer(
                ["particles/root.json": root, "particles/child.json": child], ownerOrigin: "16 24 0",
                ownerAngles: "0 0 \(-Float.pi / 4)", ownerScale: "2 1 1", requiredOriginalInputs: true
            )
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            try await renderParticleFrame(renderer, elapsed: 0.0625)
            let draws = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
            XCTAssertEqual(draws.count, 1)
            let draw = try XCTUnwrap(draws.first?.draw)
            let rows: [[Float]] = world
                ? [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
                : [[3, -0.5, 0, 16], [-1, 1.5, 0, 24], [0, 0, 1, 0], [0, 0, 0, 1]]
            // Screen U before the final transpose is M*Y=(-.5,1.5), then M^T*U=(-3,2.5).
            // An inverse would return Y instead; the actual GS consumes these skewed, normalized axes.
            let root61 = Float(61).squareRoot()
            try assertParticleDraw(draw, birth: world ? SIMD3(22, 27, 0) : SIMD3(4, 4, 0), modelRows: rows,
                                   right: world ? [1, 0, 0] : [5 / root61, 6 / root61, 0],
                                   up: world ? [0, 1, 0] : [-6 / root61, 5 / root61, 0])
            let point = world ? SIMD2(22, 37) : SIMD2(26, 38) // scene Y-up → texture row = 64-Y
            XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: point), [255, 255, 255, 255])
            if world {
                // The old post-transform of the entire emitter origin would put the world particle at(26,26).
                XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(26, 38)), [0, 0, 0, 255])
            }
            XCTAssertEqual(try pixel(renderer.backbuffer, queue: queue, at: SIMD2(42, 32)), [0, 0, 0, 255])
            XCTAssertEqual(renderer.droppedParticleBatches, 0)
        }
    }

    func testCompositeWorldParentPostOwnModelReachesOriginalGSAndMissingBasePrunesItsSubtree() async throws {
        // Parent image T(12,10), particle local T(8,0): W=T(20,10), C=T(-12,-10).
        // A material-ready world root has no live particles/renderers, but post-own D=E=W still applies.
        // Local static B=T5, VB2: D=T(25,10), position(27,10), FBO pixel(32+27,32-10)=(59,22).
        // Uniformly applying C*W*B would instead produce FBO pixel(47,32).
        for missingBase in [false, true] {
            let root: [String: Any] = ["maxcount": 1, "flags": 1,
                                       "material": missingBase ? "materials/missing.json" : "materials/plain.json",
                                       "renderer": [], "children": [["name": "particles/leaf.json", "origin": "5 0 0"]]]
            var leaf = Self.burstParticle(renderer: [["name": "sprite"]])
            leaf["emitter"] = [["name": "sphererandom", "origin": "2 0 0", "rate": 0,
                                "instantaneous": 1, "distancemax": 0]]
            leaf["initializer"] = [["name": "lifetimerandom", "min": 10, "max": 10],
                                   ["name": "sizerandom", "min": 4, "max": 4]]
            let (renderer, queue) = try await syntheticRenderer(
                ["particles/root.json": root, "particles/leaf.json": leaf], composited: true,
                parentOrigin: "12 10 0", compositeChildOrigin: "8 0 0", requiredOriginalInputs: true
            )
            if !missingBase {
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            }
            try await renderParticleFrame(renderer, elapsed: 0.0625)
            let frame = renderer.frames[0]
            var plannedParticle: WPEParitySceneDraw?
            for index in frame.draws.keys.sorted() {
                if case let .scene(description)? = frame.draws[index], case .particles = description.geometry {
                    plannedParticle = description
                    break
                }
            }
            let description = try XCTUnwrap(plannedParticle)
            XCTAssertEqual(description.compositeOwnerID, "2")
            XCTAssertNotEqual(description.target, WPEParitySceneResource.backbuffer)
            let composite = try XCTUnwrap(renderer.targets[description.target])
            let resource = try XCTUnwrap(frame.resources.first { $0.id == description.target })
            XCTAssertEqual(resource.lifetime, .pooled, "The observed parent target survives its last reader")
            XCTAssertEqual([composite.width, composite.height], [64, 64])
            XCTAssertTrue(renderer.lastFrameDraws.contains { entry in
                entry.draw.textures["g_Texture0"] === composite
            }, "The parent effect must really consume the particle's target")
            let particles = renderer.lastFrameDraws.filter { renderer.particleRenderer($0.operation) != nil }
            XCTAssertEqual(particles.count, missingBase ? 0 : 1)
            if missingBase {
                XCTAssertNotNil(renderer.particleMaterialSkips["1"], "Missing base material remains an explicit failure")
            } else {
                let draw = try XCTUnwrap(particles.first?.draw)
                try assertParticleDraw(draw, birth: SIMD3(2, 0, 0),
                                       modelRows: [[1, 0, 0, 25], [0, 1, 0, 10], [0, 0, 1, 0], [0, 0, 0, 1]],
                                       right: [1, 0, 0], up: [0, 1, 0])
            }
            XCTAssertEqual(try pixel(composite, queue: queue, at: SIMD2(59, 22)),
                           missingBase ? [0, 0, 0, 0] : [255, 255, 255, 255])
            XCTAssertEqual(try pixel(composite, queue: queue, at: SIMD2(47, 32)), [0, 0, 0, 0])
            XCTAssertGreaterThan(renderer.lastFrameDraws.count { renderer.particleRenderer($0.operation) == nil }, 0,
                                 "Material prune must retain the healthy image/effect draws")
            XCTAssertEqual(renderer.droppedParticleBatches, 0)
        }
    }

    private func renderParticleFrame(_ renderer: WPEParityFrameRenderer, elapsed: Double) async throws {
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: elapsed) else {
            throw NSError(domain: "WPEParityParticleSceneTests.RequiredFrame", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required particle frame was skipped"])
        }
        await buffer.completed()
        XCTAssertNil(buffer.error)
    }

    private func assertParticleDraw(_ draw: WPEParityDraw, birth: SIMD3<Float>, modelRows: [[Float]],
                                    right: [Float], up: [Float]) throws {
        XCTAssertNotNil(draw.pipeline.geometry, "This guard must traverse the original geometry shader")
        XCTAssertEqual(draw.primitiveType, .point)
        XCTAssertEqual(draw.vertexCount, 1)
        let bytes = draw.vertexBuffer.contents().advanced(by: draw.vertexBufferOffset)
        for lane in 0 ..< 3 {
            XCTAssertEqual(bytes.load(fromByteOffset: lane * 4, as: Float.self), birth[lane], accuracy: 0.0001)
        }
        guard case let .matrix(model)? = draw.values(for: .vertex)["g_ModelMatrix"] else {
            throw NSError(domain: "WPEParityParticleSceneTests.RequiredModel", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Particle draw has no actual model uniform"])
        }
        guard model.columns.count == 4, model.columns.allSatisfy({ $0.count == 4 }) else {
            throw NSError(domain: "WPEParityParticleSceneTests.RequiredModel", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Particle model uniform is not a 4x4 matrix"])
        }
        // WPE cbuffer matrices contain transposed rows; each SIMD column here is one mathematical D row.
        for row in 0 ..< 4 {
            for column in 0 ..< 4 {
                XCTAssertEqual(model.columns[row][column], modelRows[row][column], accuracy: 0.0001)
            }
        }
        for (name, expected) in [("g_OrientationForward", [Float(0), 0, 1]),
                                 ("g_OrientationRight", right), ("g_OrientationUp", up)] {
            let actual = try XCTUnwrap(Self.vector(draw.values(for: .geometry)[name]), name)
            XCTAssertGreaterThanOrEqual(actual.count, 3, name)
            for lane in 0 ..< min(actual.count, 3) {
                XCTAssertEqual(actual[lane], expected[lane], accuracy: 0.0001, name)
            }
        }
    }

    func testLiveOneParticleRopeSnapshotsBeforeFollowingHealthySpriteEvenWhenArenaDropsDraws() async throws {
        let root: [String: Any] = ["maxcount": 1, "material": "materials/plain.json", "renderer": [],
                                   "children": ["rope", "sprite", "refract"].map { ["name": "particles/\($0).json", "type": "static"] }]
        let rope = Self.burstParticle(renderer: [["name": "rope"]], material: "materials/refract.json")
        let sprite = Self.burstParticle(renderer: [["name": "sprite"]])
        let refract = Self.burstParticle(renderer: [["name": "sprite"]], material: "materials/refract.json")
        let files: [String: Any] = ["particles/root.json": root, "particles/rope.json": rope,
                                    "particles/sprite.json": sprite, "particles/refract.json": refract]
        for budget in [nil, 0] as [Int?] {
            let (renderer, queue) = try await syntheticRenderer(files, clear: "0 0 1", budget: budget)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.02) else { return XCTFail("skipped") }
            await buffer.completed()
            XCTAssertNil(buffer.error)
            let snapshot = try XCTUnwrap(renderer.targets[WPEParitySceneResource.fullFrameBuffer])
            XCTAssertEqual(try centerPixel(snapshot, queue: queue), [0, 0, 255, 255])
            if budget == nil {
                XCTAssertGreaterThan(try centerPixel(renderer.backbuffer, queue: queue)[0], 0, "healthy sprite never drew")
            } else {
                XCTAssertGreaterThan(renderer.droppedParticleBatches, 0)
            }
        }
    }

    /// Scene 9000107's instance alpha script: stop in init, emitParticles(1) at 1 s and (3) at 3 s.
    func testScriptStopAndEmitParticlesReachTheProductionParticleScene() async throws {
        let script = """
        let start = 0; let phase = -1;
        export function init(value) { start = engine.runtime; thisLayer.stop(); return value; }
        export function update(value) {
            let t = engine.runtime - start; let next = t < 1 ? 0 : t < 3 ? 1 : 2;
            if (next !== phase) { phase = next; if (phase === 1) thisLayer.emitParticles(1); if (phase === 2) thisLayer.emitParticles(3); }
            return (phase + 1) / 4;
        }
        """
        var particle = Self.burstParticle(renderer: [["name": "sprite"]])
        particle["maxcount"] = 8
        let (renderer, _) = try await syntheticRenderer(["particles/root.json": particle],
                                                        instanceOverride: ["alpha": ["value": 1, "script": script]])
        let engine = try XCTUnwrap(renderer.script?.engine)
        for frame in 1 ... 105 {
            try await renderParticleFrame(renderer, elapsed: 1.0 / 30)
            if frame < 29 {
                XCTAssertEqual(renderer.particleLiveCount("1"), 0, "init's stop would let the burst through at frame \(frame)")
            }
            if frame == 45 {
                XCTAssertEqual(renderer.particleLiveCount("1"), 1)
            }
        }
        XCTAssertEqual(renderer.particleLiveCount("1"), 4)
        XCTAssertEqual(engine.exceptionCount, 0, engine.exceptions.joined(separator: "\n"))
    }

    func testAudioResponsiveEmitterReadsTheRenderedSpectrum() async throws {
        let particle: [String: Any] = [
            "maxcount": 64, "material": "materials/plain.json", "renderer": [["name": "sprite"]],
            "emitter": [["name": "sphererandom", "rate": 60, "distancemax": 0, "audioprocessingmode": 3]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
        ]
        let full = [Float](repeating: 1, count: 64)
        for loud in [false, true] {
            let (renderer, _) = try await syntheticRenderer(["particles/root.json": particle])
            for _ in 0 ..< 30 {
                let input = WPEParityFrameInput(audio: loud ? (left: full, right: full) : nil)
                guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 30, input: input) else {
                    return XCTFail("skipped")
                }
                await buffer.completed()
                XCTAssertNil(buffer.error)
            }
            if loud {
                XCTAssertGreaterThan(renderer.particleLiveCount("1") ?? 0, 0, "full-scale spectrum never reached the emitter")
            } else {
                XCTAssertEqual(renderer.particleLiveCount("1"), 0, "silence must not emit an audio-responsive particle")
            }
        }
    }

    private static func burstParticle(renderer: [[String: Any]], material: String = "materials/plain.json") -> [String: Any] {
        ["maxcount": 1, "material": material, "renderer": renderer,
         "emitter": [["name": "sphererandom", "rate": 0, "instantaneous": 1, "distancemax": 0]],
         "initializer": [["name": "lifetimerandom", "min": 10, "max": 10],
                         ["name": "sizerandom", "min": 128, "max": 128],
                         ["name": "alpharandom", "min": 0.5, "max": 0.5]]]
    }

    func testCompositedParticleSnapshotsCurrentParentTargetInsteadOfSceneBackbuffer() async throws {
        let rope = Self.burstParticle(renderer: [["name": "rope"]], material: "materials/refract.json")
        let (renderer, queue) = try await syntheticRenderer(["particles/root.json": rope], clear: "0 0 1", composited: true)
        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.02) else { return XCTFail("skipped") }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        let snapshot = try XCTUnwrap(renderer.targets[WPEParitySceneResource.fullFrameBuffer])
        XCTAssertEqual(try centerPixel(snapshot, queue: queue), [0, 0, 0, 0])
    }

    func testIncompatibleParticleSnapshotIsExplicitAndKeepsHealthyParentAndHistory() async throws {
        let rope = Self.burstParticle(renderer: [["name": "rope"]], material: "materials/refract.json")
        let (renderer, queue) = try await syntheticRenderer(["particles/root.json": rope], clear: "0 0 1",
                                                            composited: true, parentSize: 32)
        XCTAssertFalse(renderer.skipped.isEmpty)
        XCTAssertTrue(renderer.skipped.values.allSatisfy { $0.description.contains("incompatible dimensions or format") })
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 0.02) else { return XCTFail("skipped") }
        await buffer.completed()
        XCTAssertNil(buffer.error)
        XCTAssertGreaterThan(renderer.lastFrameDraws.count, 0, "healthy parent was lost")
        let snapshot = try XCTUnwrap(renderer.targets[WPEParitySceneResource.fullFrameBuffer])
        XCTAssertEqual(try centerPixel(snapshot, queue: queue), [0, 0, 255, 255])
    }

    private func syntheticRenderer(_ objects: [String: Any], clear: String = "0 0 0", budget: Int? = nil,
                                   composited: Bool = false, parentSize: Int = 64, ownerOrigin: String = "32 32 0",
                                   particleCullMode: String? = nil, ownerAngles: String = "0 0 0", ownerScale: String = "1 1 1",
                                   parentOrigin: String = "32 32 0", compositeChildOrigin: String = "0 0 0",
                                   requiredOriginalInputs: Bool = false,
                                   instanceOverride: [String: Any]? = nil) async throws
        -> (WPEParityFrameRenderer, MTLCommandQueue) {
        let home = try URL(fileURLWithPath: String(cString: XCTUnwrap(getpwuid(getuid())).pointee.pw_dir))
        let engine = ProcessInfo.processInfo.environment["WPE_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
            ?? home.appending(path: "Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
        if requiredOriginalInputs {
            for (file, expected) in [
                ("genericparticle.vert", "43fd60ac760a57072b5e57ce93f46142c22b2f19aa0942bcf47cfd58752f6224"),
                ("genericparticle.geom", "b0047bfbbff1da70654681a06885ea4893ca7ccd7b7647bbbe6b04ec7fd4ba13"),
                ("genericparticle.frag", "aed28ef81a5d870c07bc6cfa6bd17b6adf388efb352bd1fd8d1fd3fc0dbf7cd5"),
                ("common_particles.h", "a8a73e28ea5e72c7628d032a11e5f223a996f89fbe9e8318d71b483f0e5078be"),
            ] {
                let data = try Data(contentsOf: engine.appending(path: "shaders/\(file)"))
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(actual, expected, "Required original shader \(file)")
            }
        }
        var files = try objects.mapValues { try JSONSerialization.data(withJSONObject: $0) }
        for (path, combos) in [("materials/plain.json", [:]), ("materials/refract.json", ["REFRACT": 1])] {
            var pass: [String: Any] = ["shader": "genericparticle", "blending": "translucent", "textures": ["white"], "combos": combos]
            if let particleCullMode {
                pass["cullmode"] = particleCullMode
            }
            files[path] = try JSONSerialization.data(withJSONObject: ["passes": [pass]])
        }
        var sceneObjects: [[String: Any]] = [["id": 1, "particle": "particles/root.json", "origin": ownerOrigin,
                                              "angles": ownerAngles, "scale": ownerScale]]
        if let instanceOverride {
            sceneObjects[0]["instanceoverride"] = instanceOverride
        }
        if composited {
            sceneObjects = [
                ["id": 2, "image": "models/parent.json", "size": "\(parentSize) \(parentSize)", "origin": parentOrigin, "color": "1 0 0",
                 "copybackground": false, "effects": [["id": 7, "file": "effects/parent.json"]]],
                ["id": 1, "parent": 2, "particle": "particles/root.json", "origin": compositeChildOrigin,
                 "angles": ownerAngles, "scale": ownerScale],
            ]
            for (path, value) in [
                // Only a passthrough parent draws its children into its composite, cleared to 0 without copybackground.
                "models/parent.json": ["material": "materials/parent.json", "passthrough": true],
                "materials/parent.json": ["passes": [["shader": "genericimage4", "textures": ["white"], "blending": "normal"]]],
                "effects/parent.json": ["passes": [["material": "materials/pass.json"]]],
                "materials/pass.json": ["passes": [["shader": "passthrough", "blending": "normal"]]],
            ] as [String: Any] {
                files[path] = try JSONSerialization.data(withJSONObject: value)
            }
        }
        var white = Data("TEXV0004\0".utf8)
        for value: UInt32 in [0, 0, 1, 1, 1, 1, 1, 1, 1, 4] {
            withUnsafeBytes(of: value.littleEndian) { white.append(contentsOf: $0) }
        }
        white.append(contentsOf: [255, 255, 255, 255])
        files["materials/white.tex"] = white
        let snapshot = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { snapshot[$0] }, .directory(engine)])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": clear],
            "objects": sceneObjects,
        ]), userValues: [:], makeTransformScriptResolver: { _, _ in NoScripts() })
        let plan = try WPEParityFramePlan(document: document, assets: assets, settings: .init(bloom: false), width: 64, height: 64)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let compiler: WPEParityHelperShaderCompiler
        do {
            compiler = try WPEParityHelperShaderCompiler.local(workDirectory: scratch.appending(path: "synthetic-shaderc"))
        } catch {
            guard requiredOriginalInputs else { throw error }
            throw NSError(domain: "WPEParityParticleSceneTests.RequiredToolchain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required current particle toolchain unavailable: \(error)"])
        }
        let store = WPEParityShaderStore(compiler: compiler, diskCache: .init(cachesURL: scratch.appending(path: "cache")))
        let renderer = try await WPEParityFrameRenderer(plan: plan, device: device, queue: queue,
                                                        shaders: .init(store: store, compilerIdentity: compiler.compilerIdentity, bindingABIVersion: 1),
                                                        particleSeed: 7, particleArenaBytes: budget)
        if WPEParitySceneScript.hasScripts(document) {
            try renderer.attachScript(WPEParitySceneScript(
                document: plan.document, state: renderer.state, assets: plan.scene.assets,
                canvasSize: renderer.pathCamera.size,
                screenResolution: SIMD2(Float(renderer.backbuffer.width), Float(renderer.backbuffer.height)),
                materialConstants: plan.materialConstants, resolvedEffectRecords: plan.scene.resolvedEffectRecords,
                host: .init()
            ))
        }
        return (renderer, queue)
    }

    private func centerPixel(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        try pixel(texture, queue: queue, at: SIMD2(texture.width / 2, texture.height / 2))
    }

    private func pixel(_ texture: MTLTexture, queue: MTLCommandQueue, at point: SIMD2<Int>) throws -> [UInt8] {
        let data = try XCTUnwrap(queue.device.makeBuffer(length: 256, options: .storageModeShared))
        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(buffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: point.x, y: point.y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: data, destinationOffset: 0,
                  destinationBytesPerRow: 256, destinationBytesPerImage: 256)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        return Array(UnsafeRawBufferPointer(start: data.contents(), count: 4))
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
        {"maxcount": 64, "material": "\(material)", "renderer": [],
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
    static func local(workDirectory: URL) throws -> Self {
        let tools = try parityShaderToolchainURLs()
        return try Self(helper: tools.helper, dxcompiler: tools.dxcompiler, metalIRConverter: tools.metalIRConverter,
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
