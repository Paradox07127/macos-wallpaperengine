#if !LITE_BUILD && DEBUG
import AVFoundation
import CoreVideo
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

@MainActor
final class WPEParityVideoTexturesTests: XCTestCase {
    func testSceneScriptPauseReachesSharedPlayerWithoutRewindingOrReplacingTexture() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let staticTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: texture, bytes: Data(contentsOf: url))],
                                                      workshopID: "parity-video-pause-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["1": texture, "2": texture, "3": staticTexture])
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (videos.playbackSnapshot(ownerID: "1")?.duration ?? 0) <= 0.5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let ready = try XCTUnwrap(videos.playbackSnapshot(ownerID: "1"))
        XCTAssertGreaterThan(ready.duration, 0.5)
        XCTAssertEqual(ready.playbackRequested, true)
        let metadata = videos.scriptFieldDefaults

        let json = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":64,"height":64}},
         "objects":[
          {"id":1,"name":"A","image":"models/shared.json","size":"64 64","alpha":{"value":1,"script":"export function init(value) { const video = thisLayer.getVideoTexture(); const result = video.pause(); thisLayer.color = new Vec3(result === undefined ? 1 : 99, video === thisLayer.getVideoTexture() ? 1 : 99, thisScene.getLayer('static').getVideoTexture() === null ? 1 : 99); return value; } export function update(value) { thisScene.getLayer('B').getVideoTexture().pause(); return value; }"}},
          {"id":2,"name":"B","image":"models/shared.json","size":"64 64"},
          {"id":3,"name":"static","image":"models/static.json","size":"64 64"}]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in VideoNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        // Fixed package fixture: this product bridge guard does not depend on installed Steam or captures.
        let root = (0 ..< 6).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
        let baseClasses = try Data(contentsOf: root.appending(path: "Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js"))
        let assets = WPEParityProgramAssets(sources: [.lookup(root) {
            $0 == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        var observations: [(String, WPEVideoPlaybackSnapshot, WPEVideoPlaybackSnapshot)] = []
        let script = try WPEParitySceneScript(
            document: document, state: state, assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            fieldDefaults: metadata, host: .init(pauseVideoTexture: { owner in
                guard let before = videos.playbackSnapshot(ownerID: owner), videos.pause(ownerID: owner),
                      let after = videos.playbackSnapshot(ownerID: owner) else { return false }
                observations.append((owner, before, after))
                return true
            })
        )
        try script.start(state: &state)
        XCTAssertEqual(state.object("1")?.color, .one)
        XCTAssertEqual(observations.map(\.0), ["1"])
        let first = try XCTUnwrap(observations.first)
        XCTAssertEqual(first.1.playbackRequested, true)
        XCTAssertEqual(first.2.playbackRequested, false)
        XCTAssertFalse(first.2.isPlaying)
        XCTAssertEqual(first.2.currentTime, first.1.currentTime, accuracy: 0.1)
        XCTAssertEqual(first.2.acknowledgedPausedSeekTime, first.1.acknowledgedPausedSeekTime)
        XCTAssertEqual(first.2.sourceGeneration, ready.sourceGeneration)
        XCTAssertEqual(first.2.rate, ready.rate)
        XCTAssertEqual(first.2.loop, ready.loop)
        XCTAssertEqual(first.2.duration, ready.duration)
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "2")?.sourceGeneration, ready.sourceGeneration)
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "2")?.playbackRequested, false)

        script.tick(dt: 0.01, cursor: .zero, world: .zero, leftDown: false, timeOfDay: 0, state: &state)
        XCTAssertEqual(observations.map(\.0), ["1", "2"])
        let second = try XCTUnwrap(observations.last)
        XCTAssertEqual(second.1.playbackRequested, false)
        XCTAssertEqual(second.2.playbackRequested, false)
        XCTAssertEqual(second.2.currentTime, second.1.currentTime, accuracy: 0.05)
        XCTAssertEqual(second.2.sourceGeneration, ready.sourceGeneration)
        XCTAssertFalse(videos.pause(ownerID: "missing"))
        XCTAssertFalse(videos.pause(ownerID: "3"))
        XCTAssertNil(videos.playbackSnapshot(ownerID: "missing"))
        XCTAssertNil(videos.playbackSnapshot(ownerID: "3"))
        XCTAssertEqual(videos.scriptFieldDefaults, metadata)
        XCTAssertTrue(videos.textures[0] === texture)
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testSceneScriptStopAndPlayReachThePlayerAndIsPlayingReadsIt() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: texture, bytes: Data(contentsOf: url))],
                                                      workshopID: "parity-video-command-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["1": texture])
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (videos.playbackSnapshot(ownerID: "1")?.duration ?? 0) <= 0.5 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "1")?.playbackRequested, true)

        let json = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":64,"height":64}},
         "objects":[
          {"id":1,"name":"A","image":"models/shared.json","size":"64 64","alpha":{"value":1,"script":"export function init(value) { thisLayer.getVideoTexture().stop(); return value; } export function update(value) { const video = thisLayer.getVideoTexture(); video.play(); thisLayer.color = new Vec3(video.isPlaying() === true ? 1 : 99, typeof video.getCurrentTime() === 'number' ? 1 : 99, 1); return value; }"}}]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in VideoNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let root = (0 ..< 6).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
        let baseClasses = try Data(contentsOf: root.appending(path: "Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js"))
        let assets = WPEParityProgramAssets(sources: [.lookup(root) {
            $0 == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let script = try WPEParitySceneScript(
            document: document, state: state, assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            fieldDefaults: videos.scriptFieldDefaults, host: .init()
        )
        script.engine.videoTextureHandler = videos.command
        try script.start(state: &state)
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "1")?.playbackRequested, false)

        script.tick(dt: 0.01, cursor: .zero, world: .zero, leftDown: false, timeOfDay: 0, state: &state)
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "1")?.playbackRequested, true)
        XCTAssertEqual(state.object("1")?.color, .one)
        XCTAssertNil(videos.command(ownerID: "missing", .play, argument: 0))
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testLoopingVideoRunsTheEndedCallbackOncePerWrap() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: texture, bytes: Data(contentsOf: url))],
                                                      workshopID: "parity-video-ended-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["1": texture])

        let json = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":64,"height":64}},
         "objects":[
          {"id":1,"name":"A","image":"models/a.json","size":"64 64","alpha":{"value":1,"script":"let ended = 0; export function init(value) { thisLayer.getVideoTexture().addEndedCallback(() => { ended += 1; }); return value; } export function update(value) { thisLayer.origin = new Vec3(ended, 0, 0); return value; }"}}]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in VideoNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let root = (0 ..< 6).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
        let baseClasses = try Data(contentsOf: root.appending(path: "Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js"))
        let assets = WPEParityProgramAssets(sources: [.lookup(root) {
            $0 == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let script = try WPEParitySceneScript(
            document: document, state: state, assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            fieldDefaults: videos.scriptFieldDefaults, host: .init()
        )
        script.engine.videoTextureHandler = videos.command
        try script.start(state: &state)
        // The fixture is one second long; each frame reports ends before the script's update, as the renderer does.
        var increments: [Date] = []
        var count: Float = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, increments.count < 2 {
            script.engine.videoEnded(ownerIDs: videos.takeEndedOwnerIDs(), state: &state)
            script.tick(dt: 0.01, cursor: .zero, world: .zero, leftDown: false, timeOfDay: 0, state: &state)
            let next = state.object("1")?.origin.x ?? 0
            XCTAssertLessThanOrEqual(next - count, 1, "One wrap must fire the callback once")
            if next > count {
                increments.append(Date())
            }
            count = next
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(increments.count, 2, "A looping one-second video wraps twice within five seconds")
        if increments.count == 2 {
            XCTAssertGreaterThan(increments[1].timeIntervalSince(increments[0]), 0.7, "Callbacks fire per wrap, not per frame")
        }
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testVideoUnsampledForMoreThanThirtySubmittedFramesPausesAndResumesWhenSampledAgain() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let textureA = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let textureB = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: textureA, bytes: bytes),
                                                                .init(texture: textureB, bytes: bytes)],
                                                      workshopID: "parity-video-unsampled-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["1": textureA, "2": textureB])
        videos.setBoundSources([0, 1])
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "2")?.isPlaying, true)

        let json = #"""
        {"camera":{"eye":"0 0 0","center":"0 0 -1","up":"0 1 0"},
         "general":{"orthogonalprojection":{"width":64,"height":64}},
         "objects":[
          {"id":1,"name":"A","image":"models/a.json","size":"64 64","alpha":{"value":1,"script":"let frame = 0; export function update(value) { frame += 1; const b = thisScene.getLayer('B'); if (frame === 2) b.visible = false; if (frame === 40) b.visible = true; thisLayer.color = new Vec3(b.getVideoTexture().isPlaying() ? 1 : 0, 1, 1); return value; }"}},
          {"id":2,"name":"B","image":"models/b.json","size":"64 64"}]}
        """#
        let document = try WPESceneDocumentParser.parse(data: Data(json.utf8), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in VideoNoScripts() })
        var state = WPEParitySceneState(document: document, hdr: false)
        let root = (0 ..< 6).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
        let baseClasses = try Data(contentsOf: root.appending(path: "Packages/LiveWallpaperProWPE/Tests/Fixtures/ParityScript/baseclasses.js"))
        let assets = WPEParityProgramAssets(sources: [.lookup(root) {
            $0 == "scripts/jsclasses/baseclasses.js" ? baseClasses : nil
        }])
        let script = try WPEParitySceneScript(
            document: document, state: state, assets: assets, canvasSize: SIMD2(64, 64), screenResolution: SIMD2(64, 64),
            fieldDefaults: videos.scriptFieldDefaults, host: .init()
        )
        script.engine.videoTextureHandler = videos.command
        try script.start(state: &state)
        // One submitted frame: the script runs, then only visible layers' draws execute and sample their video.
        func frame() {
            script.tick(dt: 0.01, cursor: .zero, world: .zero, leftDown: false, timeOfDay: 0, state: &state)
            let sources = ["1": 0, "2": 1]
            videos.recordSampled(sources: sources.filter { state.object($0.key)?.visible == true }.values)
        }
        for _ in 1 ... 32 {
            frame()
        }
        XCTAssertEqual(state.object("2")?.visible, false)
        frame()
        XCTAssertEqual(state.object("1")?.color.x, 0, "B has not been sampled for more than 30 submitted frames")
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "1")?.isPlaying, true, "A is sampled every frame")
        for _ in 34 ... 41 {
            frame()
        }
        XCTAssertEqual(state.object("2")?.visible, true)
        XCTAssertEqual(state.object("1")?.color.x, 1, "B resumes once a draw samples it again")
        XCTAssertEqual(script.engine.exceptionCount, 0, script.engine.exceptions.joined(separator: "\n"))
    }

    func testVideoBoundByAnotherLayersExecutedPassKeepsPlayingWhileItsOwnerIsHidden() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let textureA = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let textureB = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let staticTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: textureA, bytes: bytes),
                                                                .init(texture: textureB, bytes: bytes)],
                                                      workshopID: "parity-video-bound-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["hidden": textureA, "b": textureB])
        let layerB = WPEResourceID("_layer_b")
        // Draw 0 is a visible layer's effect binding A off slot zero; draw 3 is A's hidden owner; draw 1 binds B.
        let sources = WPEParityFrameRenderer.videoSources(
            of: [0: [["g_Texture0": .image(staticTexture)],
                     ["g_Texture0": .resource("_rt_effect"), "g_Texture1": .image(textureA)]],
                 1: [["g_Texture0": .resource(layerB)]],
                 2: [["g_Texture0": .image(staticTexture)]],
                 3: [["g_Texture0": .image(textureA)]]],
            videos: videos.textures, layerImages: [layerB: textureB]
        )
        XCTAssertEqual(sources, [0: [0], 1: [1], 3: [0]])
        videos.setBoundSources(Set(sources.values.joined()))
        for _ in 0 ... WPEParityVideoTextures.unsampledFrameLimit + 1 {
            videos.recordSampled(sources: sources[0] ?? [])
        }
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "hidden")?.isPlaying, true,
                       "Another layer's executed pass samples A every frame")
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "b")?.isPlaying, false,
                       "No executed draw has bound B for more than 30 submitted frames")
    }

    func testSharedOwnersUseActualPlayerControlsAndPublishReadyDurationWithoutReplayingOldWrites() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let staticTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: texture, bytes: Data(contentsOf: url))],
                                                      workshopID: "parity-video-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["a": texture, "b": texture, "static": staticTexture])
        func field(_ owner: String, _ name: String) -> WPEParitySceneState.ScriptValue? {
            videos.scriptFieldDefaults[.init(objectID: owner, name: "video.\(name)")]
        }
        XCTAssertEqual(field("a", "rate"), .vector(SIMD4(1, 0, 0, 0)))
        XCTAssertEqual(field("b", "loop"), .vector(SIMD4(1, 0, 0, 0)))
        XCTAssertNil(field("static", "rate"), "A static slot zero has no video handle")

        var state = try Self.state()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            videos.applyScriptFields(state: &state)
            if case let .vector(duration)? = state.scriptField("video.duration", of: "a"), duration.x > 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case let .vector(duration)? = state.scriptField("video.duration", of: "a") else {
            return XCTFail("The ready player must publish its duration")
        }
        XCTAssertGreaterThan(duration.x, 0.5)
        XCTAssertLessThanOrEqual(duration.x, 1.1)
        XCTAssertEqual(state.scriptField("video.duration", of: "b"), .vector(duration))
        XCTAssertEqual(field("a", "duration"), .vector(duration))
        XCTAssertNil(state.scriptField("video.duration", of: "static"))
        let generation = state.scriptFieldsGeneration
        for _ in 0 ..< 20 {
            videos.applyScriptFields(state: &state)
        }
        XCTAssertEqual(state.scriptFieldsGeneration, generation, "Stable media must not dirty the scene every frame")
        XCTAssertEqual(state.generation(.mediaPlayer), 0)

        state.setScriptField("video.rate", of: "a", to: .vector(SIMD4(1.5, 0, 0, 0)),
                             invalidating: .mediaPlayer)
        state.setScriptField("video.loop", of: "a", to: .vector(.zero), invalidating: .mediaPlayer)
        videos.applyScriptFields(state: &state)
        XCTAssertEqual(field("a", "rate"), .vector(SIMD4(1.5, 0, 0, 0)))
        XCTAssertEqual(field("b", "rate"), field("a", "rate"), "Both owners sample the same player")
        XCTAssertEqual(field("b", "loop"), .vector(.zero))
        state.setScriptField("video.rate", of: "b", to: .vector(SIMD4(0.75, 0, 0, 0)),
                             invalidating: .mediaPlayer)
        videos.applyScriptFields(state: &state)
        XCTAssertEqual(field("a", "rate"), .vector(SIMD4(0.75, 0, 0, 0)))
        state.setScriptField("unrelated", of: "", to: .integer(1), invalidating: .none)
        videos.setOwners(["a": texture, "b": texture, "static": staticTexture])
        videos.applyScriptFields(state: &state)
        XCTAssertEqual(field("b", "rate"), .vector(SIMD4(0.75, 0, 0, 0)),
                       "A field generation change must not replay a's old rate onto the shared source")

        state.setScriptField("video.rate", of: "b", to: .vector(SIMD4(3, 0, 0, 0)), invalidating: .mediaPlayer)
        videos.applyScriptFields(state: &state)
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "a")?.rate, 3, "Scene scripts pass rates above 2 through")
        XCTAssertEqual(field("a", "rate"), .vector(SIMD4(3, 0, 0, 0)))
        for rejected: Float in [0, -1, .nan] {
            state.setScriptField("video.rate", of: "b", to: .vector(SIMD4(rejected, 0, 0, 0)),
                                 invalidating: .mediaPlayer)
            videos.applyScriptFields(state: &state)
            XCTAssertEqual(videos.playbackSnapshot(ownerID: "b")?.rate, 3, "Rate \(rejected) must be ignored")
        }
        videos.setOwners(["b": texture])
        XCTAssertNil(field("a", "rate"))
        XCTAssertEqual(field("b", "rate"), .vector(SIMD4(3, 0, 0, 0)))
        XCTAssertTrue(videos.textures[0] === texture)
    }

    func testPerformanceProfileSuspendsAndResumesThePlayer() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: texture, bytes: Data(contentsOf: url))],
                                                      workshopID: "parity-video-profile-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["a": texture])
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, videos.playbackSnapshot(ownerID: "a")?.isPlaying != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "a")?.isPlaying, true)

        videos.applyPerformanceProfile(.suspended)
        let suspended = try XCTUnwrap(videos.playbackSnapshot(ownerID: "a"))
        XCTAssertFalse(suspended.isPlaying)
        XCTAssertEqual(suspended.playbackRequested, true, "Suspension is policy, not a script pause")
        videos.applyPerformanceProfile(.quality)
        XCTAssertEqual(videos.playbackSnapshot(ownerID: "a")?.isPlaying, true)
    }

    func testCaptureSeekStagesTheFrameAtTheRequestedTime() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64,
                                                                  height: 64, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let url = try await Self.writeVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [.init(texture: texture, bytes: Data(contentsOf: url))],
                                                      workshopID: "parity-video-seek-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.setOwners(["a": texture])
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, (videos.playbackSnapshot(ownerID: "a")?.duration ?? 0) <= 0.5 {
            try await Task.sleep(for: .milliseconds(10))
        }

        await videos.seekForCapture(to: 0.75)
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        try videos.encode(into: commandBuffer)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
        videos.finishFrame()
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4 * 64, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        // Frame N of `writeVideo()` is gray 40 + 4N; 0.75 s at 24 fps is frame 18.
        XCTAssertEqual(Double(pixel[1]), 112, accuracy: 8)

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(try XCTUnwrap(videos.playbackSnapshot(ownerID: "a")).currentTime, 0.75, accuracy: 0.02)
    }

    func testBoundVideoFilePlaysMutedLoopsCentreCroppedAndKeepsTheFileWhenUnbound() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let url = try await Self.writeTwoColourVideo()
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [], workshopID: "parity-user-video-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.bindUserVideos(["clip": url])
        let source = try XCTUnwrap(videos.userVideoSourceForTesting("clip"), "a bound file must start a video source")
        XCTAssertEqual(source.playerForTesting?.isMuted, true)
        XCTAssertEqual(source.playerForTesting?.volume, 0)

        // A square slot keeps the middle 64 columns of the 128x64 clip, never its green side bars.
        let slot = WPEUserImageSlot(key: "clip", aspect: 1, pads: false)
        var seen: [String] = []
        var size: [Int] = []
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline, source.completedLoopCount < 1 || Set(seen).count < 2 {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try videos.encode(into: commandBuffer)
            let texture = videos.userTexture(for: slot)
            await Self.commit(commandBuffer)
            videos.finishFrame()
            videos.recordSampled(sources: [])
            if let texture, texture.width > 1 {
                size = [texture.width, texture.height]
                for x in [4, 32, 60] {
                    let colour = try Self.colour(Self.readPixel(texture, x: x, y: 32, queue: queue))
                    XCTAssertNotEqual(colour, "green", "the crop must drop the clip's side bars")
                    if x == 32, colour != "other", seen.last != colour {
                        seen.append(colour)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(size, [64, 64], "the bound clip must be centre-cropped to the square slot")
        XCTAssertTrue(seen.contains("red") && seen.contains("blue"), "the slot must sample the playing clip, saw \(seen)")
        XCTAssertGreaterThanOrEqual(source.completedLoopCount, 1, "a bound clip loops")
        XCTAssertEqual(source.scriptPlaybackSnapshot?.rate, 1)

        videos.bindUserVideos([:])
        XCTAssertNil(videos.userVideoSourceForTesting("clip"))
        XCTAssertNil(videos.userTexture(for: slot), "an unbound slot shows the authored texture")
        XCTAssertFalse(source.isActivelyPlaying, "unbinding retires the source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)),
                      "retiring a bound video must not delete the user's file")
    }

    func testUnopenableVideoFileKeepsTheAuthoredTexture() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-broken-\(UUID().uuidString).mp4")
        try Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let videos = try await WPEParityVideoTextures(streams: [], workshopID: "parity-user-video-\(UUID().uuidString)",
                                                      device: device, queue: queue)
        videos.bindUserVideos(["clip": url])
        let source = try XCTUnwrap(videos.userVideoSourceForTesting("clip"))
        let slot = WPEUserImageSlot(key: "clip", aspect: nil, pads: false)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, source.openState == nil {
            let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
            try videos.encode(into: commandBuffer)
            XCTAssertNil(videos.userTexture(for: slot), "a file still opening shows the authored texture")
            await Self.commit(commandBuffer)
            videos.finishFrame()
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTAssertEqual(source.openState, false, "the player must report the file as unplayable")
        XCTAssertNil(videos.userTexture(for: slot), "an unplayable file keeps the authored texture")
    }

    private static func commit(_ commandBuffer: MTLCommandBuffer) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }
    }

    private static func readPixel(_ texture: MTLTexture, x: Int, y: Int, queue: MTLCommandQueue) throws -> [UInt8] {
        let buffer = try XCTUnwrap(queue.device.makeBuffer(length: 4, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: x, y: y, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: 4))
    }

    /// `bgra` is a BGRA8 texel.
    private static func colour(_ bgra: [UInt8]) -> String {
        let (blue, green, red) = (Int(bgra[0]), Int(bgra[1]), Int(bgra[2]))
        let dominant = [("red", red, green + blue), ("blue", blue, red + green), ("green", green, red + blue)]
        return dominant.first { $0.1 > 180 && $0.2 < 160 }?.0 ?? "other"
    }

    /// One second of 128x64 H.264: green 32-column side bars around a red first half-second, then blue.
    private static func writeTwoColourVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-two-colour-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 64,
        ])
        guard writer.canAdd(input) else { throw FixtureError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writer }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(3)
        for frame in 0 ..< 24 {
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else { throw writer.error ?? FixtureError.writer }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 128, 64, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
                == kCVReturnSuccess, let pixelBuffer else { throw FixtureError.pixelBuffer }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let middle: [UInt8] = frame < 12 ? [0, 0, 255, 255] : [255, 0, 0, 255]
                for row in 0 ..< 64 {
                    for column in 0 ..< 128 {
                        let texel = (32 ..< 96).contains(column) ? middle : [0, 255, 0, 255]
                        for channel in 0 ..< 4 {
                            base.storeBytes(of: texel[channel], toByteOffset: row * rowBytes + column * 4 + channel, as: UInt8.self)
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
                throw writer.error ?? FixtureError.writer
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.writer }
        return url
    }

    private static func state() throws -> WPEParitySceneState {
        let json: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]], "objects": [],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let document = try WPESceneDocumentParser.parse(data: data, userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in VideoNoScripts() })
        return WPEParitySceneState(document: document, hdr: false)
    }

    /// The same local H.264 writer approach as the source pacing tests; no capture corpus is required.
    private static func writeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parity-video-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        var completed = false
        defer {
            if !completed {
                if writer.status == .writing {
                    writer.cancelWriting()
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        guard writer.canAdd(input) else { throw FixtureError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? FixtureError.writer }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(3)
        for frame in 0 ..< 24 {
            while !input.isReadyForMoreMediaData {
                guard Date() < deadline, writer.status == .writing else { throw writer.error ?? FixtureError.writer }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBuffer: CVPixelBuffer?
            let result = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                             nil, &pixelBuffer)
            guard result == kCVReturnSuccess, let pixelBuffer else { throw FixtureError.pixelBuffer }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(base, Int32(40 + frame * 4), CVPixelBufferGetBytesPerRow(pixelBuffer) * 64)
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
                throw writer.error ?? FixtureError.writer
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? FixtureError.writer }
        completed = true
        return url
    }

    private enum FixtureError: Error { case writer, pixelBuffer }
}

private struct VideoNoScripts: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}
#endif
