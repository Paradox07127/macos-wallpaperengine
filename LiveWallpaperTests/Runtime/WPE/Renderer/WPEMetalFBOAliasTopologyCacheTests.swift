#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Cached FBO alias topology plus per-frame sizes must match the pre-split scan.
@Suite("WPE Metal FBO alias topology cache")
struct WPEMetalFBOAliasTopologyCacheTests {

    @Test("Cached-topology path matches the reference full scan across target forms")
    func cachedPathMatchesReferenceAcrossForms() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let sceneSize = CGSize(width: 1024, height: 768)
        let pipeline = makeAliasFormsPipeline()

        let split = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: sceneSize)
        let reference = referenceFBOAliasIntervals(
            executor: executor, pipeline: pipeline, sceneSize: sceneSize
        )

        #expect(!split.isEmpty)
        #expect(normalizedAliasIntervals(split) == normalizedAliasIntervals(reference))

        // The form matrix must actually exercise every exclusion path — a
        // trivially empty/degenerate pipeline would make the equality vacuous.
        let entries = normalizedAliasIntervals(split)
        func hasKey(_ name: String, _ width: Int, _ height: Int) -> Bool {
            entries.contains { $0.hasPrefix("\(name)#\(width)x\(height)#") }
        }
        // Ping-pong secondary: fx's own-sized "fxBlur" key is excluded…
        #expect(!hasKey("fxBlur", 200, 100))
        // …while dup's same-named, differently-sized key stays eligible.
        #expect(hasKey("fxBlur", 64, 32))
        // Godrays-combine source: "_rt_A" is excluded outright.
        #expect(!entries.contains { $0.hasPrefix("_rt_A#") })
        // Undeclared FBO target falls back to a scene-sized key.
        #expect(hasKey("fxBlur2", 1024, 768))
        // Layer composites size to their layer footprints.
        #expect(hasKey("_rt_imageLayerComposite_fx_a", 200, 100))
        #expect(hasKey("_rt_imageLayerComposite_compose_a", 120, 80))
    }

    @Test("Geometry/scene-size change reuses the cached topology and follows the new sizes")
    func sizeChangeReusesTopologyAndFollowsSizes() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let first = executor.fboAliasIntervals(
            pipeline: makeAliasFormsPipeline(),
            sceneSize: CGSize(width: 1024, height: 768)
        )
        #expect(executor.fboAliasTopologyRebuildCount == 1)

        // Same structure, different layer geometry + scene size. The compose
        // utility layer flips subregion → fullscreen purely from these sizes.
        let resized = makeAliasFormsPipeline(
            fxSize: CGSize(width: 300, height: 150),
            composeSize: CGSize(width: 1000, height: 760)
        )
        let resizedScene = CGSize(width: 1000, height: 800)
        let second = executor.fboAliasIntervals(pipeline: resized, sceneSize: resizedScene)

        #expect(executor.fboAliasTopologyRebuildCount == 1, "size-only change must hit the cache")
        let reference = referenceFBOAliasIntervals(
            executor: executor, pipeline: resized, sceneSize: resizedScene
        )
        #expect(normalizedAliasIntervals(second) == normalizedAliasIntervals(reference))
        #expect(
            normalizedAliasIntervals(second) != normalizedAliasIntervals(first),
            "new sizes must flow through the cached topology"
        )
        // The flip driven purely by per-frame sizes: compose composite is now
        // scene-sized.
        #expect(normalizedAliasIntervals(second).contains {
            $0.hasPrefix("_rt_imageLayerComposite_compose_a#1000x800#")
        })
    }

    @Test("Structural change invalidates the cache and the result follows")
    func structuralChangeRebuildsAndFollows() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let base = makeAliasFormsPipeline()
        let sceneSize = CGSize(width: 1024, height: 768)
        _ = executor.fboAliasIntervals(pipeline: base, sceneSize: sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 1)

        // createLayer-style insertion (the one structural change a frame can make).
        let grown = makeAliasFormsPipeline(includeExtraLayer: true)
        let grownResult = executor.fboAliasIntervals(pipeline: grown, sceneSize: sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 2)
        #expect(normalizedAliasIntervals(grownResult) == normalizedAliasIntervals(
            referenceFBOAliasIntervals(executor: executor, pipeline: grown, sceneSize: sceneSize)
        ))

        // Removal (created layer destroyed) invalidates again.
        let shrunk = base
        let shrunkResult = executor.fboAliasIntervals(pipeline: shrunk, sceneSize: sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 3)
        #expect(normalizedAliasIntervals(shrunkResult) == normalizedAliasIntervals(
            referenceFBOAliasIntervals(executor: executor, pipeline: shrunk, sceneSize: sceneSize)
        ))
    }

    @Test("Signature matcher fires for structural mutations and ignores geometry")
    func signatureMatcherFiresOnStructuralMutations() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let base = makeAliasFormsPipeline()
        let topology = executor.computeFBOAliasTopology(pipeline: base)

        #expect(topology.matches(base))
        #expect(topology.matches(makeAliasFormsPipeline(fxSize: CGSize(width: 999, height: 1))),
                "geometry-only change must stay a cache hit")
        #expect(!topology.matches(makeAliasFormsPipeline(includeExtraLayer: true)))
        #expect(!topology.matches(WPEPreparedRenderPipeline(layers: Array(base.layers.dropLast()))))
        #expect(!topology.matches(makeAliasFormsPipeline(fxImagePath: "materials/other.png")))
        // Target rename with identical ids/counts — the per-pass (id, target)
        // signature catches it directly.
        #expect(!topology.matches(makeAliasFormsPipeline(discreteTargetName: "fxBlur3")))

        // Pass-count change within a layer.
        var layers = base.layers
        let extra = preparedAliasPass(aliasPass(id: "fx.extra", target: .scene))
        layers[1] = WPEPreparedRenderLayer(
            graphLayer: layers[1].graphLayer,
            puppetModel: layers[1].puppetModel,
            passes: layers[1].passes + [extra]
        )
        #expect(!topology.matches(WPEPreparedRenderPipeline(layers: layers)))
    }

    @Test("A stale topology produces wrong intervals — invalidation is load-bearing")
    func staleTopologyProducesWrongIntervals() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let sceneSize = CGSize(width: 1024, height: 768)
        let base = makeAliasFormsPipeline()
        let staleTopology = executor.computeFBOAliasTopology(pipeline: base)

        // Change a pass's texture-reference SET while keeping every (id, target)
        // — the one structural dimension the signature deliberately does not
        // re-check (invariant within a load; a reload clears the cache). This
        // proves the stale topology would corrupt the plan if that invariant
        // were ever broken: the moved read extends "fxBlur"'s lifetime and
        // shrinks the fx composite's, which a stale topology cannot see.
        let rewired = makeAliasFormsPipeline(fxFinalReadsBlur: true)
        #expect(staleTopology.matches(rewired))

        let stale = executor.fboAliasIntervals(
            topology: staleTopology, pipeline: rewired, sceneSize: sceneSize
        )
        let correct = referenceFBOAliasIntervals(
            executor: executor, pipeline: rewired, sceneSize: sceneSize
        )
        #expect(
            normalizedAliasIntervals(stale) != normalizedAliasIntervals(correct),
            "stale topology must be observably wrong, or the cache guard has no teeth"
        )
        // And the real (guarded) entry point stays correct on the same input:
        // the executor never held `staleTopology` in its cache, so this is a
        // fresh build.
        let guarded = executor.fboAliasIntervals(pipeline: rewired, sceneSize: sceneSize)
        #expect(normalizedAliasIntervals(guarded) == normalizedAliasIntervals(correct))
    }

    @Test("Scene-capture outputGeometry memo matches the pure function across input changes")
    func outputGeometryMemoMatchesPureFunction() {
        let memo = WPESceneCaptureOutputGeometryMemo()
        let path = "models/util/composelayer.json"
        let scenes = [CGSize(width: 1024, height: 768), CGSize(width: 100, height: 80)]
        let geometries = [
            aliasGeometry(size: CGSize(width: 120, height: 80)),
            aliasGeometry(size: CGSize(width: 1000, height: 760)),
            aliasGeometry(size: CGSize(width: 120, height: 80), angles: SIMD3<Double>(0.5, 0, 0)),
            aliasGeometry(size: CGSize(width: 120, height: 80), scale: SIMD3<Double>(-1, 1, 1))
        ]
        // Same objectID throughout: every input change must recompute, never
        // serve the previous entry.
        for scene in scenes {
            for geometry in geometries {
                #expect(
                    memo.outputGeometry(layer: memoLayer(path), geometry: geometry, sceneSize: scene)
                        == WPEMetalSceneCaptureUtilityModels.outputGeometry(
                            path: path, geometry: geometry, sceneSize: scene
                        )
                )
            }
        }
        // Returning to the first inputs after overwrites must also be fresh.
        #expect(
            memo.outputGeometry(layer: memoLayer(path), geometry: geometries[0], sceneSize: scenes[0])
                == WPEMetalSceneCaptureUtilityModels.outputGeometry(
                    path: path, geometry: geometries[0], sceneSize: scenes[0]
                )
        )
        // Path change under the same objectID is part of the compare too.
        #expect(
            memo.outputGeometry(
                layer: memoLayer("models/util/fullscreenlayer.json"),
                geometry: geometries[0],
                sceneSize: scenes[0]
            ) == .fullscreen
        )
    }

    /// Same objectID so the memo key is stable; only path/geometry/scene vary.
    private func memoLayer(_ path: String) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "obj",
            objectName: "obj",
            imagePath: path,
            materialPath: nil,
            geometry: .identity,
            compositeA: "_rt_imageLayerComposite_obj_a",
            compositeB: "_rt_imageLayerComposite_obj_b",
            localFBOs: [],
            passes: []
        )
    }
}

