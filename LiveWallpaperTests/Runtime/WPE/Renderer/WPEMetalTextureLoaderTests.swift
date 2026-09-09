import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal texture loader")
struct WPEMetalTextureLoaderTests {

    @MainActor
    @Test("Rain quads preserve model scale and trails retain local speed and frame aspect",
          arguments: [-1, 0, 4], [SIMD3<Float>(1, 1, 0), SIMD3<Float>(0.5, 0.5, 0),
                                  SIMD3<Float>(0.5, 1, 0), SIMD3<Float>(0.5, 1, .pi / 2),
                                  SIMD3<Float>(-0.5, 1, 0)])
    func rainTrailGeometry(flags: Int, scale: SIMD3<Float>) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        // Windows Lofi Cafe uses 32x128 drop textures and velocity-based stretch,
        // including flags=4. Keep depth zero to isolate trail geometry from projection.
        let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "flags": max(0, flags), "maxcount": 1,
            "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 8, "max": 8],
                            ["name": "lifetimerandom", "min": 10, "max": 10],
                            ["name": "velocityrandom", "min": "0 -100 0", "max": "0 -100 0"]],
            "renderer": flags < 0 ? [] : [["name": "spritetrail", "length": 0.05, "maxlength": 6]],
        ]))
        let system = try #require(WPEParticleSystem(
            definition: definition, device: device,
            sceneTransform: WPEParticleSceneTransform(
                sceneSize: SIMD2<Float>(256, 256), objectOrigin: SIMD3<Float>(128, 128, 0),
                objectScale: SIMD3<Float>(scale.x, scale.y, 1), objectAngleZ: scale.z
            ), seed: 133
        ))
        system.tick(now: 0)
        system.tick(now: 0.05)
        try #require(system.liveInstanceCount == 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        let zero = [UInt8](repeating: 0, count: 256 * 256 * 4)
        output.replace(region: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0, withBytes: zero, bytesPerRow: 1024)
        let textureHeight = flags < 0 ? 32 : 128
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: textureHeight, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = .shaderRead
        let albedo = try #require(device.makeTexture(descriptor: textureDescriptor))
        albedo.replace(region: MTLRegionMake2D(0, 0, 32, textureHeight), mipmapLevel: 0,
                       withBytes: [UInt8](repeating: 255, count: 32 * textureHeight * 4), bytesPerRow: 128)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let size = CGSize(width: 256, height: 256)
        var state = WPEMetalFrameState(output: output, sceneSize: size)
        try executor.encodeParticleSystem(
            system, into: command, output: output, sceneSize: size, cameraParallax: .neutral,
            texturesByMaterial: [ObjectIdentifier(system): albedo], normalsByMaterial: [:],
            frameState: &state, traceIndex: 0
        )
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        var pixels = zero
        output.getBytes(&pixels, bytesPerRow: 1024, from: MTLRegionMake2D(0, 0, 256, 256), mipmapLevel: 0)
        var xs: [Int] = []
        var ys: [Int] = []
        for y in 0 ..< 256 {
            for x in 0 ..< 256 where pixels[(y * 256 + x) * 4] > 0 {
                xs.append(x)
                ys.append(y)
            }
        }
        let width = try #require(xs.max()) - #require(xs.min()) + 1
        let height = try #require(ys.max()) - #require(ys.min()) + 1
        let localWidth = Int(8 * abs(scale.x))
        let localHeight = Int((flags < 0 ? 8 : 160) * abs(scale.y))
        let expectedWidth = scale.z == 0 ? localWidth : localHeight
        let expectedHeight = scale.z == 0 ? localHeight : localWidth
        #expect(abs(width - expectedWidth) <= 1)
        #expect(abs(height - expectedHeight) <= 2, "Expected \(expectedWidth)x\(expectedHeight), got \(width)x\(height)")
    }

    @MainActor
    @Test("Zero refraction preserves the background across the whole particle quad")
    func zeroRefractionPreservesBackground() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let definition = try #require(WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 1, "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 80, "max": 80],
                            ["name": "lifetimerandom", "min": 10, "max": 10]],
        ]))
        let system = try #require(WPEParticleSystem(definition: definition, device: device, blendMode: .translucent, seed: 133))
        system.isRefract = true
        system.refractAmount = 0
        system.tick(now: 0)
        system.tick(now: 0.05)
        try #require(system.liveInstanceCount == 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 128, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let output = try #require(device.makeTexture(descriptor: descriptor))
        var pixels: [UInt8] = []
        for y in 0 ..< 128 {
            for x in 0 ..< 128 {
                pixels.append(contentsOf: [UInt8(x * 2), UInt8(y * 2), 80, 255])
            }
        }
        output.replace(region: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0, withBytes: pixels, bytesPerRow: 512)
        let small = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        small.storageMode = .shared
        small.usage = .shaderRead
        let albedo = try #require(device.makeTexture(descriptor: small))
        let normal = try #require(device.makeTexture(descriptor: small))
        albedo.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        normal.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](arrayLiteral: 255, 129, 0, 128), bytesPerRow: 4)
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let size = CGSize(width: 128, height: 128)
        var state = WPEMetalFrameState(output: output, sceneSize: size)
        try executor.encodeParticleSystem(
            system, into: command, output: output, sceneSize: size, cameraParallax: .neutral,
            texturesByMaterial: [ObjectIdentifier(system): albedo], normalsByMaterial: [ObjectIdentifier(system): normal],
            frameState: &state, traceIndex: 0
        )
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        var rendered = [UInt8](repeating: 0, count: pixels.count)
        output.getBytes(&rendered, bytesPerRow: 512, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0)
        #expect(stride(from: 3, to: rendered.count, by: 4).allSatisfy { rendered[$0] == 255 },
                "Translucent droplets must preserve an already opaque scene's alpha")
        #expect(zip(pixels, rendered).allSatisfy { abs(Int($0) - Int($1)) <= 1 })
    }

    @MainActor
    @Test("Animated normal maps preserve linear sampling through upload and restore")
    func animatedNormalMapsPreserveLinearSampling() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Lofi Cafe's flat atlas border: red=mask, green=normal Y, alpha=normal X.
        let bytes = Data([255, 129, 0, 128])
        let info = WPETexInfo(
            containerVersion: 5, infoVersion: 1, width: 1, height: 1,
            textureFormatCode: WPETexFormat.rgba8888.rawValue,
            format: .rgba8888, mipmapCount: 1, flags: 0
        )
        let mip = WPETexTextureMipmap(index: 0, width: 1, height: 1, bytes: bytes)
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let payload = WPETexTexturePayload(
            info: info, mipmaps: [], hasAnimationFrames: true,
            animationTrack: WPETexAnimationTrack(
                frames: [WPETexAnimationFrame(imageID: 0, duration: 0.1, mipmaps: [mip], subRect: rect)],
                frameRate: 10, loop: true
            )
        )
        let streaming = WPETexStreamingPayload(
            info: info,
            compressedImages: [WPETexCompressedImage(width: 1, height: 1, payloads: [
                WPETexCompressedMipmap(
                    index: 0, width: 1, height: 1, isCompressed: false,
                    compressedBytes: bytes, decompressedByteCount: bytes.count
                ),
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
        let lazy = try loader.makeLazyAnimatedTextureSource(from: streaming, label: "normal", colorSpace: .linear)
        let streamed = try #require(lazy.texture(at: 0))
        for texture in [initial, restored, streamed] {
            #expect(texture.pixelFormat == .rgba8Unorm)
            let normal = try sampleNormal(texture, device: device)
            #expect(abs(normal.x) < 0.02 && abs(normal.y) < 0.02,
                    "A flat normal border must not displace the whole particle quad")
        }
        let color = try await loader.makeAnimatedTextureSource(from: payload, label: "color")
        #expect(color.texture(at: 0)?.pixelFormat == .rgba8Unorm_srgb)
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

    @Test("Uploads RGBA texture payload into an MTLTexture")
    func uploadsRGBA8888Payload() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let bytes = Data([
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 255, 255,
            255, 255, 255, 255
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
        #expect(texture.pixelFormat == .rgba8Unorm_srgb)
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

        let defaults = UserDefaults.standard
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
