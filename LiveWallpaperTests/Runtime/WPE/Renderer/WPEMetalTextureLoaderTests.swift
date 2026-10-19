import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture loader")
struct WPEMetalTextureLoaderTests {

    @MainActor
    @Test("Animated normal maps preserve linear sampling through upload and restore")
    func animatedNormalMapsPreserveLinearSampling() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Flat atlas border: red=mask, green=normal Y, alpha=normal X.
        let bytes = Data([255, 129, 0, 128, 255, 129, 0, 128, 255, 129, 0, 128, 255, 129, 0, 128])
        let info = WPETexInfo(
            containerVersion: 5, infoVersion: 1, width: 2, height: 2,
            textureFormatCode: WPETexFormat.rgba8888.rawValue,
            format: .rgba8888, mipmapCount: 2, flags: 0
        )
        let mip = WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)
        let smallMip = WPETexTextureMipmap(index: 1, width: 1, height: 1, bytes: Data([255, 129, 0, 128]))
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let payload = WPETexTexturePayload(
            info: info, mipmaps: [], hasAnimationFrames: true,
            animationTrack: WPETexAnimationTrack(
                frames: [WPETexAnimationFrame(imageID: 0, duration: 0.1, mipmaps: [mip, smallMip], subRect: rect)],
                frameRate: 10, loop: true
            )
        )
        let streaming = WPETexStreamingPayload(
            info: info,
            compressedImages: [WPETexCompressedImage(width: 2, height: 2, payloads: [
                WPETexCompressedMipmap(
                    index: 0, width: 2, height: 2, isCompressed: false,
                    compressedBytes: bytes, decompressedByteCount: bytes.count
                ),
                WPETexCompressedMipmap(index: 1, width: 1, height: 1, isCompressed: false,
                                       compressedBytes: smallMip.bytes, decompressedByteCount: smallMip.bytes.count),
            ])],
            frames: [WPETexStreamingFrame(imageID: 0, subRect: rect, duration: 0.1)],
            frameRate: 10, loop: true
        )
        let loader = WPEMetalTextureLoader(device: device)
        let eager = try await loader.makeAnimatedTextureSource(from: payload, label: "normal", colorSpace: .linear)
        let provider = try #require(WPETexAnimatedAtlasProvider(
            payload: streaming, device: device, label: "normal", colorSpace: .linear
        ))
        #expect(eager.attachAtlasProvider(provider))
        let initial = try #require(eager.texture(at: 0))
        eager.applyPerformanceProfile(.suspended)
        let restored = try #require(eager.texture(at: 0))
        #expect(initial.mipmapLevelCount == 2)
        #expect(restored.mipmapLevelCount == 2)
        let lazy = try loader.makeLazyAnimatedTextureSource(from: streaming, label: "normal", colorSpace: .linear)
        let streamed = try #require(lazy.texture(at: 0))
        for texture in [initial, restored, streamed] {
            #expect(texture.pixelFormat == .rgba8Unorm)
            let normal = try sampleNormal(texture, device: device)
            #expect(abs(normal.x) < 0.02 && abs(normal.y) < 0.02,
                    "A flat normal border must not displace the whole particle quad")
        }
        let color = try await loader.makeAnimatedTextureSource(from: payload, label: "color")
        #expect(color.texture(at: 0)?.pixelFormat == .rgba8Unorm)
    }

    private func sampleNormal(_ texture: MTLTexture, device: MTLDevice) throws -> SIMD2<Float> {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void sample_normal(texture2d<float> t [[texture(0)]], device float2 *out [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 value = t.sample(s, float2(0.5));
            out[0] = value.ag * 2.0 - 1.0;
        }
        """, options: nil)
        let function = try #require(library.makeFunction(name: "sample_normal"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let buffer = try #require(device.makeBuffer(length: MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        return buffer.contents().load(as: SIMD2<Float>.self)
    }

    @Test("CGImage uploads preserve straight sampled RGB and coverage before image shaders",
          arguments: [(false, false), (false, true), (true, false), (true, true)], [false, true])
    func cgImageAlphaRepresentation(configuration: (Bool, Bool), srgb: Bool) async throws {
        let (premultiplied, capped) = configuration
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pixel: [UInt8] = premultiplied ? [128, 64, 0, 128] : [255, 128, 0, 128]
        let bytes = Data((0 ..< 128 * 128).flatMap { _ in pixel })
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let image = try #require(CGImage(
            width: 128, height: 128, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 512,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: (premultiplied ? CGImageAlphaInfo.premultipliedLast : .last).rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(
            from: image, label: "alpha-upload-probe", colorSpace: srgb ? .sRGB : .linear,
            maxSourceEdge: capped ? 64 : nil
        )
        #expect(texture.width == (capped ? 64 : 128))
        let sample = try sampleRGBA(texture, device: device)
        let green = Float(128.0 / 255)
        // Alpha association is independent of the actual hardware sampling transfer.
        // MetalKit can infer a view format from the CGImage despite the requested SRGB option.
        let decodesSRGB = texture.pixelFormat == .rgba8Unorm_srgb || texture.pixelFormat == .bgra8Unorm_srgb
        let expected = SIMD4<Float>(1, decodesSRGB ? pow((green + 0.055) / 1.055, 2.4) : green, 0, green)
        #expect(abs(sample.x - expected.x) < 0.01 && abs(sample.y - expected.y) < 0.01
            && abs(sample.z - expected.z) < 0.01 && abs(sample.w - expected.w) < 0.01,
            "External images must sample as straight RGBA; sampled \(sample)")
    }

    @Test("Raster alpha conversion preserves 16-bit component precision")
    func rasterAlphaConversionKeepsPrecision() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let components: [UInt16] = [32768, 16384, 0, 32768]
        let bytes = components.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let image = try #require(CGImage(
            width: 1, height: 1, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 8, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let straight = try WPERasterImageAlpha.straightImage(image)
        #expect(straight.bitsPerComponent == 16 && straight.bitsPerPixel == 64)
        #expect(straight.alphaInfo == .last && straight.colorSpace == image.colorSpace)
        let data = try #require(straight.dataProvider?.data)
        let values = (data as Data).withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        #expect(values[0] == 65535 && abs(Int(values[1]) - 32768) <= 1 && values[2] == 0 && values[3] == 32768)
    }

    private func sampleRGBA(_ texture: MTLTexture, device: MTLDevice) throws -> SIMD4<Float> {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void sample_rgba(texture2d<float> t [[texture(0)]], device float4 *out [[buffer(0)]]) {
            constexpr sampler s(filter::nearest, address::clamp_to_edge);
            out[0] = t.sample(s, float2(0.5));
        }
        """, options: nil)
        let function = try #require(library.makeFunction(name: "sample_rgba"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let buffer = try #require(device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let encoder = try #require(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        return buffer.contents().load(as: SIMD4<Float>.self)
    }

    @Test("Uploads RGBA texture payload into an MTLTexture")
    func uploadsRGBA8888Payload() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([
            255, 0, 0, 0,
            0, 255, 0, 64,
            0, 0, 255, 128,
            255, 255, 255, 255,
        ])
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rgba")

        #expect(texture.width == 2)
        #expect(texture.height == 2)
        #expect(texture.pixelFormat == .rgba8Unorm)
        var uploaded = [UInt8](repeating: 0, count: bytes.count)
        texture.getBytes(&uploaded, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        #expect(uploaded == Array(bytes), "Raw TEX uploads must preserve all four channels, including RGB at alpha zero")
    }

    @Test("RG88 alpha-channel-priority uploads .rg8Unorm with (R,R,R,G) swizzle")
    func rg88AlphaPrioritySwizzle() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([200, 50, 10, 255, 0, 128, 64, 32])
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rg88.rawValue,
                format: .rg88,
                mipmapCount: 1,
                flags: 0x0008_0000
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rg88-glow")

        #expect(texture.pixelFormat == .rg8Unorm)
        #expect(texture.swizzle.red == .red)
        #expect(texture.swizzle.green == .red)
        #expect(texture.swizzle.blue == .red)
        #expect(texture.swizzle.alpha == .green)
    }

    @Test("RG88 without the 0x80000 flag (fog/smoke glows) still swizzles to (R,R,R,G)")
    func rg88WithoutAlphaPriorityFlagAlsoSwizzles() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([200, 50, 10, 255, 0, 128, 64, 32])
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rg88.rawValue,
                format: .rg88,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "test-rg88-noflag")

        #expect(texture.pixelFormat == .rg8Unorm)
        #expect(texture.swizzle.red == .red)
        #expect(texture.swizzle.green == .red)
        #expect(texture.swizzle.blue == .red)
        #expect(texture.swizzle.alpha == .green)
    }

    @Test("RG88 shake flow mask keeps raw (R,G) channels — NOT the glow swizzle")
    func rg88FlowMaskIsNotSwizzled() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([200, 50, 10, 255, 0, 128, 64, 32])
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rg88.rawValue,
                format: .rg88,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 2, height: 2, bytes: bytes)],
            hasAnimationFrames: false
        )

        let texture = try await WPEMetalTextureLoader(device: device).makeTexture(from: payload, label: "masks/shake_mask_d3e38905")

        #expect(texture.pixelFormat == .rg8Unorm)
        #expect(texture.swizzle.red == .red)
        #expect(texture.swizzle.green == .green)
        #expect(texture.swizzle.blue == .blue)
        #expect(texture.swizzle.alpha == .alpha)
    }

    @Test("rg88NeedsLuminanceAlphaSwizzle: glow swizzles, mask path does not")
    func rg88SwizzleDiscriminator() {
        #expect(WPEMetalTextureLoader.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: true, label: "particles/fog3"))
        #expect(WPEMetalTextureLoader.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: true, label: "effects/light_shafts/beam_1"))
        #expect(!WPEMetalTextureLoader.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: true, label: "masks/shake_mask_3fab49d9"))
        #expect(!WPEMetalTextureLoader.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: true, label: "MASKS/Shake_Mask_X"))
        #expect(!WPEMetalTextureLoader.rg88NeedsLuminanceAlphaSwizzle(isLuminanceAlpha: false, label: "particles/fog3"))
    }

    @Test("Rejects BC payload when current device cannot sample BC")
    func rejectsBCWithoutDeviceSupport() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 4,
                height: 4,
                textureFormatCode: WPETexFormat.bc7.rawValue,
                format: .bc7,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: Data(count: 16))],
            hasAnimationFrames: false
        )
        let loader = WPEMetalTextureLoader(
            device: device,
            capabilities: WPEMetalTextureCapabilities(supportsBCTextureCompression: false)
        )

        await #expect(throws: WPEMetalTextureLoaderError.unsupportedCompressedFormat(.bc7)) {
            _ = try await loader.makeTexture(from: payload, label: "test-bc7")
        }
    }

    @Test("Payload upload runs on the dedicated upload queue instead of the main thread")
    @MainActor
    func payloadUploadRunsOffMainThread() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let recorder = UploadThreadRecorder()
        let queue = WPEMetalTextureUploadQueue(
            label: "test.livewallpaper.upload.off-main",
            maxConcurrentUploads: 1,
            didStartUpload: { isMainThread in
                recorder.append(isMainThread)
            }
        )
        let loader = WPEMetalTextureLoader(device: device, uploadQueue: queue)
        let payload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 2,
                height: 2,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 1,
                flags: 0
            ),
            mipmaps: [
                WPETexTextureMipmap(
                    index: 0,
                    width: 2,
                    height: 2,
                    bytes: Data([
                        255, 0, 0, 255,
                        0, 255, 0, 255,
                        0, 0, 255, 255,
                        255, 255, 255, 255
                    ])
                )
            ],
            hasAnimationFrames: false
        )

        let texture = try await loader.makeTexture(from: payload, label: "test-rgba-off-main")

        #expect(texture.width == 2)
        #expect(recorder.snapshot() == [false])
    }

    @MainActor
    @Test("Eager animated payload shares one MTLTexture per imageID across frames")
    func eagerAnimatedPayloadSharesOneTexturePerImageID() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var atlasBytes: [UInt8] = []
        atlasBytes.reserveCapacity(4 * 4 * 4)
        for row in 0..<4 {
            for col in 0..<4 {
                atlasBytes.append(contentsOf: [UInt8(row << 4 | col), 0, 0, 0xff])
            }
        }
        let atlasMipmap = WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: Data(atlasBytes))
        let secondAtlas = WPETexTextureMipmap(
            index: 0,
            width: 4,
            height: 4,
            bytes: Data(repeating: 0x55, count: 4 * 4 * 4)
        )

        let track = WPETexAnimationTrack(
            frames: [
                WPETexAnimationFrame(
                    imageID: 0,
                    duration: 0.04,
                    mipmaps: [atlasMipmap],
                    subRect: CGRect(x: 0, y: 0, width: 2, height: 2)
                ),
                WPETexAnimationFrame(
                    imageID: 0,
                    duration: 0.04,
                    mipmaps: [atlasMipmap],
                    subRect: CGRect(x: 2, y: 0, width: 2, height: 2)
                ),
                WPETexAnimationFrame(
                    imageID: 1,
                    duration: 0.04,
                    mipmaps: [secondAtlas],
                    subRect: CGRect(x: 0, y: 2, width: 2, height: 2)
                )
            ],
            frameRate: 25,
            loop: true
        )
        let payload = WPETexTexturePayload(
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
            mipmaps: [],
            hasAnimationFrames: true,
            animationTrack: track
        )

        let source = try await WPEMetalTextureLoader(device: device)
            .makeAnimatedTextureSource(from: payload, label: "test-animated")

        let frame0 = try #require(source.texture(at: 0.0))
        let frame1 = try #require(source.texture(at: 0.05))
        let frame2 = try #require(source.texture(at: 0.09))

        #expect(frame0.width == 4)
        #expect(frame0.height == 4)
        #expect(frame1.width == 4)
        #expect(frame2.width == 4)
        #expect(frame0 === frame1)
        #expect(frame0 !== frame2)
    }

    @Test("Mip chain flag: multi-level payload uploads the full chain only when enabled")
    func mipChainUploadRespectsFlag() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let level0Bytes = Data((0..<64).map { UInt8($0) })
        let level1Bytes = Data([9, 8, 7, 255, 6, 5, 4, 255, 3, 2, 1, 255, 0, 9, 8, 255])
        let multiLevelPayload = WPETexTexturePayload(
            info: WPETexInfo(
                containerVersion: 5,
                infoVersion: 1,
                width: 4,
                height: 4,
                textureFormatCode: WPETexFormat.rgba8888.rawValue,
                format: .rgba8888,
                mipmapCount: 2,
                flags: 0
            ),
            mipmaps: [
                WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: level0Bytes),
                WPETexTextureMipmap(index: 1, width: 2, height: 2, bytes: level1Bytes)
            ],
            hasAnimationFrames: false
        )

        let defaults = UserDefaults.appScoped()
        let key = WPEMetalTextureLoader.mipChainDefaultsKey
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        defaults.set(false, forKey: key)
        let disabledTexture = try await WPEMetalTextureLoader(device: device)
            .makeTexture(from: multiLevelPayload, label: "test-mipchain-off")
        #expect(disabledTexture.mipmapLevelCount == 1)

        defaults.set(true, forKey: key)
        let enabledTexture = try await WPEMetalTextureLoader(device: device)
            .makeTexture(from: multiLevelPayload, label: "test-mipchain-on")
        #expect(enabledTexture.mipmapLevelCount == 2)
        var readBack = [UInt8](repeating: 0, count: level1Bytes.count)
        readBack.withUnsafeMutableBytes { raw in
            enabledTexture.getBytes(
                raw.baseAddress!,
                bytesPerRow: 2 * 4,
                from: MTLRegionMake2D(0, 0, 2, 2),
                mipmapLevel: 1
            )
        }
        #expect(Data(readBack) == level1Bytes)

        let singleLevelPayload = WPETexTexturePayload(
            info: multiLevelPayload.info,
            mipmaps: [WPETexTextureMipmap(index: 0, width: 4, height: 4, bytes: level0Bytes)],
            hasAnimationFrames: false
        )
        let singleLevelTexture = try await WPEMetalTextureLoader(device: device)
            .makeTexture(from: singleLevelPayload, label: "test-mipchain-single-level")
        #expect(singleLevelTexture.mipmapLevelCount == 1)
    }

    @Test("Uploaded source mip metadata follows reduction without changing logical or world dimensions",
          arguments: [0, 128, 64], [64, 128])
    func uploadedSourceMipMetadata(maxEdge: Int, height: Int) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let mipmaps = (0 ... 2).map { level in
            let width = 256 >> level, levelHeight = height >> level
            return WPETexTextureMipmap(index: level, width: width, height: levelHeight,
                                       bytes: Data(repeating: UInt8(level), count: width * levelHeight * 4))
        }
        for flags in [UInt32(0), UInt32(1)] {
            let payload = WPETexTexturePayload(
                info: WPETexInfo(containerVersion: 5, infoVersion: 1, width: 256, height: height,
                                 textureFormatCode: WPETexFormat.rgba8888.rawValue, format: .rgba8888,
                                 mipmapCount: mipmaps.count, flags: flags, imageWidth: 240, imageHeight: height - 8),
                mipmaps: mipmaps, hasAnimationFrames: false
            )
            let texture = try await WPEMetalTextureLoader(device: device).makeTexture(
                from: payload, label: "test-source-mip", maxSourceEdge: maxEdge == 0 ? nil : maxEdge
            )
            defer { WPEMetalTextureMetadataRegistry.shared.unregister(texture: texture) }
            let expectedLevel = maxEdge == 0 || height <= 64 || flags == 1 ? 0 : (maxEdge == 128 ? 1 : 2)
            let resolution = WPEMetalTextureMetadataRegistry.shared.resolution(for: texture)
            #expect(WPEMetalTextureMetadataRegistry.shared.semantics(for: texture) == .straightColor)
            #expect(resolution.sourceMipLevel == mipmaps[expectedLevel].index)
            #expect(texture.width == (256 >> expectedLevel))
            #expect(texture.height == (height >> expectedLevel))
            #expect(resolution.imageWidth == (240 >> expectedLevel))
            #expect(resolution.imageHeight == ((height - 8) >> expectedLevel))
            #expect(resolution.worldWidth == 256)
            #expect(resolution.worldHeight == height)
            #expect(resolution.noInterpolation == (flags == 1))
        }
    }

    @Test("Source mip metadata defaults to zero and re-registration replaces the previous value")
    func sourceMipMetadataDefaultAndReplacement() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 8, height: 4, mipmapped: false)
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let registry = WPEMetalTextureMetadataRegistry.shared
        defer { registry.unregister(texture: texture) }
        #expect(WPEMetalTextureResolution(texture: texture).sourceMipLevel == 0)
        #expect(registry.resolution(for: texture).sourceMipLevel == 0)
        registry.register(texture: texture, imageWidth: 7, imageHeight: 3, worldWidth: 32, worldHeight: 16, sourceMipLevel: 2)
        #expect(registry.resolution(for: texture).sourceMipLevel == 2)
        #expect(registry.resolution(for: texture).shaderValue == .vector([8, 4, 7, 3]))
        registry.register(texture: texture)
        #expect(registry.resolution(for: texture).sourceMipLevel == 0)
        #expect(registry.resolution(for: texture).shaderValue == .vector([8, 4, 8, 4]))
        registry.register(texture: texture, sourceMipLevel: 1)
        #expect(registry.resolution(for: texture).sourceMipLevel == 1)
        registry.unregister(texture: texture)
        #expect(registry.resolution(for: texture).sourceMipLevel == 0)
    }

    @Test("Upload queue semaphore bounds concurrent upload operations")
    func uploadQueueSemaphoreBoundsConcurrency() async throws {
        let probe = UploadConcurrencyProbe()
        let queue = WPEMetalTextureUploadQueue(
            label: "test.livewallpaper.upload.semaphore",
            maxConcurrentUploads: 1
        )

        async let first: Void = queue.perform {
            probe.enter()
            Thread.sleep(forTimeInterval: 0.05)
            probe.leave()
        }
        async let second: Void = queue.perform {
            probe.enter()
            Thread.sleep(forTimeInterval: 0.05)
            probe.leave()
        }

        try await first
        try await second

        #expect(probe.maximumConcurrentUploads == 1)
    }
}

private final class UploadThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Bool] {
        lock.lock()
        let current = values
        lock.unlock()
        return current
    }
}

private final class UploadConcurrencyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeUploads = 0
    private var maximum = 0

    var maximumConcurrentUploads: Int {
        lock.lock()
        let value = maximum
        lock.unlock()
        return value
    }

    func enter() {
        lock.lock()
        activeUploads += 1
        maximum = max(maximum, activeUploads)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        activeUploads -= 1
        lock.unlock()
    }
}