/// E3a: the topology carries a structural generation, and the per-frame
/// alias-interval / persistent-depth scans hang off it instead of re-running.
/// Every test here also asserts the VALUE is right, because a cache that
/// under-invalidates aliases two live FBOs onto the same memory.
@Suite("WPE Metal FBO alias structural generation")
struct WPEMetalFBOAliasStructuralGenerationTests {
    private static let sceneSize = CGSize(width: 1024, height: 768)

    private func executor() throws -> WPEMetalRenderExecutor {
        let device = try #require(MTLCreateSystemDefaultDevice())
        return try WPEMetalRenderExecutor(device: device)
    }

    private func metrics(
        _ executor: WPEMetalRenderExecutor
    ) throws -> WPEMetalRenderExecutor.FBOAliasTopology.Metrics {
        try #require(executor.cachedFBOAliasTopology).metrics
    }

    // MARK: - 1. Steady state

    @Test("Re-presenting the same pipeline value costs no walk and no rescan")
    func identicalPipelineValueSkipsEveryScan() throws {
        let executor = try executor()
        let pipeline = makeAliasFormsPipeline()

        let first = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: Self.sceneSize)
        let firstDepth = executor.computePersistentDepthTargetIDs(for: pipeline)
        let cold = try metrics(executor)
        #expect(cold == .init(structuralScans: 0, intervalRebuilds: 1, depthRebuilds: 1))

