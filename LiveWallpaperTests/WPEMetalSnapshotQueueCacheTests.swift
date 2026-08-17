import AppKit
import Metal
import Testing
import os
@testable import LiveWallpaper

// B6 guard: the poster downsample path caches one MTLCommandQueue per device
// (process lifetime) instead of creating a queue per capture. Needs a real
// MTLDevice, so this suite stays out of the headless fast-app-contract shard
// (that shard is an explicit allowlist in scripts/fast_app_contract_tests.sh).

@Suite("WPEMetalTextureSnapshotter downsample queue cache")
struct WPEMetalSnapshotQueueCacheTests {

    @Test("the same device resolves to the same cached queue instance")
    func sameDeviceSameQueueInstance() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let first = try #require(WPEMetalTextureSnapshotter.commandQueue(for: device))
        let second = try #require(WPEMetalTextureSnapshotter.commandQueue(for: device))
        #expect(first === second)
        #expect(first.label == "com.livewallpaper.wpe-metal.poster-downsample")
    }

    @Test("repeated poster snapshots reuse the cached queue: zero creations once primed")
    func repeatedSnapshotsDoNotRecreateQueue() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let primed = try #require(WPEMetalTextureSnapshotter.commandQueue(for: device))

        // Wider than posterMaxDimension so snapshotAsync must take the GPU
        // downsample path — the cached queue's only consumer.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 2048,
            height: 64,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        let creationsBefore = WPEMetalTextureSnapshotter.downsampleQueueCreationsForTesting.withLock { $0 }
        let snapshotter = WPEMetalTextureSnapshotter(label: "test.queue-cache.readback")
        for _ in 0 ..< 3 {
            let image = await snapshotter.snapshotAsync(
                from: WPEMetalTextureSnapshotter.SnapshotSource(texture: texture)
            )
            let poster = try #require(image)
            // 2048 → 1440 proves the downsample actually ran; a 2048-wide poster
            // would mean the fallback path executed and the counts below are vacuous.
            #expect(Int(poster.size.width) == WPEMetalTextureSnapshotter.posterMaxDimension)
        }
        let creationsAfter = WPEMetalTextureSnapshotter.downsampleQueueCreationsForTesting.withLock { $0 }
        #expect(
            creationsAfter - creationsBefore == 0,
            "downsampling created \(creationsAfter - creationsBefore) new queue(s) for an already-cached device"
        )
        let cachedAfter = try #require(WPEMetalTextureSnapshotter.commandQueue(for: device))
        #expect(cachedAfter === primed)
    }

    /// The review flagged that the sRGB branch takes a differing-format texture
    /// view, which Apple documents as needing `.pixelFormatView` — a usage the
    /// renderer's output textures do not carry. This pins what the shipping
    /// descriptor actually does: same format/usage as `makeOutputTexture`, and
    /// the poster must come back downsampled rather than through the
    /// full-resolution fallback.
    @Test("an sRGB poster built with the renderer's own descriptor still downsamples on GPU")
    func srgbPosterWithRendererDescriptorDownsamples() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: 2048,
            height: 64,
            mipmapped: false
        )
        // Verbatim from WPEMetalRenderExecutor.makeOutputTexture.
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: descriptor))

        let snapshotter = WPEMetalTextureSnapshotter(label: "test.queue-cache.srgb")
        let poster = try #require(await snapshotter.snapshotAsync(
            from: WPEMetalTextureSnapshotter.SnapshotSource(texture: texture)
        ))
        #expect(
            Int(poster.size.width) == WPEMetalTextureSnapshotter.posterMaxDimension,
            "sRGB poster came back at \(poster.size.width)px — the GPU downsample was skipped"
        )
    }
}
