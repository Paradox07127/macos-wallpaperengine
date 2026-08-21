#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Metal
import Testing
@testable import LiveWallpaper

/// Characterization + mutation guard for the split alias-interval scan: the
/// cached structural topology (`FBOAliasTopology`) plus per-frame size mapping
/// must reproduce the pre-split full scan EXACTLY (the reference replica lives
/// at the bottom of this file), and the cache's invalidation must demonstrably
/// carry the correctness — a deliberately stale topology must produce wrong
/// intervals.
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

    /// Same objectID throughout so the memo's own key never changes — only the
    /// path/geometry/scene inputs it validates against do.
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

/// One pipeline covering every alias-scan form: plain FBO write/read across
/// layers, layer composites, a layer-local FBO, a ping-pong secondary, a
/// same-named FBO in two layers with different footprints, a godrays-combine
/// discrete-source read, an undeclared scene-sized FBO target, and a
/// composelayer utility whose composite size is frame-size dependent.
private func makeAliasFormsPipeline(
    fxSize: CGSize = CGSize(width: 200, height: 100),
    dupSize: CGSize = CGSize(width: 64, height: 32),
    composeSize: CGSize = CGSize(width: 120, height: 80),
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
        geometry: aliasGeometry(size: composeSize),
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

// MARK: - Reference replica + normalization

private func normalizedAliasIntervals(
    _ intervals: [WPEMetalRenderTargetPool.AliasInterval]
) -> [String] {
    intervals.map {
        "\($0.key.name)#\($0.key.width)x\($0.key.height)#\($0.key.format)"
            + "#\($0.key.pixelFormat.rawValue)@\($0.firstPass)-\($0.lastPass)"
    }.sorted()
}

/// Replica of the pre-split full-scan algorithm (single-pass key resolution +
/// interval scan over the flattened pass order). The production path must stay
/// element-for-element equal to this for any pipeline and any sizes.
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
        for reference in executor.textureReferences(for: item.pass) {
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