        for _ in 0..<8 {
            let intervals = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: Self.sceneSize)
            let depth = executor.computePersistentDepthTargetIDs(for: pipeline)
            #expect(normalizedAliasIntervals(intervals) == normalizedAliasIntervals(first))
            #expect(depth == firstDepth)
        }
        #expect(executor.fboAliasTopologyRebuildCount == 1)
        let steady = try metrics(executor)
        #expect(
            steady == .init(structuralScans: 0, intervalRebuilds: 1, depthRebuilds: 1),
            "a steady frame must not walk the graph at all"
        )
    }

    @Test("An animated frame rebuilds the pipeline value but not the topology or its results")
    func animationFrameKeepsGenerationAndMemos() throws {
        let executor = try executor()
        let animated = animatedUniformPipeline(makeAliasFormsPipeline())
        let camera = WPEMetalCameraUniforms.identity

        let (frame0, _) = animated.addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(time: 0, daytime: 0, brightness: 1, pointerPosition: .zero),
            camera: camera
        )
        let first = executor.fboAliasIntervals(pipeline: frame0, sceneSize: Self.sceneSize)
        _ = executor.computePersistentDepthTargetIDs(for: frame0)
        #expect(executor.fboAliasTopologyRebuildCount == 1)

        for step in 1...4 {
            let (frame, _) = animated.addingMetalRuntimeUniforms(
                WPEMetalRuntimeUniforms(
                    time: Double(step) * 0.25, daytime: 0, brightness: 1, pointerPosition: .zero
                ),
                camera: camera
            )
            // The fixture must actually produce a NEW value each frame, or this
            // test degenerates into the identical-value case above.
            let cached = try #require(executor.cachedFBOAliasTopology)
            #expect(!cached.holdsSameLayerStorage(as: frame))

            let intervals = executor.fboAliasIntervals(pipeline: frame, sceneSize: Self.sceneSize)
            _ = executor.computePersistentDepthTargetIDs(for: frame)
            #expect(normalizedAliasIntervals(intervals) == normalizedAliasIntervals(first))
        }

        #expect(executor.fboAliasTopologyRebuildCount == 1, "uniform animation is not a graph change")
        let final = try metrics(executor)
        #expect(final.intervalRebuilds == 1, "intervals must be reused across animated frames")
        #expect(final.depthRebuilds == 1, "the depth set is structural — one scan per graph")
        #expect(final.structuralScans == 4, "one revalidation walk per rebuilt pipeline value")
    }

    @Test("Alpha and colour animation never disturbs the interval memo")
    func tintOnlyChangeKeepsTheIntervalMemo() throws {
        let executor = try executor()
        let base = makeAliasFormsPipeline()
        _ = executor.fboAliasIntervals(pipeline: base, sceneSize: Self.sceneSize)

        let tinted = base.applyingLayerAlpha(["fx": 0.25]).applyingLayerColor(
            ["fx": SIMD3<Double>(0.1, 0.2, 0.3)]
        )
        _ = executor.fboAliasIntervals(pipeline: tinted, sceneSize: Self.sceneSize)

        #expect(executor.fboAliasTopologyRebuildCount == 1)
        let tintedMetrics = try metrics(executor)
        #expect(tintedMetrics.intervalRebuilds == 1)
    }

    // MARK: - 2/3/4/5. Invalidation

    @Test("Created-layer insertion and removal both move the generation")
    func createdLayerInsertAndRemoveRebuild() throws {
        let executor = try executor()
        let base = makeAliasFormsPipeline()
        _ = executor.fboAliasIntervals(pipeline: base, sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 1)

        let grown = makeAliasFormsPipeline(includeExtraLayer: true)
        let grownIntervals = executor.fboAliasIntervals(pipeline: grown, sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 2)
        let grownMetrics = try metrics(executor)
        #expect(grownMetrics.intervalRebuilds == 2)
        #expect(normalizedAliasIntervals(grownIntervals) == normalizedAliasIntervals(
            referenceFBOAliasIntervals(executor: executor, pipeline: grown, sceneSize: Self.sceneSize)
        ))

        let shrunkIntervals = executor.fboAliasIntervals(pipeline: base, sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 3)
        #expect(normalizedAliasIntervals(shrunkIntervals) == normalizedAliasIntervals(
            referenceFBOAliasIntervals(executor: executor, pipeline: base, sceneSize: Self.sceneSize)
        ))
    }

    @Test("A reload to a different graph rebuilds even after releaseTransientResources")
    func reloadRebuilds() throws {
        let executor = try executor()
        _ = executor.fboAliasIntervals(pipeline: makeAliasFormsPipeline(), sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 1)

        // Structurally different scene, no explicit release: the signature alone
        // must catch it.
        let other = makeAliasFormsPipeline(fxImagePath: "materials/other.png")
        _ = executor.fboAliasIntervals(pipeline: other, sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 2)

        // And the reload path itself drops the retained layers + every memo.
        executor.releaseTransientResources()
        #expect(executor.cachedFBOAliasTopology == nil)
        _ = executor.fboAliasIntervals(pipeline: other, sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 3)
    }

    @Test("Same layers, one renamed pass target — the easiest miss — rebuilds")
    func renamedPassTargetRebuilds() throws {
        let executor = try executor()
        let base = makeAliasFormsPipeline()
        let first = executor.fboAliasIntervals(pipeline: base, sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 1)

        let renamed = makeAliasFormsPipeline(discreteTargetName: "fxBlur3")
        #expect(renamed.layers.count == base.layers.count)
        let intervals = executor.fboAliasIntervals(pipeline: renamed, sceneSize: Self.sceneSize)
        #expect(executor.fboAliasTopologyRebuildCount == 2)
        #expect(normalizedAliasIntervals(intervals) != normalizedAliasIntervals(first))
        #expect(normalizedAliasIntervals(intervals) == normalizedAliasIntervals(
            referenceFBOAliasIntervals(executor: executor, pipeline: renamed, sceneSize: Self.sceneSize)
        ))
    }

    @Test("Scene size, pixel scale and HDR promotion each re-derive the intervals")
    func perFrameKeyInputsInvalidateTheMemo() throws {
        let executor = try executor()
        let pipeline = makeAliasFormsPipeline()
        let first = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: Self.sceneSize)

        let resized = executor.fboAliasIntervals(
            pipeline: pipeline, sceneSize: CGSize(width: 800, height: 600)
        )
        #expect(executor.fboAliasTopologyRebuildCount == 1, "size is not structure")
        #expect(normalizedAliasIntervals(resized) != normalizedAliasIntervals(first))

        executor.targetPool.pixelScale = 0.5
        let scaled = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: Self.sceneSize)
        #expect(normalizedAliasIntervals(scaled) != normalizedAliasIntervals(first))
        #expect(normalizedAliasIntervals(scaled) == normalizedAliasIntervals(
            referenceFBOAliasIntervals(executor: executor, pipeline: pipeline, sceneSize: Self.sceneSize)
        ))

        executor.targetPool.pixelScale = 1
        executor.targetPool.promotesLDRFormatsToHDR = true
        let hdr = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: Self.sceneSize)
        #expect(normalizedAliasIntervals(hdr) != normalizedAliasIntervals(first))
        #expect(normalizedAliasIntervals(hdr) == normalizedAliasIntervals(
            referenceFBOAliasIntervals(executor: executor, pipeline: pipeline, sceneSize: Self.sceneSize)
        ))
        #expect(executor.fboAliasTopologyRebuildCount == 1)
    }

    /// The memo's teeth: a layer whose geometry drives its pooled-target size
    /// must invalidate it even though the GRAPH is untouched. Serving the memo
    /// here would hand the pool intervals keyed to the old pixel size.
    @Test("Layer geometry that feeds a pool key invalidates the interval memo")
    func sizingGeometryChangeInvalidatesTheMemo() throws {
        let executor = try executor()
        let base = makeAliasFormsPipeline()
        let first = executor.fboAliasIntervals(pipeline: base, sceneSize: Self.sceneSize)

        let resizedLayer = makeAliasFormsPipeline(fxSize: CGSize(width: 320, height: 160))
        let intervals = executor.fboAliasIntervals(pipeline: resizedLayer, sceneSize: Self.sceneSize)
        let reference = referenceFBOAliasIntervals(
            executor: executor, pipeline: resizedLayer, sceneSize: Self.sceneSize
        )
        #expect(executor.fboAliasTopologyRebuildCount == 1, "geometry is not structure")
        #expect(normalizedAliasIntervals(intervals) == normalizedAliasIntervals(reference))
        #expect(
            normalizedAliasIntervals(reference) != normalizedAliasIntervals(first),
            "control: the stale memo would have been observably wrong"
        )

        // `scale` reaches the key only through the compose utility layer's
        // fullscreen/subregion classification — 120x80 scaled 9x/10x covers the
        // canvas, so its composite flips from local to scene-sized.
        let scaled = makeAliasFormsPipeline(
            fxSize: CGSize(width: 320, height: 160),
            composeScale: SIMD3<Double>(9, 10, 1)
        )
        let scaledIntervals = executor.fboAliasIntervals(pipeline: scaled, sceneSize: Self.sceneSize)
        let scaledReference = referenceFBOAliasIntervals(
            executor: executor, pipeline: scaled, sceneSize: Self.sceneSize
        )
        #expect(normalizedAliasIntervals(scaledIntervals) == normalizedAliasIntervals(scaledReference))
        #expect(normalizedAliasIntervals(scaledIntervals).contains {
            $0.hasPrefix("_rt_imageLayerComposite_compose_a#1024x768#")
        }, "control: scale must have moved this key, or the assertion above is vacuous")
        #expect(executor.fboAliasTopologyRebuildCount == 1)
    }

    // MARK: - 6. The pool early-out downstream

    @Test("The pool still skips its whole prepare on a steady frame")
    func poolStableFrameEarlyOutSurvives() throws {
        let executor = try executor()
        let pipeline = makeAliasFormsPipeline()
        let pool = executor.targetPool

        for _ in 0..<12 {
            let intervals = executor.fboAliasIntervals(pipeline: pipeline, sceneSize: Self.sceneSize)
            pool.prepare(
                pipeline: pipeline,
                aliasIntervals: intervals,
                pipelineIdentity: executor.fboAliasTopologyRebuildCount
            )
        }
        #expect(pool.prepareRebuildCount == 1)
        let steadyQueries = pool.aliasPlanDeviceQueryCount

        // A created-layer insertion must push a NEW identity through, or the
        // pool would keep a plan built for the old graph.
        let grown = makeAliasFormsPipeline(includeExtraLayer: true)
        let grownIntervals = executor.fboAliasIntervals(pipeline: grown, sceneSize: Self.sceneSize)
        pool.prepare(
            pipeline: grown,
            aliasIntervals: grownIntervals,
            pipelineIdentity: executor.fboAliasTopologyRebuildCount
        )
        #expect(pool.prepareRebuildCount == 2)
        #expect(pool.aliasPlanDeviceQueryCount > steadyQueries)
    }
}

