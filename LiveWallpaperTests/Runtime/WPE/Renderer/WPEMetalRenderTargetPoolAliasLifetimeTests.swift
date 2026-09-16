import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

/// `endPass` releases alias-heap textures by the pool's key→lastPass mapping, so a plan
/// reuse that keeps a stale mapping makes a still-live target aliasable early.
@Suite("WPEMetalRenderTargetPool — alias plan reuse keeps lifetimes current")
struct WPEMetalRenderTargetPoolAliasLifetimeTests {
    private static let sceneSize = CGSize(width: 64, height: 64)

    private static func layer(fboNames: [String]) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "obj",
            objectName: "obj",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_obj_a",
            compositeB: "_rt_imageLayerComposite_obj_b",
            localFBOs: fboNames.map { WPERenderFBO(name: $0, scale: 1, format: "rgba8888") },
            passes: []
        )
    }

    private static func pipeline(_ layer: WPERenderLayer) -> WPEPreparedRenderPipeline {
        WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: [])])
    }

    private static func interval(
        _ pool: WPEMetalRenderTargetPool,
        _ layer: WPERenderLayer,
        _ name: String,
        _ firstPass: Int,
        _ lastPass: Int,
        sceneSize: CGSize = sceneSize
    ) -> WPEMetalRenderTargetPool.AliasInterval {
        let declared = Dictionary(uniqueKeysWithValues: layer.localFBOs.map { ($0.name, $0) })
        return WPEMetalRenderTargetPool.AliasInterval(
            key: pool.diagnosticKey(
                for: .fbo(name: name), layer: layer, sceneSize: sceneSize, declaredFBOs: declared
            ),
            firstPass: firstPass,
            lastPass: lastPass
        )
    }

    private static func texture(
        _ pool: WPEMetalRenderTargetPool,
        _ layer: WPERenderLayer,
        _ name: String,
        sceneSize: CGSize = sceneSize
    ) throws -> MTLTexture {
        try pool.texture(for: .fbo(name: name), layer: layer, sceneSize: sceneSize, avoiding: nil)
    }

    @Test("Swapped lifetimes behind an identical size/pass sequence refresh the release schedule")
    func swappedLifetimesRefreshReleaseSchedule() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        let layer = Self.layer(fboNames: ["fx_a", "fx_b"])
        let pipeline = Self.pipeline(layer)

        pool.prepare(pipeline: pipeline, aliasIntervals: [
            Self.interval(pool, layer, "fx_a", 0, 1),
            Self.interval(pool, layer, "fx_b", 0, 3),
        ], pipelineIdentity: 1)
        pool.beginAliasFrame()
        let heap = try #require(try Self.texture(pool, layer, "fx_a").heap)

        // Same (size, firstPass, lastPass) sequence, but now fx_a is the long-lived one.
        pool.prepare(pipeline: pipeline, aliasIntervals: [
            Self.interval(pool, layer, "fx_b", 0, 1),
            Self.interval(pool, layer, "fx_a", 0, 3),
        ], pipelineIdentity: 1)
        pool.beginAliasFrame()
        let aAtPass0 = try Self.texture(pool, layer, "fx_a")
        let bAtPass0 = try Self.texture(pool, layer, "fx_b")
        #expect(aAtPass0.heap === heap, "an unchanged plan must keep reusing its heap")
        pool.endPass(passIndex: 0)
        pool.endPass(passIndex: 1)

        #expect(try Self.texture(pool, layer, "fx_a") === aAtPass0, "fx_a lives to pass 3 and must stay leased")
        #expect(try Self.texture(pool, layer, "fx_b") !== bAtPass0, "fx_b ended at pass 1 and must be released")
    }

    @Test("Re-preparing an unchanged plan without an identity keeps the heap and the schedule")
    func unchangedPlanKeepsHeapAndSchedule() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        let layer = Self.layer(fboNames: ["fx_a", "fx_b"])
        let pipeline = Self.pipeline(layer)
        let intervals = [
            Self.interval(pool, layer, "fx_a", 0, 1),
            Self.interval(pool, layer, "fx_b", 0, 3),
        ]

        // No pipeline identity, so `prepare` cannot early-out and the plan itself must recognise the repeat.
        pool.prepare(pipeline: pipeline, aliasIntervals: intervals)
        pool.beginAliasFrame()
        let heap = try #require(try Self.texture(pool, layer, "fx_a").heap)

        pool.prepare(pipeline: pipeline, aliasIntervals: intervals)
        pool.beginAliasFrame()
        let aAtPass0 = try Self.texture(pool, layer, "fx_a")
        let bAtPass0 = try Self.texture(pool, layer, "fx_b")
        #expect(pool.prepareRebuildCount == 2)
        #expect(aAtPass0.heap === heap)
        pool.endPass(passIndex: 0)
        pool.endPass(passIndex: 1)

        #expect(try Self.texture(pool, layer, "fx_a") !== aAtPass0)
        #expect(try Self.texture(pool, layer, "fx_b") === bAtPass0)
    }

    @Test("New key dimensions inside the same allocation bucket still get the alias heap")
    func sameBucketDimensionsStayOnAliasHeap() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = WPEMetalRenderTargetPool(device: device)
        let layer = Self.layer(fboNames: ["fx_a"])
        let pipeline = Self.pipeline(layer)
        func allocationSize(_ interval: WPEMetalRenderTargetPool.AliasInterval) -> Int {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: interval.key.pixelFormat,
                width: interval.key.width,
                height: interval.key.height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.heapTextureSizeAndAlign(descriptor: descriptor).size
        }
        let before = Self.interval(pool, layer, "fx_a", 0, 1)
        // Tile-rounded allocations make a neighbouring height share 64x64's bucket.
        let (resizedScene, after) = try #require([63, 62, 60, 56, 48].lazy
            .map { height -> (CGSize, WPEMetalRenderTargetPool.AliasInterval) in
                let scene = CGSize(width: 64, height: CGFloat(height))
                return (scene, Self.interval(pool, layer, "fx_a", 0, 1, sceneSize: scene))
            }
            .first { allocationSize($0.1) == allocationSize(before) })
        #expect(after.key != before.key)

        pool.prepare(pipeline: pipeline, aliasIntervals: [before], pipelineIdentity: 1)
        pool.beginAliasFrame()
        let heap = try #require(try Self.texture(pool, layer, "fx_a").heap)

        pool.prepare(pipeline: pipeline, aliasIntervals: [after], pipelineIdentity: 1)
        pool.beginAliasFrame()
        let resized = try Self.texture(pool, layer, "fx_a", sceneSize: resizedScene)

        #expect(resized.height == after.key.height)
        #expect(resized.heap === heap, "the resized key must be planned onto the alias heap, not a discrete slot")
    }
}
