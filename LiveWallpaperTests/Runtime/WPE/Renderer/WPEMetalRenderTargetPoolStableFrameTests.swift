import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// W1: `prepare` must do its work once per set of INPUTS, not once per frame.
/// The two counters are read-only seams on the pool; `prepareRebuildCount`
/// covers the `declaredFBOs` rebuild, `aliasPlanDeviceQueryCount` counts the
/// `heapTextureSizeAndAlign` driver calls the alias planner issues.
@Suite("WPEMetalRenderTargetPool — stable-frame prepare early-out")
struct WPEMetalRenderTargetPoolStableFrameTests {
    private static let sceneSize = CGSize(width: 1920, height: 1080)
    private static let fboNames = ["fx_blur", "fx_bloom", "fx_mask"]

    // MARK: - Fixtures

    private static func layer(
        fboNames: [String] = fboNames,
        format: String = "rgba8888"
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "obj",
            objectName: "obj",
            imagePath: "materials/base.png",
            materialPath: nil,
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_obj_a",
            compositeB: "_rt_imageLayerComposite_obj_b",
            localFBOs: fboNames.map { WPERenderFBO(name: $0, scale: 1, format: format) },
            passes: []
        )
    }

    private static func pipeline(_ layer: WPERenderLayer) -> WPEPreparedRenderPipeline {
        WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(graphLayer: layer, passes: [])])
    }

    /// Real key derivation (`diagnosticKey`), so scene size / pixel scale / HDR
    /// reach the intervals exactly the way the executor makes them reach it.
    private static func intervals(
        pool: WPEMetalRenderTargetPool,
        layer: WPERenderLayer,
        sceneSize: CGSize
    ) -> [WPEMetalRenderTargetPool.AliasInterval] {
        let declared = Dictionary(uniqueKeysWithValues: layer.localFBOs.map { ($0.name, $0) })
        return layer.localFBOs.enumerated().map { index, fbo in
            WPEMetalRenderTargetPool.AliasInterval(
                key: pool.diagnosticKey(
                    for: .fbo(name: fbo.name),
                    layer: layer,
                    sceneSize: sceneSize,
                    declaredFBOs: declared
                ),
                firstPass: index,
                lastPass: index + 1
            )
        }
    }

    /// Runs `count` identical prepares and returns the pool, warm and stable.
    private static func warmPool(
        device: MTLDevice,
        layer: WPERenderLayer,
        prepares: Int = 8
    ) -> (pool: WPEMetalRenderTargetPool, intervals: [WPEMetalRenderTargetPool.AliasInterval]) {
        let pool = WPEMetalRenderTargetPool(device: device)
        let pipeline = pipeline(layer)
        let intervals = intervals(pool: pool, layer: layer, sceneSize: sceneSize)
        for _ in 0..<prepares {
            pool.prepare(pipeline: pipeline, aliasIntervals: intervals, pipelineIdentity: 1)
        }
        return (pool, intervals)
    }

    // MARK: - The early-out itself

    @Test("Repeated identical prepares build the plan and query the driver once")
    func stableFrameSkipsRebuildAndDriverQueries() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, intervals) = Self.warmPool(device: device, layer: layer, prepares: 30)

        #expect(pool.prepareRebuildCount == 1)
        #expect(pool.aliasPlanDeviceQueryCount == intervals.count)
    }

    @Test("declaredFBOs survives the skipped rebuilds")
    func declaredFBOsStayResolvableAcrossSkippedPrepares() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, _) = Self.warmPool(device: device, layer: layer)

        #expect(pool.prepareRebuildCount == 1)
        for name in Self.fboNames {
            #expect(pool.zeroFilledPlaceholderTexture(forDeclaredFBO: name) != nil)
        }
        #expect(pool.zeroFilledPlaceholderTexture(forDeclaredFBO: "never_declared") == nil)
    }

    @Test("Without a pipeline identity the caller gets the old every-frame rebuild")
    func absentIdentityNeverSkips() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let pool = WPEMetalRenderTargetPool(device: device)
        let pipeline = Self.pipeline(layer)
        let intervals = Self.intervals(pool: pool, layer: layer, sceneSize: Self.sceneSize)

        for _ in 0..<5 { pool.prepare(pipeline: pipeline, aliasIntervals: intervals) }

        #expect(pool.prepareRebuildCount == 5)
        #expect(pool.aliasPlanDeviceQueryCount == intervals.count * 5)
    }

    // MARK: - Every input change must re-trigger the work

    @Test("Scene size change re-plans")
    func sceneSizeChangeInvalidates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, _) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        let resized = Self.intervals(pool: pool, layer: layer, sceneSize: CGSize(width: 1280, height: 720))
        pool.prepare(pipeline: Self.pipeline(layer), aliasIntervals: resized, pipelineIdentity: 1)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > queriesWhenWarm)
    }

    @Test("Render pixel scale change re-plans")
    func pixelScaleChangeInvalidates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, _) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        pool.pixelScale = 0.5
        let scaled = Self.intervals(pool: pool, layer: layer, sceneSize: Self.sceneSize)
        pool.prepare(pipeline: Self.pipeline(layer), aliasIntervals: scaled, pipelineIdentity: 1)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > queriesWhenWarm)
    }

    @Test("HDR promotion change re-plans even when the interval keys are identical")
    func hdrChangeInvalidatesWithUnchangedKeys() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Already-float FBOs: `pixelFormat(forFBOFormat:promoteLDRToHDR:)` maps
        // them to `.rgba16Float` either way, so the keys do NOT move and only
        // the flag itself can catch the change.
        let layer = Self.layer(format: "rgba16f")
        let (pool, intervals) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        pool.promotesLDRFormatsToHDR = true
        let promoted = Self.intervals(pool: pool, layer: layer, sceneSize: Self.sceneSize)
        #expect(promoted == intervals, "fixture must keep the keys identical for this test to mean anything")

        pool.prepare(pipeline: Self.pipeline(layer), aliasIntervals: promoted, pipelineIdentity: 1)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > queriesWhenWarm)
    }

    @Test("Reload (releaseAll) re-plans")
    func releaseAllInvalidates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, intervals) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        pool.releaseAll()
        pool.prepare(pipeline: Self.pipeline(layer), aliasIntervals: intervals, pipelineIdentity: 1)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > queriesWhenWarm)
        // The rebuild must have actually repopulated declaredFBOs, not just the heap.
        #expect(pool.zeroFilledPlaceholderTexture(forDeclaredFBO: Self.fboNames[0]) != nil)
    }

    @Test("discardTextures re-plans")
    func discardTexturesInvalidates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, intervals) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        pool.discardTextures(named: [Self.fboNames[0]])
        pool.prepare(pipeline: Self.pipeline(layer), aliasIntervals: intervals, pipelineIdentity: 1)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > queriesWhenWarm)
    }

    @Test("A pipeline structure change re-plans through the identity alone")
    func pipelineIdentityChangeInvalidates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, intervals) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        // Same intervals, different declared FBOs: only the identity separates them.
        let rewired = Self.layer(fboNames: ["fx_other"])
        pool.prepare(pipeline: Self.pipeline(rewired), aliasIntervals: intervals, pipelineIdentity: 2)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > queriesWhenWarm)
        #expect(pool.zeroFilledPlaceholderTexture(forDeclaredFBO: "fx_other") != nil)
        #expect(pool.zeroFilledPlaceholderTexture(forDeclaredFBO: Self.fboNames[0]) == nil)
    }

    @Test("Adding an FBO to the pipeline re-plans")
    func addedFBOInvalidates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, _) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        let grown = Self.layer(fboNames: Self.fboNames + ["fx_added"])
        let grownIntervals = Self.intervals(pool: pool, layer: grown, sceneSize: Self.sceneSize)
        pool.prepare(pipeline: Self.pipeline(grown), aliasIntervals: grownIntervals, pipelineIdentity: 2)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount == queriesWhenWarm + grownIntervals.count)
    }

    @Test("A lifetime-only change re-plans")
    func aliasLifetimeChangeInvalidates() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let layer = Self.layer()
        let (pool, intervals) = Self.warmPool(device: device, layer: layer)
        let queriesWhenWarm = pool.aliasPlanDeviceQueryCount

        let shifted = intervals.map {
            WPEMetalRenderTargetPool.AliasInterval(
                key: $0.key,
                firstPass: $0.firstPass,
                lastPass: $0.lastPass + 4
            )
        }
        pool.prepare(pipeline: Self.pipeline(layer), aliasIntervals: shifted, pipelineIdentity: 1)

        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > queriesWhenWarm)
    }
}