// MARK: - Pipeline fixtures

private func aliasGeometry(
    size: CGSize,
    scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
    angles: SIMD3<Double> = SIMD3<Double>(0, 0, 0)
) -> WPERenderLayerGeometry {
    WPERenderLayerGeometry(
        origin: SIMD3<Double>(0, 0, 0),
        scale: scale,
        angles: angles,
        alignment: .center,
        size: size,
        alpha: 1,
        color: SIMD3<Double>(1, 1, 1),
        brightness: 1
    )
}

private func aliasPass(
    id: String,
    shader: String = "solidcolor",
    source: WPETextureReference = .previous,
    target: WPERenderTarget,
    textures: [Int: WPETextureReference] = [:]
) -> WPERenderPass {
    WPERenderPass(
        id: id,
        phase: .material,
        shader: shader,
        source: source,
        target: target,
        textures: textures,
        binds: [:],
        constants: [:],
        combos: [:],
        blending: "normal",
        cullMode: "nocull",
        depthTest: "disabled",
        depthWrite: "disabled"
    )
}

private func preparedAliasPass(_ pass: WPERenderPass) -> WPEPreparedRenderPass {
    WPEPreparedRenderPass(
        pass: pass,
        shader: nil,
        textureBindings: [:],
        comboValues: [:],
        uniformValues: [:]
    )
}

