import Compression
import CoreGraphics
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Warm-suspend release of the eager (below-threshold) `.tex` animation path.
/// Before this behaviour existed `applyPerformanceProfile` / `invalidate` were
/// empty, so every atlas stayed resident for the whole session.
@Suite("WPETexAnimatedTextureSource suspend")
@MainActor
struct WPETexAnimatedTextureSourceSuspendTests {

    @Test("Suspend drops eager atlas GPU bytes to zero")
    func suspendReleasesAtlasGPUBytes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try makeEagerSource(device: device)

        // Two 4x4 RGBA8 atlases.
        #expect(fixture.source.residentAtlasGPUBytes == 2 * 4 * 4 * 4)

        fixture.source.applyPerformanceProfile(.suspended)

        #expect(fixture.source.residentAtlasGPUBytes == 0)
        #expect(fixture.source.hasReleasedAtlases)
    }

    @Test("Resume restores every frame's own atlas pixels")
    func resumeRestoresFramePixels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try makeEagerSource(device: device)
        let residentBefore = fixture.source.residentAtlasGPUBytes
        let image0Bytes = readRGBA(fixture.atlases[0])
        let image1Bytes = readRGBA(fixture.atlases[1])
        #expect(image0Bytes != image1Bytes)

        fixture.source.applyPerformanceProfile(.suspended)
        fixture.source.applyPerformanceProfile(.quality)

        // Frames 0/1 reference image 0, frames 2/3 reference image 1.
        let restoredFirst = try #require(fixture.source.texture(at: 0.0))
        let restoredThird = try #require(fixture.source.texture(at: 0.25))
        #expect(readRGBA(restoredFirst) == image0Bytes)
        #expect(readRGBA(restoredThird) == image1Bytes)
        #expect(fixture.source.residentAtlasGPUBytes == residentBefore)
        #expect(!fixture.source.hasReleasedAtlases)
    }

    @Test("Restored atlases keep the eager descriptor (format, size)")
    func restoredAtlasesKeepEagerDescriptor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try makeEagerSource(device: device)
        let original = try #require(fixture.source.texture(at: 0.0))
        let originalFormat = original.pixelFormat
        let originalSize = (original.width, original.height)

        fixture.source.applyPerformanceProfile(.suspended)
        let restored = try #require(fixture.source.texture(at: 0.0))

        #expect(restored.pixelFormat == originalFormat)
        #expect((restored.width, restored.height) == originalSize)
    }

    @Test("LZ4-compressed atlases restore identically to their eager upload")
    func compressedAtlasesRestoreIdentically() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try makeEagerSource(device: device, compressed: true)
        let image0Bytes = readRGBA(fixture.atlases[0])

        fixture.source.applyPerformanceProfile(.suspended)
        let restored = try #require(fixture.source.texture(at: 0.0))

        #expect(readRGBA(restored) == image0Bytes)
    }

    @Test("Sprite-sheet UV rects survive the release without rebuilding")
    func spriteSheetRectsSurviveRelease() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try makeEagerSource(device: device)
        let before = fixture.source.spriteSheetFrameRectsNormalized()
        #expect(before.count == 4)

        fixture.source.applyPerformanceProfile(.suspended)
        let after = fixture.source.spriteSheetFrameRectsNormalized()

        #expect(after == before)
        // Reading UVs must not silently re-upload the atlases it just dropped.
        #expect(fixture.source.hasReleasedAtlases)
        #expect(fixture.source.residentAtlasGPUBytes == 0)
    }

    @Test("invalidate releases the atlases too")
    func invalidateReleasesAtlases() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try makeEagerSource(device: device)

        fixture.source.invalidate()

        #expect(fixture.source.residentAtlasGPUBytes == 0)
        #expect(fixture.source.hasReleasedAtlases)
    }

    @Test("Without a rebuild source the atlases stay resident")
    func withoutProviderAtlasesStayResident() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textures = try (0..<3).map { _ in try makeBlankTexture(device: device) }
        let source = WPETexAnimatedTextureSource(frames: textures, frameRate: 10, loop: true)
        let before = source.residentAtlasGPUBytes
        #expect(before > 0)

        source.applyPerformanceProfile(.suspended)

        #expect(source.residentAtlasGPUBytes == before)
        #expect(!source.hasReleasedAtlases)
        #expect(source.texture(at: 0.0) === textures[0])
    }

    @Test("A rebuild source whose frame schedule disagrees is rejected")
    func mismatchedProviderIsRejected() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fixture = try makeEagerSource(device: device)
        // Same images, one fewer frame than the eager source was built with.
        let shortPayload = makeStreamingPayload(frames: [
            WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 0, y: 0, width: 2, height: 2), duration: 0.1)
        ])
        let shortProvider = try #require(
            WPETexAnimatedAtlasProvider(payload: shortPayload, device: device, label: "mismatch")
        )

        let secondSource = WPETexAnimatedTextureSource(
            frames: fixture.eagerFrames,
            frameRate: 10,
            loop: true
        )
        #expect(secondSource.attachAtlasProvider(shortProvider) == false)

        secondSource.applyPerformanceProfile(.suspended)
        #expect(secondSource.residentAtlasGPUBytes > 0)
    }

    // MARK: - Fixture

    private struct EagerFixture {
        let source: WPETexAnimatedTextureSource
        let atlases: [MTLTexture]
        let eagerFrames: [WPETexAnimatedFrame]
    }

    /// Mirrors the production wiring: the loader uploads one atlas per unique
    /// image, then the renderer attaches the compressed payload as the rebuild
    /// source (`WPEMetalSceneRenderer.attachAtlasProvider`).
    private func makeEagerSource(
        device: MTLDevice,
        compressed: Bool = false
    ) throws -> EagerFixture {
        let payload = makeStreamingPayload(compressed: compressed)
        let provider = try #require(
            WPETexAnimatedAtlasProvider(payload: payload, device: device, label: "eager-suspend")
        )
        let atlases = try (0..<payload.compressedImages.count).map { imageID in
            try provider.makeAtlas(imageID: imageID)
        }
        let eagerFrames = payload.frames.map { frame in
            WPETexAnimatedFrame(
                texture: atlases[frame.imageID],
                sourceSubRect: frame.subRect,
                duration: frame.duration
            )
        }
        let source = WPETexAnimatedTextureSource(frames: eagerFrames, frameRate: 10, loop: true)
        #expect(source.attachAtlasProvider(provider))
        return EagerFixture(source: source, atlases: atlases, eagerFrames: eagerFrames)
    }

    private func makeStreamingPayload(
        frames: [WPETexStreamingFrame]? = nil,
        compressed: Bool = false
    ) -> WPETexStreamingPayload {
        makeSharedStreamingPayload(frames: frames, compressed: compressed)
    }

    private func makeBlankTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 4,
            height: 4,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func readRGBA(_ texture: MTLTexture) -> [UInt8] {
        let bytesPerRow = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * texture.height)
        texture.getBytes(
            &bytes,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, texture.width, texture.height),
            mipmapLevel: 0
        )
        return bytes
    }
}

