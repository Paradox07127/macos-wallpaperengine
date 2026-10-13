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