private func aliasLayer(
    objectID: String,
    imagePath: String = "materials/base.png",
    geometry: WPERenderLayerGeometry = .identity,
    localFBOs: [WPERenderFBO] = [],
    passes: [WPERenderPass]
) -> WPEPreparedRenderLayer {
    let graph = WPERenderLayer(
        objectID: objectID,
        objectName: objectID,
        imagePath: imagePath,
        materialPath: nil,
        geometry: geometry,
        compositeA: "_rt_imageLayerComposite_\(objectID)_a",
        compositeB: "_rt_imageLayerComposite_\(objectID)_b",
        localFBOs: localFBOs,
        passes: passes
    )
    return WPEPreparedRenderLayer(graphLayer: graph, passes: passes.map(preparedAliasPass))
}

/// Fixture covering every alias-scan form the cache must reproduce.
private func makeAliasFormsPipeline(
    fxSize: CGSize = CGSize(width: 200, height: 100),
    dupSize: CGSize = CGSize(width: 64, height: 32),
    composeSize: CGSize = CGSize(width: 120, height: 80),
    composeScale: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
    includeExtraLayer: Bool = false,
    fxImagePath: String = "materials/base.png",
    discreteTargetName: String = "fxBlur2",
    fxFinalReadsBlur: Bool = false
) -> WPEPreparedRenderPipeline {
    var layers: [WPEPreparedRenderLayer] = []
    // dup FIRST so its writes precede fx's — its "fxBlur" write must not be a
    // ping-pong secondary (nothing wrote that target yet).
    layers.append(aliasLayer(
        objectID: "dup",
        geometry: aliasGeometry(size: dupSize),
        localFBOs: [WPERenderFBO(name: "fxBlur", scale: 1, format: "rgba8888")],
        passes: [
            aliasPass(id: "dup.0", target: .fbo(name: "fxBlur")),
            aliasPass(
                id: "dup.1",
                source: .fbo("fxBlur"),
                target: .scene,
                textures: [0: .fbo("fxBlur")]
            )
        ]
    ))
    layers.append(aliasLayer(objectID: "bg", passes: [
        aliasPass(id: "bg.0", target: .fbo(name: "_rt_A")),
        aliasPass(
            id: "bg.1",
            source: .fbo("_rt_A"),
            target: .scene,
            textures: [0: .fbo("_rt_A")]
        )
    ]))
    let fxComposite = "_rt_imageLayerComposite_fx_a"
    layers.append(aliasLayer(
        objectID: "fx",
        imagePath: fxImagePath,
        geometry: aliasGeometry(size: fxSize),
        localFBOs: [WPERenderFBO(name: "fxBlur", scale: 1, format: "rgba8888")],
        passes: [
            aliasPass(id: "fx.0", target: .layerComposite(name: fxComposite)),
            aliasPass(
                id: "fx.1",
                source: .fbo(fxComposite),
                target: .fbo(name: "fxBlur"),
                textures: [0: .fbo(fxComposite)]
            ),
            // Ping-pong: reads its own already-written target.
            aliasPass(
                id: "fx.2",
                source: .fbo("fxBlur"),
                target: .fbo(name: "fxBlur"),
                textures: [0: .fbo("fxBlur")]
            ),
            // Godrays combine: source FBO must stay discrete; target is an
            // UNDECLARED FBO (scene-sized fallback spec).
            aliasPass(
                id: "fx.3",
                shader: "effects/godrays_combine",
                source: .fbo("_rt_A"),
                target: .fbo(name: discreteTargetName),
                textures: [0: .fbo("_rt_A")]
            ),
            aliasPass(
                id: "fx.4",
                source: .fbo(fxFinalReadsBlur ? "fxBlur" : fxComposite),
                target: .scene,
                textures: [0: .fbo(fxFinalReadsBlur ? "fxBlur" : fxComposite)]
            )
        ]
    ))
    layers.append(aliasLayer(
        objectID: "compose",
        imagePath: "models/util/composelayer.json",
        geometry: aliasGeometry(size: composeSize, scale: composeScale),
        passes: [
            aliasPass(
                id: "compose.0",
                source: .fbo("_rt_FullFrameBuffer"),
                target: .layerComposite(name: "_rt_imageLayerComposite_compose_a"),
                textures: [0: .fbo("_rt_FullFrameBuffer")]
            ),
            aliasPass(
                id: "compose.1",
                source: .fbo("_rt_imageLayerComposite_compose_a"),
                target: .scene,
                textures: [0: .fbo("_rt_imageLayerComposite_compose_a")]
            )
        ]
    ))
    if includeExtraLayer {
        layers.append(aliasLayer(objectID: "created_1", passes: [
            aliasPass(id: "created_1.0", target: .scene)
        ]))
    }
    return WPEPreparedRenderPipeline(layers: layers)
}