/// The lazy/eager split metric. It used to be `totalUncompressedImageBytes`
/// (every container image at its stored payload size), which over-counts images
/// no frame references and trusts a padded `decompressedByteCount`.
@Suite("WPETexAnimatedTextureSource eager byte gate")
struct WPETexAnimatedTextureSourceGateTests {

    @Test("Unreferenced container images are not billed")
    func unreferencedImagesAreNotBilled() {
        let payload = makeSharedStreamingPayload(extraUnreferencedImage: true)

        // 3 images in the container, 2 referenced by the frame schedule.
        #expect(payload.compressedImages.count == 3)
        #expect(payload.totalUncompressedImageBytes == 3 * 4 * 4 * 4)
        #expect(WPEMetalSceneRenderer.eagerAnimationGPUBytes(of: payload) == 2 * 4 * 4 * 4)
    }

    @Test("A padded stored byte count does not inflate the GPU estimate")
    func paddedStoredByteCountIsIgnored() {
        let payload = makeSharedStreamingPayload(paddedStoredByteCount: true)

        #expect(payload.totalUncompressedImageBytes > 2 * 4 * 4 * 4)
        #expect(WPEMetalSceneRenderer.eagerAnimationGPUBytes(of: payload) == 2 * 4 * 4 * 4)
    }

