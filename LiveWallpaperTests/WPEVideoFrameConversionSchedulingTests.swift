import CoreVideo
import Foundation
import Metal
import simd
import Testing
@testable import LiveWallpaper

/// E2: the NV12→BGRA pass rides the renderer's scene command buffer instead of
/// committing one of its own, so a decoded frame is published only once that
/// buffer is committed. These pin the transaction — staging, in-buffer
/// ordering, retirement timing, multi-source isolation and teardown — not the
/// colour math (`WPEVideoNV12ConversionTests` owns that).
@MainActor
@Suite("WPE video frame conversion scheduling", .serialized)
struct WPEVideoFrameConversionSchedulingTests {

    @Test("Staging alone publishes nothing; the sampled texture stays on the last frame")
    func stagingDoesNotPublish() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        harness.source.ingestForTesting(pixelBuffer: try Harness.nv12(luma: 100, cb: 110, cr: 140))
        let texture = try #require(harness.source.texture(at: 0))
        let baseline = try harness.readback(texture)
        #expect(!harness.source.hasStagedFrameWork, "a driven frame must leave nothing staged")

        harness.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: 180, cb: 100, cr: 155), drivesFrame: false
        )
        #expect(harness.source.hasStagedFrameWork)
        let afterStaging = try harness.readback(texture)
        #expect(afterStaging == baseline,
                "staging must not touch the working texture — no command buffer ran")
    }

    /// `texture(at:)` hands a staged frame's target to the renderer before the
    /// conversion filling it has been encoded, so a brand-new `.private` backing
    /// would be sampled as undefined memory in the one case where the conversion
    /// encoder fails to be created. Both mm-review models raised this for the
    /// first frame and for a decoder resolution change — the "NV12 first frame
    /// only" reading missed the resize.
    ///
    /// This pins that every new backing is cleared. It deliberately does NOT
    /// assert on the bytes: an unwritten `.private` texture may read back as
    /// zeros anyway, and a byte assertion stayed green when the clear was
    /// removed — it pinned nothing.
    @Test("Every newly allocated working texture is cleared before it can be sampled")
    func newWorkingTextureIsCleared() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        harness.source.ingestForTesting(pixelBuffer: try Harness.nv12(luma: 100, cb: 110, cr: 140))
        let first = try #require(harness.source.texture(at: 0))
        #expect(harness.source.workingTextureClearsForTesting == 1)

        // Same size: the backing is reused, so nothing is allocated or cleared.
        harness.source.ingestForTesting(pixelBuffer: try Harness.nv12(luma: 120, cb: 115, cr: 145))
        #expect(harness.source.workingTextureClearsForTesting == 1)

        // A decoder resolution change allocates a fresh backing — and clears it.
        harness.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: 200, cb: 90, cr: 160, size: 128),
            drivesFrame: false
        )
        #expect(harness.source.workingTextureClearsForTesting == 2)
        let exposed = try #require(harness.source.texture(at: 0))
        #expect(exposed.width == 128, "the staged resize is what gets handed out")
        #expect(exposed !== first)
    }

    /// Criterion 1: a scene command buffer can be built and then dropped
    /// (drawable miss, encode throw, `WPEMetalFrameInFlightBudgetExhausted`).
    @Test("A scene command buffer that never commits leaves the published frame in place")
    func droppedSceneBufferKeepsThePublishedFrame() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        harness.source.ingestForTesting(pixelBuffer: try Harness.nv12(luma: 100, cb: 110, cr: 140))
        let texture = try #require(harness.source.texture(at: 0))
        let baseline = try harness.readback(texture)

        harness.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: 180, cb: 100, cr: 155), drivesFrame: false
        )
        let pendingBefore = harness.source.pendingRetirementCountForTesting
        let fencesBefore = harness.source.retirementFencesCreatedForTesting
        do {
            // Encoded into a buffer the executor then abandons. Scoped so the
            // buffer is released without ever being committed.
            let dropped = try #require(harness.queue.makeCommandBuffer())
            harness.source.encodeStagedFrameWork(into: dropped)
            harness.source.rollbackStagedFrameWork()
        }

        let afterRollback = try harness.readback(texture)
        #expect(afterRollback == baseline,
                "an uncommitted conversion must not change what the renderer samples")
        #expect(harness.source.hasStagedFrameWork,
                "the frame must stay staged so the next scene buffer re-encodes it")
        #expect(harness.source.pendingRetirementCountForTesting == pendingBefore,
                "rollback must not hand an uncommitted buffer to the retirement drain")
        #expect(harness.source.retirementFencesCreatedForTesting == fencesBefore)

        // Control: the very same staged frame does land once a buffer commits,
        // so the assertions above are not passing for want of a decoded frame.
        harness.source.driveStagedFrameWorkForTesting()
        let afterRetry = try harness.readback(texture)
        #expect(afterRetry != baseline)
        #expect(!harness.source.hasStagedFrameWork)
    }

    /// Criterion 2: the conversion must be ordered ahead of anything in the
    /// same buffer that samples the working texture.
    @Test("The conversion is encoded ahead of a same-buffer reader of the working texture")
    func conversionPrecedesSameBufferReaders() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        harness.source.ingestForTesting(pixelBuffer: try Harness.nv12(luma: 100, cb: 110, cr: 140))
        let texture = try #require(harness.source.texture(at: 0))
        let firstFrame = try harness.readback(texture)

        let (luma, cb, cr): (UInt8, UInt8, UInt8) = (180, 100, 155)
        harness.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: luma, cb: cb, cr: cr), drivesFrame: false
        )

        // One buffer, in the executor's order: conversion, then a reader.
        let commandBuffer = try #require(harness.queue.makeCommandBuffer())
        harness.source.encodeStagedFrameWork(into: commandBuffer)
        let readbackBuffer = try #require(
            harness.device.makeBuffer(length: 4, options: .storageModeShared)
        )
        let blit = try #require(commandBuffer.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: readbackBuffer, destinationOffset: 0,
            destinationBytesPerRow: 4, destinationBytesPerImage: 4
        )
        blit.endEncoding()
        commandBuffer.commit()
        harness.source.commitStagedFrameWork()
        commandBuffer.waitUntilCompleted()

        let pointer = readbackBuffer.contents().bindMemory(to: UInt8.self, capacity: 4)
        let sampled = [pointer[0], pointer[1], pointer[2], pointer[3]]
        #expect(sampled != firstFrame,
                "the reader in the same buffer still saw the previous frame — the conversion was not ordered first")
        #expect(Harness.matchesReference(sampled, luma: luma, cb: cb, cr: cr),
                "same-buffer reader must see the converted frame, got \(sampled)")
    }

    /// Criterion 3: the replaced frame's CV wrappers are handed to a fence only
    /// once that fence is a committed buffer — `drainRetiredFrames` waits on
    /// every entry, and waiting on an uncommitted buffer never returns.
    @Test("A replaced frame is fenced at commit, not at staging or at encode")
    func retirementJoinsThePendingListOnlyAtCommit() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        harness.source.ingestForTesting(pixelBuffer: try Harness.nv12(luma: 100, cb: 110, cr: 140))
        harness.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: 180, cb: 100, cr: 155), drivesFrame: false
        )
        // Snapshot after the ingest: `publish` sweeps completed fences.
        let pendingAfterStage = harness.source.pendingRetirementCountForTesting
        let fencesAfterStage = harness.source.retirementFencesCreatedForTesting

        let commandBuffer = try #require(harness.queue.makeCommandBuffer())
        harness.source.encodeStagedFrameWork(into: commandBuffer)
        #expect(harness.source.retirementFencesCreatedForTesting == fencesAfterStage,
                "arming a completed handler is not publishing")
        #expect(harness.source.pendingRetirementCountForTesting == pendingAfterStage,
                "an un-committed buffer must not be in the drain list")

        commandBuffer.commit()
        harness.source.commitStagedFrameWork()
        #expect(harness.source.retirementFencesCreatedForTesting == fencesAfterStage + 1)
        #expect(harness.source.pendingRetirementCountForTesting == pendingAfterStage + 1,
                "the replaced frame's wrappers must be held behind the committed buffer")

        commandBuffer.waitUntilCompleted()
    }

    /// Criterion 4: each source owns its working texture, so one command buffer
    /// carrying both conversions cannot cross their frames.
    @Test("Two sources converting in one command buffer keep their own frames")
    func twoSourcesDoNotCrossFrames() throws {
        let first = try Harness.make()
        defer { first.tearDown() }
        let second = try Harness.make(device: first.device, queue: first.queue)
        defer { second.tearDown() }

        // Kept inside the 0…1 gamut so the shader's saturate never clamps and
        // the CPU reference stays an exact pin.
        let (aLuma, aCb, aCr): (UInt8, UInt8, UInt8) = (110, 150, 120)
        let (bLuma, bCb, bCr): (UInt8, UInt8, UInt8) = (190, 105, 150)
        first.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: aLuma, cb: aCb, cr: aCr), drivesFrame: false
        )
        second.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: bLuma, cb: bCb, cr: bCr), drivesFrame: false
        )

        let commandBuffer = try #require(first.queue.makeCommandBuffer())
        first.source.encodeStagedFrameWork(into: commandBuffer)
        second.source.encodeStagedFrameWork(into: commandBuffer)
        commandBuffer.commit()
        first.source.commitStagedFrameWork()
        second.source.commitStagedFrameWork()
        commandBuffer.waitUntilCompleted()

        let aTexture = try #require(first.source.texture(at: 0))
        let bTexture = try #require(second.source.texture(at: 0))
        #expect(aTexture !== bTexture, "each source must own its working texture")
        let aPixel = try first.readback(aTexture)
        let bPixel = try first.readback(bTexture)
        #expect(Harness.matchesReference(aPixel, luma: aLuma, cb: aCb, cr: aCr),
                "source A sampled \(aPixel)")
        #expect(Harness.matchesReference(bPixel, luma: bLuma, cb: bCb, cr: bCr),
                "source B sampled \(bPixel)")
        #expect(aPixel != bPixel, "the two frames must be distinguishable for this test to bite")
    }

    /// Criterion 5: a scene reload lands while a conversion is staged and even
    /// while one is armed on a buffer that will never be committed.
    @Test("Invalidate with a staged and an armed conversion tears down completely")
    func invalidateWithStagedConversion() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        harness.source.ingestForTesting(pixelBuffer: try Harness.nv12(luma: 100, cb: 110, cr: 140))
        harness.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: 180, cb: 100, cr: 155), drivesFrame: false
        )
        let abandoned = try #require(harness.queue.makeCommandBuffer())
        harness.source.encodeStagedFrameWork(into: abandoned)

        // A drain that waited on `abandoned` would never return.
        harness.source.invalidate()

        #expect(harness.source.pendingRetirementCountForTesting == 0)
        #expect(!harness.source.hasStagedFrameWork)
        #expect(harness.source.texture(at: 0) == nil)
        harness.source.invalidate()
    }

    @Test("An invalidated source encodes nothing into a live scene command buffer")
    func invalidatedSourceEncodesNothing() throws {
        let harness = try Harness.make()
        defer { harness.tearDown() }

        harness.source.ingestForTesting(
            pixelBuffer: try Harness.nv12(luma: 100, cb: 110, cr: 140), drivesFrame: false
        )
        harness.source.invalidate()

        let commandBuffer = try #require(harness.queue.makeCommandBuffer())
        harness.source.encodeStagedFrameWork(into: commandBuffer)
        harness.source.commitStagedFrameWork()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        #expect(harness.source.texture(at: 0) == nil)
        #expect(harness.source.pendingRetirementCountForTesting == 0)
    }

    // MARK: - Source-order pins

    /// The runtime tests above drive the three contract calls by hand. This is
    /// what keeps the executor doing the same thing in the same order.
    @Test("The executor encodes staged conversions into the scene buffer before any pass")
    func executorEncodesConversionsBeforeScenePasses() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalRenderExecutor.swift"
        )
        let makeBuffer = try #require(
            source.range(of: "WPEFrameOccupancyMeter.count(.sceneCommandBuffer)")
        )
        let encode = try #require(
            source.range(of: "source.encodeStagedFrameWork(into: commandBuffer)")
        )
        let firstScenePass = try #require(
            source.range(of: "try clearTexture(output, color: clearColor(for: .scene)")
        )
        #expect(makeBuffer.upperBound < encode.lowerBound)
        #expect(encode.upperBound < firstScenePass.lowerBound,
                "a scene pass is encoded before the video conversion it may sample")

        // Both scene-buffer commits (async and synchronous) must publish, and
        // only after committing — a `publishStagedTextureWork()` that ran first
        // would hand `drainRetiredFrames` an uncommitted fence.
        let paired = source.components(
            separatedBy: "commandBuffer.commit()\n            publishStagedTextureWork()"
        ).count - 1
        #expect(paired == 2, "expected both scene-buffer commits to be followed by the publish")
        // The drop path is a `defer`, so it fires on every throw between the
        // encode and the commit (drawable miss, in-flight budget, encode error).
        #expect(source.contains("source.rollbackStagedFrameWork()"))
        #expect(source.contains("source.commitStagedFrameWork()"))
    }

    @Test("Neither publish path builds a command buffer any more")
    func publishPathsCommitNothing() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Assets/WPEVideoTextureSource.swift"
        )
        for name in ["private func publishBiPlanar(", "private func publishBGRA("] {
            let body = try Self.functionBody(of: name, in: source)
            #expect(!body.contains("makeCommandBuffer"),
                    "\(name) reintroduced a per-frame command buffer")
            #expect(!body.contains(".commit()"), "\(name) reintroduced a per-frame commit")
        }
    }

    /// Brace-matched body of a declaration, so the pins above cannot pass by
    /// reading a neighbouring function.
    private static func functionBody(of declaration: String, in source: String) throws -> String {
        let start = try #require(source.range(of: declaration))
        var depth = 0
        var started = false
        var index = start.upperBound
        var body = ""
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                depth += 1
                started = true
            } else if character == "}" {
                depth -= 1
                if started, depth == 0 { return body }
            }
            if started { body.append(character) }
            index = source.index(after: index)
        }
        throw HarnessError.unbalancedBraces(declaration)
    }

    // MARK: - Harness

    /// A player-free source: a zero-ticket admission keeps `init` on the
    /// still-frame branch, and a zero-byte file makes the still extract fail, so
    /// nothing publishes until a test ingests. No AVPlayer, no timing.
    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let source: WPEVideoTextureSource
        let fileURL: URL

        static func make(
            device explicitDevice: MTLDevice? = nil,
            queue explicitQueue: MTLCommandQueue? = nil
        ) throws -> Harness {
            let device: MTLDevice
            if let explicitDevice {
                device = explicitDevice
            } else {
                device = try #require(MTLCreateSystemDefaultDevice())
            }
            let queue: MTLCommandQueue
            if let explicitQueue {
                queue = explicitQueue
            } else {
                queue = try #require(device.makeCommandQueue())
            }
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wpe-e2-\(UUID().uuidString).mp4")
            try Data().write(to: fileURL)
            let source = try WPEVideoTextureSource(
                device: device,
                videoURL: fileURL,
                commandQueue: queue,
                decoderAdmission: WPEVideoDecoderAdmission(limit: 0)
            )
            #expect(!source.isLiveDecoder, "harness must not spin up an AVPlayer")
            return Harness(device: device, queue: queue, source: source, fileURL: fileURL)
        }

        func tearDown() {
            source.invalidate()
            try? FileManager.default.removeItem(at: fileURL)
        }

        /// Pixel (0,0) as BGRA. Runs on the source's own queue, so it is ordered
        /// behind every conversion committed there.
        func readback(_ texture: MTLTexture) throws -> [UInt8] {
            let buffer = try #require(device.makeBuffer(length: 4, options: .storageModeShared))
            let commandBuffer = try #require(queue.makeCommandBuffer())
            let blit = try #require(commandBuffer.makeBlitCommandEncoder())
            blit.copy(
                from: texture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                to: buffer, destinationOffset: 0,
                destinationBytesPerRow: 4, destinationBytesPerImage: 4
            )
            blit.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            let pointer = buffer.contents().bindMemory(to: UInt8.self, capacity: 4)
            return [pointer[0], pointer[1], pointer[2], pointer[3]]
        }

        /// BT.601 video range — what `WPEVideoYCbCrConversion.kind` picks for a
        /// 64-line untagged buffer, matching the fixtures below.
        static func matchesReference(_ bgra: [UInt8], luma: UInt8, cb: UInt8, cr: UInt8) -> Bool {
            let reference = WPEVideoYCbCrConversion.make(kind: .bt601, fullRange: false)
                .apply(SIMD3(Float(luma) / 255.0, Float(cb) / 255.0, Float(cr) / 255.0))
            let expected = [reference.z, reference.y, reference.x].map { Int(($0 * 255).rounded()) }
            return abs(Int(bgra[0]) - expected[0]) <= 2
                && abs(Int(bgra[1]) - expected[1]) <= 2
                && abs(Int(bgra[2]) - expected[2]) <= 2
                && bgra[3] == 255
        }

        static func nv12(
            luma: UInt8, cb: UInt8, cr: UInt8, size: Int = 64
        ) throws -> CVPixelBuffer {
            let width = size
            let height = size
            var pixelBuffer: CVPixelBuffer?
            let attributes: CFDictionary = [
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ] as CFDictionary
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault, width, height,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes, &pixelBuffer
            )
            guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
                throw HarnessError.pixelBufferCreateFailed(status)
            }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let lumaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            for row in 0..<height {
                memset(lumaBase + row * lumaRowBytes, Int32(luma), width)
            }
            let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let chromaBase = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
                .bindMemory(to: UInt8.self, capacity: chromaRowBytes * (height / 2))
            for row in 0..<(height / 2) {
                for column in 0..<(width / 2) {
                    chromaBase[row * chromaRowBytes + column * 2] = cb
                    chromaBase[row * chromaRowBytes + column * 2 + 1] = cr
                }
            }
            return buffer
        }
    }

    private enum HarnessError: Error {
        case pixelBufferCreateFailed(CVReturn)
        case unbalancedBraces(String)
    }
}