/// Gives the first layer an animated constant so `addingMetalRuntimeUniforms`
/// takes its rebuild path and hands back a FRESH layers array every frame —
/// the case the structural generation must see through.
private func animatedUniformPipeline(
    _ pipeline: WPEPreparedRenderPipeline
) -> WPEPreparedRenderPipeline {
    let animated = WPESceneShaderConstantValue.animated(WPESceneAnimatedValue(
        animation: WPESceneNumericAnimation(
            tracks: [[.init(frame: 0, value: 0), .init(frame: 30, value: 1)]],
            fps: 30,
            length: 30,
            mode: "loop",
            wrapLoop: true
        ),
        scalarFallback: 1,
        vectorFallback: nil
    ))
    var layers = pipeline.layers
    let head = layers[0]
    layers[0] = WPEPreparedRenderLayer(
        graphLayer: head.graphLayer,
        puppetModel: head.puppetModel,
        passes: head.passes.map { pass in
            WPEPreparedRenderPass(
                pass: pass.pass,
                shader: pass.shader,
                textureBindings: pass.textureBindings,
                comboValues: pass.comboValues,
                uniformValues: ["g_Fade": animated]
            )
        }
    )
    return WPEPreparedRenderPipeline(layers: layers)
}

// MARK: - Reference replica + normalization