    @Test("Block-compressed images are billed per 4x4 block, not per pixel")
    func blockCompressedImagesAreBilledPerBlock() {
        let payload = makeBC3StreamingPayload()

        // 8x8 BC3 = 2x2 blocks of 4x4 pixels, 16 B per block.
        #expect(WPEMetalSceneRenderer.eagerAnimationGPUBytes(of: payload) == 2 * 2 * 16)
    }

    private func makeBC3StreamingPayload() -> WPETexStreamingPayload {
        let blockBytes = Data(count: 2 * 2 * 16)
        let mip = WPETexCompressedMipmap(
            index: 0,
            width: 8,
            height: 8,
            isCompressed: false,
            compressedBytes: blockBytes,
            decompressedByteCount: blockBytes.count
        )
        return WPETexStreamingPayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 8,
                height: 8,
                textureFormatCode: WPETexFormat.dxt5.rawValue,
                format: .dxt5,
                mipmapCount: 1,
                flags: 0
            ),
            compressedImages: [WPETexCompressedImage(width: 8, height: 8, payloads: [mip])],
            frames: [
                WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 0, y: 0, width: 8, height: 8), duration: 0.1)
            ],
            frameRate: 10,
            loop: true
        )
    }
}

// MARK: - Shared fixture builders

/// 4x4 RGBA8888 images; pixel value encodes (x, y, tag) so a restored atlas is
/// distinguishable from its sibling.
private func makeFixtureImage(width: Int, height: Int, blue: UInt8) -> Data {
    var bytes = Data(count: width * height * 4)
    bytes.withUnsafeMutableBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                base[offset] = UInt8(x)
                base[offset + 1] = UInt8(y)
                base[offset + 2] = blue
                base[offset + 3] = 0xff
            }
        }
    }
    return bytes
}

private func lz4Encoded(_ data: Data) -> Data {
    let capacity = data.count + 1024
    var destination = Data(count: capacity)
    let written = destination.withUnsafeMutableBytes { dstRaw -> Int in
        data.withUnsafeBytes { srcRaw -> Int in
            guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress,
                  let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(dst, capacity, src, data.count, nil, COMPRESSION_LZ4_RAW)
        }
    }
    // A zero return means LZ4 declined; the fixture would then feed the provider
    // empty bytes and fail for a reason that has nothing to do with suspend.
    #expect(written > 0)
    return destination.prefix(written)
}

private func makeSharedStreamingPayload(
    frames: [WPETexStreamingFrame]? = nil,
    compressed: Bool = false,
    extraUnreferencedImage: Bool = false,
    paddedStoredByteCount: Bool = false
) -> WPETexStreamingPayload {
    func mipmap(blue: UInt8) -> WPETexCompressedMipmap {
        let raw = makeFixtureImage(width: 4, height: 4, blue: blue)
        return WPETexCompressedMipmap(
            index: 0,
            width: 4,
            height: 4,
            isCompressed: compressed,
            compressedBytes: compressed ? lz4Encoded(raw) : raw,
            decompressedByteCount: paddedStoredByteCount ? raw.count * 2 : raw.count
        )
    }

    var images = [
        WPETexCompressedImage(width: 4, height: 4, payloads: [mipmap(blue: 0)]),
        WPETexCompressedImage(width: 4, height: 4, payloads: [mipmap(blue: 0x40)])
    ]
    if extraUnreferencedImage {
        images.append(WPETexCompressedImage(width: 4, height: 4, payloads: [mipmap(blue: 0x80)]))
    }

    return WPETexStreamingPayload(
        info: WPETexInfo(
            containerVersion: 5,
            infoVersion: 1,
            width: 4,
            height: 4,
            textureFormatCode: WPETexFormat.rgba8888.rawValue,
            format: .rgba8888,
            mipmapCount: 1,
            flags: 0
        ),
        compressedImages: images,
        frames: frames ?? [
            WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 0, y: 0, width: 2, height: 2), duration: 0.1),
            WPETexStreamingFrame(imageID: 0, subRect: CGRect(x: 2, y: 0, width: 2, height: 2), duration: 0.1),
            WPETexStreamingFrame(imageID: 1, subRect: CGRect(x: 0, y: 2, width: 2, height: 2), duration: 0.1),
            WPETexStreamingFrame(imageID: 1, subRect: CGRect(x: 2, y: 2, width: 2, height: 2), duration: 0.1)
        ],
        frameRate: 10,
        loop: true
    )
}
