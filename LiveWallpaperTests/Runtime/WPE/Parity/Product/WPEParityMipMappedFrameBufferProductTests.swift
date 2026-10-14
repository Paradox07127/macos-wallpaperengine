#if !LITE_BUILD && DEBUG
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@testable import LiveWallpaper
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal
import XCTest

/// Reuses the real Driver fixture/compiler/present/readback. The controlled fragment really samples the named
/// mip texture; expected RGB comes from authored primary colours and the native pre-bloom copy order.
extension WPEParitySceneDriverTests {
    /// Fixed independent oracles from original d2c60/d3500: min ceiling exponent minus3, includes base.
    @objc func testNativeMipCountReachesAllocationUniformsAndExplicitLODClamp() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (baseAssets, compiler) = try requiredMipInputs()
        try await withMipNativeScale {
            for (width, height, count) in [(16, 16, 1), (32, 32, 2), (64, 64, 3), (128, 96, 4),
                                           (384, 256, 5), (513, 385, 6), (1024, 16, 1)] {
                let suite = try TestScratch.defaultsSuite(prefix: "WPEParityNativeMipCount")
                defer { suite.discard() }
                suite.defaults.set(false, forKey: "loomscreen.wallpapers.parityMipMappedFrameBufferQuality.v1")
                let settings = try mipProductSettings(device: device, defaults: suite.defaults)
                let (document, assets) = try mipDocument(baseAssets: baseAssets, explicit: true, sampleLOD: 99)
                let driver = try WPEParitySceneDriver(device: device)
                defer { driver.cleanup() }
                let size = CGSize(width: width, height: height)
                try await driver.load(document: document, assets: assets, settings: settings, drawableSize: size,
                                      pixelFormat: .rgba8Unorm_srgb, compiler: compiler,
                                      diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                let renderer = try XCTUnwrap(driver.renderer)
                let texture = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
                let label = "native mip \(width)x\(height)"
                XCTAssertEqual([texture.width, texture.height, texture.sampleCount], [width, height, 1], label)
                XCTAssertEqual(texture.mipmapLevelCount, count, label)
                try assertFreshMipBlack(texture, queue: driver.executor.textureSourceCommandQueue)
                // Binary RGB encodes the level index's low3 bits without transfer/quantization ambiguity.
                // The shader requests LOD99; only the fixed native final level may reach the drawable.
                try seedNativeMipLevels(texture, queue: driver.executor.textureSourceCommandQueue)
                let layer = try mipLayer(device: device, size: size)
                try await present(driver, layer: layer, label: label)
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                XCTAssertTrue(renderer.fallbackTextures.isEmpty)
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first {
                    renderer.frames[0].operations[$0.operation].pass.rawValue == "2/albedo"
                }?.draw)
                XCTAssertTrue(try XCTUnwrap(draw.textures["g_Texture1"]) === texture)
                XCTAssertEqual(mipComponents(draw.constants[.fragment]?["g_Texture1MipMapInfo"]), [Float(count)], label)
                let finalLevel = count - 1
                let expected = [finalLevel & 1, (finalLevel >> 1) & 1, (finalLevel >> 2) & 1].map { $0 * 255 }
                try assertMipPixel(readBack(renderer.backbuffer, device: device), width: width,
                                   x: width / 4, y: height / 2, rgb: expected, label: "raw LOD clamp \(label)")
                try assertMipPixel(readBack(XCTUnwrap(layer.lastTexture), device: device), width: width,
                                   x: width / 4, y: height / 2, rgb: expected, label: "present LOD clamp \(label)")
                XCTAssertFalse(driver.needsContinuousFrames, "no-refresh history stays static")
            }
        }
    }

    private func seedNativeMipLevels(_ texture: MTLTexture, queue: MTLCommandQueue) throws {
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
        var owners: [MTLBuffer] = []
        for level in 0 ..< texture.mipmapLevelCount {
            let width = max(1, texture.width >> level)
            let height = max(1, texture.height >> level)
            let rowBytes = (width * 4 + 255) & ~255
            let buffer = try XCTUnwrap(texture.device.makeBuffer(length: rowBytes * height, options: .storageModeShared))
            owners.append(buffer)
            let data = buffer.contents().bindMemory(to: UInt8.self, capacity: rowBytes * height)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let offset = y * rowBytes + x * 4
                    data[offset] = UInt8((level & 1) * 255)
                    data[offset + 1] = UInt8(((level >> 1) & 1) * 255)
                    data[offset + 2] = UInt8(((level >> 2) & 1) * 255)
                    data[offset + 3] = 255
                }
            }
            encoder.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: rowBytes,
                         sourceBytesPerImage: rowBytes * height, sourceSize: MTLSize(width: width, height: height, depth: 1),
                         to: texture, destinationSlice: 0, destinationLevel: level,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        withExtendedLifetime(owners) {}
    }

    @objc func testMipSnapshotSamplesPreviousSceneThroughDefaultAndExplicitSlotsAndProductPolicy() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (baseAssets, compiler) = try requiredMipInputs()
        try await withMipNativeScale {
            for historySlot in [0, 1] {
                for explicit in [false, true] {
                    for quality in [true, false] {
                        let suite = try TestScratch.defaultsSuite(prefix: "WPEParityMipQuality")
                        defer { suite.discard() }
                        // The product's absent-key policy is on. A canonical bool false selects allocation without refresh.
                        if !quality {
                            suite.defaults.set(false, forKey: "loomscreen.wallpapers.parityMipMappedFrameBufferQuality.v1")
                        }
                        let settings = try mipProductSettings(device: device, defaults: suite.defaults)
                        XCTAssertEqual(settings.mipMappedFrameBufferEnabled, quality)
                        suite.defaults.set(!quality, forKey: "loomscreen.wallpapers.parityMipMappedFrameBufferQuality.v1")
                        XCTAssertEqual(settings.mipMappedFrameBufferEnabled, quality, "the load snapshot is immutable")
                        let (document, assets) = try mipDocument(baseAssets: baseAssets, explicit: explicit, historySlot: historySlot)
                        let driver = try WPEParitySceneDriver(device: device)
                        defer { driver.cleanup() }
                        try await driver.load(document: document, assets: assets, settings: settings,
                                              drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm_srgb,
                                              compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                        let renderer = try XCTUnwrap(driver.renderer)
                        let history = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
                        XCTAssertEqual(history.pixelFormat, .rgba8Unorm)
                        XCTAssertEqual([history.width, history.height, history.sampleCount], [64, 64, 1])
                        XCTAssertEqual(history.mipmapLevelCount, 3, "Native count includes the base level")
                        XCTAssertEqual(driver.needsContinuousFrames, quality,
                                       "a no-g_Time history shader still needs frames exactly when it refreshes")
                        XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                        try assertFreshMipBlack(history, queue: driver.executor.textureSourceCommandQueue)
                        let layer = try mipLayer(device: device, size: CGSize(width: 64, height: 64))
                        let colours: [SIMD4<Float>] = [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0)]
                        let bytes = [[255, 0, 0], [0, 255, 0], [0, 0, 255]]
                        for frame in colours.indices {
                            XCTAssertTrue(renderer.state.set(.color, of: "1", to: colours[frame]))
                            let label = "slot=\(historySlot), explicit=\(explicit), quality=\(quality), frame=\(frame)"
                            try await present(driver, layer: layer, label: label)
                            let sampled = quality && frame > 0 ? bytes[frame - 1] : [0, 0, 0]
                            // Panel centre (16,32), background point (48,32): both are away from all filter/geometry edges.
                            try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 64,
                                               x: 16, y: 32, rgb: sampled, label: "raw history reader \(label)")
                            let shown = try readBack(XCTUnwrap(layer.lastTexture), device: device)
                            try assertMipPixel(shown, width: 64, x: 16, y: 32, rgb: sampled, label: "present \(label)")
                            try assertMipPixel(shown, width: 64, x: 48, y: 32, rgb: bytes[frame], label: "producer \(label)")
                            let draw = try XCTUnwrap(renderer.lastFrameDraws.first {
                                renderer.frames[0].operations[$0.operation].pass.rawValue == "2/albedo"
                            }?.draw)
                            XCTAssertTrue(try XCTUnwrap(draw.textures["g_Texture\(historySlot)"]) === history,
                                          "the real active slot must sample the history allocation: \(label)")
                            XCTAssertEqual(draw.samplers["g_Texture\(historySlot)SamplerState"], .wpe(filter: .linear, address: .clamp))
                            XCTAssertEqual(mipComponents(draw.constants[.fragment]?["g_Texture\(historySlot)MipMapInfo"]), [3])
                            let level2 = try mipBytes(history, level: 2, queue: driver.executor.textureSourceCommandQueue)
                            try assertMipPixel(level2, width: 16, x: 12, y: 8,
                                               rgb: quality ? bytes[frame] : [0, 0, 0],
                                               alpha: nil,
                                               label: "tail copy then actual generated LOD2 \(label)")
                        }
                        XCTAssertTrue(renderer.fallbackTextures.isEmpty)
                    }
                }
            }
        }
    }

    @objc func testMipSnapshotInactiveAnnotationDoesNotAllocateOrWakeTheScene() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (baseAssets, compiler) = try requiredMipInputs()
        try await withMipNativeScale {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityMipInactive")
            defer { suite.discard() }
            let settings = try mipProductSettings(device: device, defaults: suite.defaults)
            XCTAssertTrue(settings.mipMappedFrameBufferEnabled)
            for explicit in [false, true] {
                let (document, assets) = try mipDocument(baseAssets: baseAssets, explicit: explicit, active: false)
                let driver = try WPEParitySceneDriver(device: device)
                defer { driver.cleanup() }
                try await driver.load(document: document, assets: assets, settings: settings,
                                      drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm_srgb,
                                      compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
                let renderer = try XCTUnwrap(driver.renderer)
                XCTAssertNil(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
                XCTAssertFalse(driver.needsContinuousFrames)
                XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
                let layer = try mipLayer(device: device, size: CGSize(width: 64, height: 64))
                try await present(driver, layer: layer, label: "inactive mip declaration \(explicit)")
                try assertMipPixel(readBack(XCTUnwrap(layer.lastTexture), device: device), width: 64,
                                   x: 16, y: 32, rgb: [255, 255, 0], label: "inactive draw still really renders")
                let draw = try XCTUnwrap(renderer.lastFrameDraws.first {
                    renderer.frames[0].operations[$0.operation].pass.rawValue == "2/albedo"
                }?.draw)
                XCTAssertNil(draw.textures["g_Texture1"], "dead sampler annotation is not an active request")
            }
        }
    }

    @objc func testMipSnapshotPreparesAHiddenEffectBeforeItsFirstToggle() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (baseAssets, compiler) = try requiredMipInputs()
        try await withMipNativeScale {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityMipHidden")
            defer { suite.discard() }
            let settings = try mipProductSettings(device: device, defaults: suite.defaults)
            let (document, assets) = try mipDocument(baseAssets: baseAssets, explicit: false,
                                                     active: false, hiddenEffect: true)
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: assets, settings: settings,
                                  drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm_srgb,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            let renderer = try XCTUnwrap(driver.renderer)
            // Only an initially-disabled effect has an active slot. The all-effect preparation fact must exist
            // before that effect's first draw, so readiness cannot deadlock on its undeclared named RT.
            let history = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
            XCTAssertTrue(driver.needsContinuousFrames)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            let layer = try mipLayer(device: device, size: CGSize(width: 64, height: 64))
            try await present(driver, layer: layer, label: "hidden effect seeds red history")
            try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 64,
                               x: 16, y: 32, rgb: [255, 255, 0], label: "effect really begins disabled")
            XCTAssertTrue(renderer.state.setEffect("5", of: "2", visible: true))
            XCTAssertTrue(renderer.state.set(.color, of: "1", to: SIMD4(0, 1, 0, 0)))
            try await present(driver, layer: layer, label: "first hidden-effect toggle")
            try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 64,
                               x: 16, y: 32, rgb: [255, 0, 0], label: "newly enabled effect really samples prior red")
            let effect = try XCTUnwrap(renderer.lastFrameDraws.first {
                renderer.frames[0].operations[$0.operation].pass.rawValue == "2/5/0"
            }?.draw)
            XCTAssertTrue(try XCTUnwrap(effect.textures["g_Texture1"]) === history)
            XCTAssertTrue(renderer.state.setEffect("5", of: "2", visible: false))
            try await present(driver, layer: layer, label: "hide effect again")
            try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 64,
                               x: 16, y: 32, rgb: [255, 255, 0], label: "normal effect cache rebuild")
            XCTAssertTrue(try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer")) === history)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            XCTAssertTrue(renderer.fallbackTextures.isEmpty)
        }
    }

    @objc func testMipSnapshotKeepsCompatibleReplanHistoryAndInitializesEveryMipAfterResize() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (baseAssets, compiler) = try requiredMipInputs()
        try await withMipNativeScale {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityMipResize")
            defer { suite.discard() }
            let settings = try mipProductSettings(device: device, defaults: suite.defaults)
            let (document, assets) = try mipDocument(baseAssets: baseAssets, explicit: false)
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: assets, settings: settings,
                                  drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm_srgb,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            let layer = try mipLayer(device: device, size: CGSize(width: 64, height: 64))
            try await present(driver, layer: layer, label: "red seeds mip history")
            let generation = driver.loadGeneration
            let beforeRenderer = try ObjectIdentifier(XCTUnwrap(driver.renderer))
            let beforeHistory = try ObjectIdentifier(XCTUnwrap(driver.renderer?.renderTarget("_rt_MipMappedFrameBuffer")))
            // Store only identities; the guard does not keep the old renderer or target alive across replacement.
            driver.setPresentFitMode(.stretch)
            XCTAssertTrue(driver.needsReplan)
            let replanned = await driver.replan()
            XCTAssertTrue(replanned)
            XCTAssertEqual(driver.loadGeneration, generation)
            XCTAssertNotEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer)), beforeRenderer)
            XCTAssertEqual(try ObjectIdentifier(XCTUnwrap(driver.renderer?.renderTarget("_rt_MipMappedFrameBuffer"))),
                           beforeHistory)
            do {
                let renderer = try XCTUnwrap(driver.renderer)
                let history = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
                try assertMipPixel(mipBytes(history, level: 2, queue: driver.executor.textureSourceCommandQueue),
                                   width: 16, x: 12, y: 8, rgb: [255, 0, 0],
                                   label: "compatible replan must not apply an initialClear to retained history")
                XCTAssertTrue(renderer.state.set(.color, of: "1", to: SIMD4(0, 1, 0, 0)))
                try await present(driver, layer: layer, label: "green after compatible replan")
                try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 64,
                                   x: 16, y: 32, rgb: [255, 0, 0], label: "retained red sampled after replan")
            }

            driver.updateSurfaceGeometry(drawableSize: CGSize(width: 72, height: 40))
            XCTAssertTrue(driver.needsReplan)
            let resized = await driver.replan()
            XCTAssertTrue(resized)
            XCTAssertEqual(driver.loadGeneration, generation)
            do {
                let renderer = try XCTUnwrap(driver.renderer)
                let history = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
                XCTAssertNotEqual(ObjectIdentifier(history), beforeHistory)
                XCTAssertEqual([history.width, history.height], [72, 40])
                try assertFreshMipBlack(history, queue: driver.executor.textureSourceCommandQueue)
                layer.drawableSize = CGSize(width: 72, height: 40)
                try await present(driver, layer: layer, label: "first frame at new size")
                // Stretch preserves the authored 64×64 ortho: (16,32) projects to (18,20) in 72×40.
                try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 72,
                                   x: 18, y: 20, rgb: [0, 0, 0], label: "new descriptor starts safe black")
                try await present(driver, layer: layer, label: "second frame at new size")
                try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 72,
                                   x: 18, y: 20, rgb: [0, 255, 0], label: "new history receives current green scene")
            }
            driver.cleanup()
            XCTAssertNil(driver.renderer)
        }
    }

    @MainActor @objc func testMipSnapshotDoesNotRunItsTailCopyAfterARealLateDrawFailure() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (baseAssets, compiler) = try requiredMipInputs()
        try await withMipNativeScale {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityMipPrefix")
            defer { suite.discard() }
            let settings = try mipProductSettings(device: device, defaults: suite.defaults)
            let (document, assets) = try mipDocument(baseAssets: baseAssets, explicit: false, lateFailure: true)
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: assets, settings: settings,
                                  drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm_srgb,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            let renderer = try XCTUnwrap(driver.renderer)
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            let history = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
            let layer = try mipLayer(device: device, size: CGSize(width: 64, height: 64))
            let source = MipFailureMediaSource()
            let dispatcher = WPESceneMediaEventDispatcher(source: source)
            defer { dispatcher.stop() }
            XCTAssertTrue(dispatcher.mailbox.beginParityGeneration(driver.loadGeneration))
            XCTAssertTrue(dispatcher.configureParity(generation: driver.loadGeneration, device: device,
                                                     textureDemand: true, onChange: {}))
            renderer.attachMedia(dispatcher.mailbox, generation: driver.loadGeneration)
            try await present(driver, layer: layer, label: "valid volume draw seeds red history")
            let originalLUT = try XCTUnwrap(renderer.lastFrameDraws.first {
                renderer.frames[0].operations[$0.operation].pass.rawValue == "3/8/0"
            }?.draw.textures["g_Texture1"])
            XCTAssertEqual(originalLUT.textureType, .type3D)

            try source.push(artwork: mipFailureArtwork())
            XCTAssertTrue(renderer.state.set(.color, of: "1", to: SIMD4(0, 1, 0, 0)))
            var caught: (any Error)?
            do {
                _ = try renderer.encodeFrame(elapsed: 1.0 / 60)
                XCTFail("The real media2D → original ccsimple sampler3D emit must throw")
            } catch {
                caught = error
            }
            XCTAssertEqual(try XCTUnwrap(caught as? WPEParityExecutionError),
                           .textureDimensionMismatch("g_Texture1", expected: "3d", actual: MTLTextureType.type2D.rawValue))
            let media = try XCTUnwrap(renderer.mediaTextures?.current)
            let failed = try XCTUnwrap(renderer.lastFrameDraws.last)
            XCTAssertTrue(try XCTUnwrap(failed.draw.textures["g_Texture1"]) === media)
            XCTAssertEqual(media.textureType, .type2D)
            let reader = try XCTUnwrap(renderer.lastFrameDraws.first {
                renderer.frames[0].operations[$0.operation].pass.rawValue == "2/albedo"
            })
            XCTAssertLessThan(reader.operation, failed.operation)
            XCTAssertTrue(try XCTUnwrap(reader.draw.textures["g_Texture1"]) === history)
            // The throwing caller returns no CB. This same-producer-queue blit is a real marker behind its prefix.
            let prefix = try mipBytes(renderer.backbuffer, level: 0, queue: driver.executor.textureSourceCommandQueue)
            try assertMipPixel(prefix, width: 64, x: 48, y: 32, rgb: [0, 255, 0], label: "green prefix was committed")
            try assertMipPixel(prefix, width: 64, x: 16, y: 32, rgb: [255, 0, 0], label: "prefix really sampled red history")
            try assertMipPixel(mipBytes(history, level: 2, queue: driver.executor.textureSourceCommandQueue),
                               width: 16, x: 12, y: 8, rgb: [255, 0, 0], label: "unreached tail leaves history red")
            XCTAssertTrue(renderer.state.set(.visible, of: "3", to: .zero))
            try await present(driver, layer: layer, label: "recover by hiding only the failing layer")
            try assertMipPixel(readBack(renderer.backbuffer, device: device), width: 64,
                               x: 16, y: 32, rgb: [255, 0, 0], label: "recovery still reads the last executed tail")
            try assertMipPixel(mipBytes(history, level: 2, queue: driver.executor.textureSourceCommandQueue),
                               width: 16, x: 12, y: 8, rgb: [0, 255, 0], label: "only successful recovery advances history")
            XCTAssertTrue(renderer.fallbackTextures.isEmpty)
        }
    }

    @objc func testMipSnapshotHDRLODStoresPreBloomValuesBeforeTheLinearTerminal() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (baseAssets, compiler) = try requiredMipInputs()
        try await withMipNativeScale {
            let suite = try TestScratch.defaultsSuite(prefix: "WPEParityMipHDR")
            defer { suite.discard() }
            let settings = try mipProductSettings(device: device, defaults: suite.defaults, bloomEnabled: true)
            let (document, assets) = try mipDocument(baseAssets: baseAssets, explicit: false, hdr: true)
            let driver = try WPEParitySceneDriver(device: device)
            defer { driver.cleanup() }
            try await driver.load(document: document, assets: assets, settings: settings,
                                  drawableSize: CGSize(width: 64, height: 64), pixelFormat: .rgba8Unorm_srgb,
                                  compiler: compiler, diskCache: WPEParityShaderDiskCache(cachesURL: scratch))
            let renderer = try XCTUnwrap(driver.renderer)
            let history = try XCTUnwrap(renderer.renderTarget("_rt_MipMappedFrameBuffer"))
            XCTAssertEqual(history.pixelFormat, .rgba16Float)
            XCTAssertEqual([history.width, history.height, history.sampleCount, history.mipmapLevelCount], [64, 64, 1, 3])
            XCTAssertTrue(renderer.skipped.isEmpty, "\(renderer.skipped)")
            XCTAssertTrue(driver.needsContinuousFrames)
            try assertFreshMipBlack(history, queue: driver.executor.textureSourceCommandQueue)
            let layer = try mipLayer(device: device, size: CGSize(width: 64, height: 64))
            for frame in 0 ..< 2 {
                try await present(driver, layer: layer, label: "HDR history frame \(frame)")
                // Exact binary values survive either FP16 storage rounding policy. Strength=0 disables bloom's
                // contribution while the real original HDR terminal still changes/clamps these authored values.
                try assertMipFloatPixel(mipBytes(history, level: 2, queue: driver.executor.textureSourceCommandQueue),
                                        width: 16, x: 12, y: 8, rgba: [2, 0.5, 0.25, 1], label: "pre-bloom HDR LOD2")
                let reader = try XCTUnwrap(renderer.lastFrameDraws.first {
                    renderer.frames[0].operations[$0.operation].pass.rawValue == "2/albedo"
                }?.draw)
                XCTAssertTrue(try XCTUnwrap(reader.textures["g_Texture1"]) === history)
                XCTAssertEqual(reader.samplers["g_Texture1SamplerState"], .wpe(filter: .linear, address: .clamp))
                XCTAssertEqual(mipComponents(reader.constants[.fragment]?["g_Texture1MipMapInfo"]), [3])
                let combine = try XCTUnwrap(renderer.lastFrameDraws.first {
                    renderer.frames[0].operations[$0.operation].pass.rawValue == "combine_hdr"
                }?.draw)
                let scene = try XCTUnwrap(combine.textures["g_Texture0"])
                let previous: [Float] = frame == 0 ? [0, 0, 0, 1] : [2, 0.5, 0.25, 1]
                try assertMipFloatPixel(mipBytes(scene, level: 0, queue: driver.executor.textureSourceCommandQueue),
                                        width: 64, x: 16, y: 32, rgba: previous, label: "actual floating LOD2 reader before post")
                try assertMipFloatPixel(readBack(renderer.backbuffer, device: device), width: 64,
                                        x: 48, y: 32, rgba: [1, Float(pow((0.5 + 0.055) / 1.055, 2.4)),
                                                             Float(pow((0.25 + 0.055) / 1.055, 2.4)), 1],
                                        accuracy: 0.001, label: "independent original lin + clamp terminal")
                let shown = try readBack(XCTUnwrap(layer.lastTexture), device: device)
                try assertMipPixel(shown, width: 64, x: 48, y: 32, rgb: [255, 128, 64], label: "single linear present transfer")
                try assertMipPixel(shown, width: 64, x: 16, y: 32,
                                   rgb: frame == 0 ? [0, 0, 0] : [255, 128, 64], label: "HDR previous-frame reader present")
            }
            XCTAssertTrue(renderer.fallbackTextures.isEmpty)
        }
    }

    private func mipProductSettings(device: MTLDevice, defaults: UserDefaults, bloomEnabled: Bool = false) throws -> WPEParityProgramSettings {
        let descriptor = SceneDescriptor(workshopID: "mip-product", cacheRelativePath: "wpe-cache/mip-product",
                                         entryFile: "scene.json", capabilityTier: .imageOnly, presetID: "mip",
                                         presetSnapshot: [:])
        return try WPEParityProductSettings.make(descriptor: descriptor, device: device, defaults: defaults,
                                                 bloomEnabled: bloomEnabled)
    }

    private func requiredMipInputs() throws -> (WPEParityProgramAssets, WPEParityHelperShaderCompiler) {
        do {
            let (_, assets) = try sceneInputs()
            return try (assets, makeCompiler())
        } catch {
            throw NSError(domain: "WPEParityMipMappedFrameBufferProductTests.RequiredInputs", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Required original assets/toolchain unavailable: \(error)"])
        }
    }

    private func mipDocument(baseAssets: WPEParityProgramAssets, explicit: Bool, active: Bool = true,
                             hdr: Bool = false, lateFailure: Bool = false, hiddenEffect: Bool = false, historySlot: Int = 1, sampleLOD: Int? = nil)
        throws -> (WPESceneDocument, WPEParityProgramAssets) {
        let vertex = try XCTUnwrap(baseAssets.data("shaders/passthrough.vert"))
        let hash = SHA256.hash(data: vertex).map { String(format: "%02x", $0) }.joined()
        _ = try XCTUnwrap(hash == "ff6cd2bb166ce427c73058f3f77f338442d83fab9883f302e31bbffd81fa5317" ? true : nil,
                          "Required pinned original passthrough vertex consumer")
        for (path, hash) in [
            ("shaders/flat.frag", "7e0503a1821089475b884e4e8b0fb1987108f7d00c5cb353da7695eac7796477"),
            ("shaders/flat.vert", "3659d0455c48d9c57b329675c42ce0e7f76628865bc2ce7c8452e1b63fdb9805"),
            ("materials/util/solidlayer.json", "2bbc99c15f38041dfb636b4fb8afe975de500c3ad4eb5bd09b616564d46c7b59"),
            ("models/util/solidlayer.json", "a39818343c99fbff21b3a21b962871618c63c0a9257cf944dc09d20d54e3f5ea"),
        ] {
            let data = try XCTUnwrap(baseAssets.data(path))
            _ = try XCTUnwrap(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash ? true : nil,
                              "Required original flat producer identity: \(path)")
        }
        let fragment = """
        // [COMBO] {"combo":"READMIP","default":0}
        uniform sampler2D g_Texture\(historySlot); // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
        uniform float g_Texture\(historySlot)MipMapInfo;
        void main() {
        #if READMIP
            // LOD2 is real high-mip sampling. Its footprint at (.75,.5) lies entirely outside the reader panel.
            float lod = \(sampleLOD.map { "\($0).0" } ?? "min(2.0, max(0.0, g_Texture\(historySlot)MipMapInfo - 1.0))");
            gl_FragColor = vec4(texSample2DLod(g_Texture\(historySlot), vec2(0.75, 0.5), lod).rgb, 1.0);
        #else
            gl_FragColor = vec4(1.0, 1.0, 0.0, 1.0);
        #endif
        }
        """
        var pass: [String: Any] = ["shader": "mip-history-reader", "combos": ["TRANSFORM": 1, "READMIP": active ? 1 : 0],
                                   "blending": "normal", "cullmode": "nocull",
                                   "depthtest": "disabled", "depthwrite": "disabled"]
        if explicit {
            pass["textures"] = Array(repeating: "util/white", count: historySlot) + ["_rt_MipMappedFrameBuffer"]
        }
        var files: [String: Data] = try [
            "models/mip-history-reader.json": JSONSerialization.data(withJSONObject: ["material": "materials/mip-history-reader.json"]),
            "materials/mip-history-reader.json": JSONSerialization.data(withJSONObject: ["passes": [pass]]),
            "shaders/mip-history-reader.vert": vertex,
            "shaders/mip-history-reader.frag": Data(fragment.utf8),
        ]
        if lateFailure {
            for (name, hash) in [
                ("ccsimple.frag", "0cb10ceff0b7fe6e14576928ee09e4d2fed7fb405dc6ff38d94970687e46ed3b"),
                ("ccsimple.vert", "25d48e4e45c8f2092e87d1a29eb2aeb62e5592e1581a6efc15dd06e9790f53cd"),
            ] {
                let data = try XCTUnwrap(baseAssets.data("shaders/" + name))
                _ = try XCTUnwrap(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash ? true : nil,
                                  "Required original shader identity: \(name)")
            }
            files["materials/mip-valid-volume.tex"] = mipVolume()
            files["effects/mip-late-failure.json"] = try JSONSerialization.data(withJSONObject: [
                "passes": [["material": "materials/mip-late-failure.json"]],
            ])
            files["materials/mip-late-failure.json"] = try JSONSerialization.data(withJSONObject: ["passes": [[
                "shader": "ccsimple", "combos": ["LUT": 1, "COL": 0],
                "textures": ["previous", "mip-valid-volume"],
                "usertextures": [NSNull(), ["name": "$mediaThumbnail", "type": "system"]],
                "blending": "normal", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled",
            ]]])
        }
        if hdr {
            for (path, hash) in [
                ("shaders/hdr_downsample.frag", "f702cc282d08b6c618646ee78305991139185e626e454ab8a2e40600bb41c874"),
                ("shaders/hdr_downsample.vert", "8a1ffaa2cbf79f3be3faa3e1aac5670d66711ec656cfdb1d5a89d8b6614e80b0"),
                ("shaders/combine_hdr.frag", "755db6efba18303898c9a7fb2cb892f57fcddd11888d840e1be826d535ed83f2"),
                ("shaders/combine_hdr.vert", "25d48e4e45c8f2092e87d1a29eb2aeb62e5592e1581a6efc15dd06e9790f53cd"),
                ("materials/util/hdr_downsample_bloom.json", "1aee61c3e2bc1f641a07ddc4cbfb52dafa22ffcec31afd4a2d182fbf2d3397a5"),
                ("materials/util/hdr_downsample.json", "3e453dfe06db50adaf07a7c2ca4b273bb5144088147076b71aa4b035f8b281fc"),
                ("materials/util/hdr_upsample_cubic.json", "70e6751ef097672998991213b9715182b9e4734119a3c9c742b73f42bb0603bd"),
                ("materials/util/hdr_upsample.json", "05d5ab7aa51b0b006ec69d80c5e668d977ad8fb6ea6c782c2997626635f03d12"),
                ("materials/util/combine_hdr_upsample.json", "844d885484c09908882065d7663b8d39c415e194c638bc0ea7ff706c14549ce1"),
            ] {
                let data = try XCTUnwrap(baseAssets.data(path))
                _ = try XCTUnwrap(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == hash ? true : nil,
                                  "Required original util identity: \(path)")
            }
        }
        if hiddenEffect {
            var effectPass = pass
            effectPass["combos"] = ["TRANSFORM": 1, "READMIP": 1]
            files["materials/mip-hidden-reader.json"] = try JSONSerialization.data(withJSONObject: ["passes": [effectPass]])
            files["effects/mip-hidden-reader.json"] = try JSONSerialization.data(withJSONObject: [
                "passes": [["material": "materials/mip-hidden-reader.json"]],
            ])
        }
        var readerObject: [String: Any] = ["id": 2, "image": "models/mip-history-reader.json",
                                           "name": "actual LOD2 history reader", "size": "16 16", "origin": "16 32 0"]
        if hiddenEffect {
            readerObject["effects"] = [["id": 5, "file": "effects/mip-hidden-reader.json", "visible": false]]
        }
        var objects: [[String: Any]] = [
            ["id": 1, "image": "models/util/solidlayer.json", "name": "primary-colour producer", "size": "64 64",
             "origin": "32 32 0", "color": hdr ? "1 0.25 0.125" : "1 0 0", "brightness": hdr ? 2 : 1, "solid": true],
            readerObject,
        ]
        if lateFailure {
            objects.append(["id": 3, "image": "models/util/solidlayer.json", "name": "real late dimension failure",
                            "size": "8 8", "origin": "48 16 0", "color": "0 0 0", "solid": true,
                            "effects": [["id": 8, "file": "effects/mip-late-failure.json"]]])
        }
        let fixtureFiles = files
        let assets = WPEParityProgramAssets(sources: [.lookup(scratch) { fixtureFiles[$0] }] + baseAssets.sources)
        let json: [String: Any] = [
            "camera": ["center": "0 0 -1", "eye": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 64, "height": 64], "clearcolor": "0 0 0",
                        "clearenabled": true, "bloom": hdr, "hdr": hdr, "camerafade": false,
                        "bloomhdriterations": 4, "bloomhdrstrength": 0, "bloomhdrthreshold": 0.4,
                        "bloomhdrfeather": 0.5, "bloomhdrscatter": 0.5, "bloomtint": "1 1 1"],
            "objects": objects,
        ]
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: json), userValues: [:],
                                                        makeTransformScriptResolver: { _, _ in NoScripts() })
        return (document, assets)
    }

    private func mipLayer(device: MTLDevice, size: CGSize) throws -> RecordingLayer {
        let layer = RecordingLayer()
        layer.device = device
        layer.pixelFormat = .rgba8Unorm_srgb
        layer.colorspace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        layer.framebufferOnly = false
        layer.drawableSize = size
        return layer
    }

    private nonisolated(nonsending) func withMipNativeScale(_ body: () async throws -> Void) async throws {
        let defaults = UserDefaults.appScoped()
        guard defaults !== UserDefaults.standard else {
            throw NSError(domain: "WPEParityMipMappedFrameBufferProductTests.Isolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Product gate requires isolated app defaults"])
        }
        let key = WPEMetalFXSpatialUpscaler.renderScaleDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(1.0, forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        try await body()
    }

    private func mipComponents(_ value: WPECBufferValue?) -> [Float] {
        switch value {
        case let .float(value)?: [value]
        case let .vector(values)?: values
        default: []
        }
    }

    private func assertMipPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int, rgb: [Int], alpha: Int? = 255, label: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let offset = (y * width + x) * 4
        _ = try XCTUnwrap(offset >= 0 && offset + 3 < bytes.count ? true : nil, label, file: file, line: line)
        for channel in 0 ..< 3 {
            XCTAssertLessThanOrEqual(abs(Int(bytes[offset + channel]) - rgb[channel]), 1,
                                     "\(label), channel \(channel)", file: file, line: line)
        }
        if let alpha {
            XCTAssertEqual(Int(bytes[offset + 3]), alpha, "\(label), opaque terminal/draw alpha", file: file, line: line)
        }
    }

    private func assertFreshMipBlack(_ texture: MTLTexture, queue: MTLCommandQueue) throws {
        for level in 0 ..< texture.mipmapLevelCount {
            let bytes = try mipBytes(texture, level: level, queue: queue)
            let rgbBytes = texture.pixelFormat == .rgba16Float ? 6 : 3
            let pixelBytes = texture.pixelFormat == .rgba16Float ? 8 : 4
            XCTAssertTrue(stride(from: 0, to: bytes.count, by: pixelBytes).allSatisfy { offset in
                (0 ..< rgbBytes).allSatisfy { bytes[offset + $0] == 0 }
            }, "Mac safe initialization must cover actual mip \(level), before any scene reader")
        }
    }

    /// Ordered on the actual producer queue, including the initial clear submitted during load/replan.
    private func mipBytes(_ texture: MTLTexture, level: Int, queue: MTLCommandQueue) throws -> [UInt8] {
        _ = try XCTUnwrap([MTLPixelFormat.rgba8Unorm, .rgba16Float].contains(texture.pixelFormat) ? true : nil)
        let width = max(1, texture.width >> level)
        let height = max(1, texture.height >> level)
        let rowBytes = width * (texture.pixelFormat == .rgba16Float ? 8 : 4)
        let padded = (rowBytes + 255) & ~255
        let buffer = try XCTUnwrap(texture.device.makeBuffer(length: padded * height, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
        encoder.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                     destinationBytesPerRow: padded, destinationBytesPerImage: padded * height)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        XCTAssertNil(command.error)
        let source = UnsafeRawBufferPointer(start: buffer.contents(), count: padded * height)
        return (0 ..< height).flatMap { Array(source[($0 * padded) ..< ($0 * padded + rowBytes)]) }
    }

    private func assertMipFloatPixel(_ bytes: [UInt8], width: Int, x: Int, y: Int, rgba: [Float],
                                     accuracy: Float = 0, label: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let offset = (y * width + x) * 8
        _ = try XCTUnwrap(offset >= 0 && offset + 7 < bytes.count ? true : nil, label, file: file, line: line)
        for channel in 0 ..< 4 {
            let word = UInt16(bytes[offset + channel * 2]) | UInt16(bytes[offset + channel * 2 + 1]) << 8
            XCTAssertEqual(Float(Float16(bitPattern: word)), rgba[channel], accuracy: accuracy,
                           "\(label), channel \(channel)", file: file, line: line)
        }
    }

    /// A minimal real TEXV0005 raw 2×2×2 identity volume. No encoded-volume callback assumption is needed.
    private func mipVolume() -> Data {
        var data = Data()
        func magic(_ value: String) {
            data.append(contentsOf: value.utf8); data.append(0)
        }
        func words(_ values: [UInt32]) {
            for value in values {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
        }
        magic("TEXV0005"); magic("TEXI0001")
        words([0, 0x42, 2, 2, 2, 2, 2, 0])
        magic("TEXB0003")
        words([1, .max, 1, 2, 2, 2, 0, 32, 32])
        for index in 0 ..< 8 {
            data.append(contentsOf: [UInt8((index >> 2) * 255), UInt8((index & 1) * 255),
                                     UInt8(((index >> 1) & 1) * 255), 255])
        }
        return data
    }

    private func mipFailureArtwork() throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([UInt8(128), 64, 192, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                                          space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        _ = try XCTUnwrap(CGImageDestinationFinalize(destination) ? true : nil)
        return data as Data
    }
}

@MainActor
private final class MipFailureMediaSource: WPENowPlayingEventSource {
    private var handlers: [UUID: @Sendable (UInt64, MonitorNowPlayingState) -> Void] = [:]
    func subscribe(id: UUID, handler: @escaping @Sendable (UInt64, MonitorNowPlayingState) -> Void) {
        handlers[id] = handler
        handler(0, .init(phase: .awaitingFirstEvent, title: ""))
    }

    func unsubscribe(id: UUID) {
        handlers[id] = nil
    }

    func push(artwork: Data) {
        for handler in handlers.values {
            handler(1, .init(phase: .paused, title: "Mip prefix", artwork: artwork))
        }
    }
}
#endif