private func normalizedAliasIntervals(
    _ intervals: [WPEMetalRenderTargetPool.AliasInterval]
) -> [String] {
    intervals.map {
        "\($0.key.name)#\($0.key.width)x\($0.key.height)#\($0.key.format)"
            + "#\($0.key.pixelFormat.rawValue)@\($0.firstPass)-\($0.lastPass)"
    }.sorted()
}

/// Pre-split full-scan replica. Production intervals must match this exactly.
private func referenceFBOAliasIntervals(
    executor: WPEMetalRenderExecutor,
    pipeline: WPEPreparedRenderPipeline,
    sceneSize: CGSize
) -> [WPEMetalRenderTargetPool.AliasInterval] {
    var declaredFBOs: [String: WPERenderFBO] = [:]
    for layer in pipeline.layers {
        for fbo in layer.graphLayer.localFBOs {
            declaredFBOs[fbo.name] = fbo
        }
    }

    var flattened: [(pass: WPEPreparedRenderPass, key: WPEMetalRenderTargetKey?)] = []
    var keysByName: [String: Set<WPEMetalRenderTargetKey>] = [:]
    for layer in pipeline.layers {
        for pass in layer.passes {
            let key: WPEMetalRenderTargetKey?
            switch pass.pass.target {
            case .scene:
                key = nil
            case .fbo, .layerComposite:
                key = executor.targetPool.diagnosticKey(
                    for: pass.pass.target,
                    layer: layer.graphLayer,
                    sceneSize: sceneSize,
                    declaredFBOs: declaredFBOs
                )
            }
            flattened.append((pass, key))
            if let key {
                keysByName[key.name, default: []].insert(key)
            }
        }
    }

    var firstPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
    var lastPassByKey: [WPEMetalRenderTargetKey: Int] = [:]
    var secondaryKeys: Set<WPEMetalRenderTargetKey> = []
    var nonAliasKeys: Set<WPEMetalRenderTargetKey> = []
    var writtenTargets: Set<WPEMetalTargetID> = []

    func touch(_ key: WPEMetalRenderTargetKey, _ index: Int) {
        if firstPassByKey[key] == nil { firstPassByKey[key] = index }
        lastPassByKey[key] = max(lastPassByKey[key] ?? index, index)
    }

    for (index, item) in flattened.enumerated() {
        let targetID = WPEMetalTargetID(target: item.pass.pass.target)
        if let targetKey = item.key {
            touch(targetKey, index)
            if writtenTargets.contains(targetID),
               executor.passReadsCurrentTarget(item.pass, targetID: targetID) {
                secondaryKeys.insert(targetKey)
            }
        }
        for reference in item.pass.textureReferences {
            switch reference {
            case .fbo(let name):
                for namedKey in keysByName[name] ?? [] { touch(namedKey, index) }
                if WPEMetalRenderExecutor.requiresDiscreteDestinationForSourceAliasing(item.pass) {
                    for namedKey in keysByName[name] ?? [] { nonAliasKeys.insert(namedKey) }
                }
            case .previous:
                if let targetKey = item.key { touch(targetKey, index) }
            case .image, .asset:
                break
            }
        }
        writtenTargets.insert(targetID)
    }

    return firstPassByKey.compactMap { key, first in
        guard !secondaryKeys.contains(key),
              !nonAliasKeys.contains(key),
              let last = lastPassByKey[key] else { return nil }
        return WPEMetalRenderTargetPool.AliasInterval(key: key, firstPass: first, lastPass: last)
    }
}
#endif
