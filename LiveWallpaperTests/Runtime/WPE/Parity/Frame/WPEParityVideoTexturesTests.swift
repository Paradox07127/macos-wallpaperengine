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
            videos.recordSampled(ownerIDs: ["1", "2"].filter { state.object($0)?.visible == true })
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

        // Preserve the existing source's supported rate policy until the Windows out-of-range rule is known.
        state.setScriptField("video.rate", of: "b", to: .vector(SIMD4(3, 0, 0, 0)), invalidating: .mediaPlayer)
        videos.applyScriptFields(state: &state)
        XCTAssertEqual(field("a", "rate"), .vector(SIMD4(0.75, 0, 0, 0)))
        videos.setOwners(["b": texture])
        XCTAssertNil(field("a", "rate"))
        XCTAssertEqual(field("b", "rate"), .vector(SIMD4(0.75, 0, 0, 0)))
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
