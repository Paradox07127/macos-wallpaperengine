import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import simd
import Testing
@testable import LiveWallpaper

@Suite("WPE Metal object uniforms")
struct WPEMetalObjectUniformsTests {

    @Test("Identity geometry produces identity model and normal matrices")
    func identityGeometryProducesIdentity() {
        let values = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        #expect(values["g_ModelMatrix"]?.vectorValue == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(values["g_ModelMatrixInverse"]?.vectorValue == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(values["g_LayerModelMatrix"]?.vectorValue == values["g_ModelMatrix"]?.vectorValue)
        #expect(values["g_NormalModelMatrix"]?.vectorValue == [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    @Test("Translation lands in column-major column 3")
    func translationIsColumnMajor() {
        let m = WPEMetalObjectUniforms.modelMatrix(
            origin: SIMD3<Double>(5, 6, 7),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        let flat = WPEMetalObjectUniforms.flattenedColumnMajor(m)
        #expect(Array(flat[12..<16]) == [5, 6, 7, 1])
    }

    @Test("Non-uniform scale yields reciprocal normal-matrix diagonal")
    func nonUniformScaleNormalMatrix() throws {
        let values = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(2, 4, 1),
            angles: SIMD3<Double>(0, 0, 0)
        )
        let model = try #require(values["g_ModelMatrix"]?.vectorValue)
        #expect(model[0] == 2 && model[5] == 4 && model[10] == 1)

        let normal = try #require(values["g_NormalModelMatrix"]?.vectorValue)
        #expect(abs(normal[0] - 0.5) < 1e-9)
        #expect(abs(normal[4] - 0.25) < 1e-9)
        #expect(abs(normal[8] - 1.0) < 1e-9)
    }

    @Test("Degenerate (zero) scale falls back to identity normal matrix without NaN")
    func zeroScaleFallsBackToIdentityNormal() throws {
        let values = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(0, 0, 0),
            angles: SIMD3<Double>(0, 0, 0)
        )
        let normal = try #require(values["g_NormalModelMatrix"]?.vectorValue)
        #expect(normal == [1, 0, 0, 0, 1, 0, 0, 0, 1])
        #expect(normal.allSatisfy { $0.isFinite })
        let modelInverse = try #require(values["g_ModelMatrixInverse"]?.vectorValue)
        #expect(modelInverse == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(modelInverse.allSatisfy { $0.isFinite })
    }

    @Test("MVP counterparts use VP times model and invert the product")
    func modelViewProjectionCounterpartsAreStrictMath() throws {
        let object = WPEMetalObjectUniforms.uniformValues(
            origin: SIMD3<Double>(5, 6, 7),
            scale: SIMD3<Double>(2, 3, 4),
            angles: .zero
        )
        let model = try #require(object["g_ModelMatrix"])
        let modelInverseValue = try #require(object["g_ModelMatrixInverse"])
        let viewProjection = WPESceneShaderConstantValue.vector([
            10, 0, 0, 0,
            0, 20, 0, 0,
            0, 0, 30, 0,
            0, 0, 0, 1
        ])
        let mvpValue = try #require(WPEMetalObjectUniforms.cameraComposedValue(
            named: "g_ModelViewProjectionMatrix",
            modelValue: model,
            viewProjectionValue: viewProjection
        ))
        let inverseValue = try #require(WPEMetalObjectUniforms.cameraComposedValue(
            named: "g_ModelViewProjectionMatrixInverse",
            modelValue: model,
            viewProjectionValue: viewProjection
        ))
        let mvpValues = try #require(mvpValue.vectorValue)
        let inverseValues = try #require(inverseValue.vectorValue)
        let modelValues = try #require(model.vectorValue)
        let modelInverseValues = try #require(modelInverseValue.vectorValue)
        let modelMatrix = try #require(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: modelValues))
        let modelInverse = try #require(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: modelInverseValues))
        let mvp = try #require(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: mvpValues))
        let inverse = try #require(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: inverseValues))

        let local = SIMD4<Double>(1, 1, 1, 1)
        let world = modelMatrix * local
        let modelRecovered = modelInverse * world
        #expect(abs(modelRecovered.x - 1) < 1e-9)
        #expect(abs(modelRecovered.y - 1) < 1e-9)
        #expect(abs(modelRecovered.z - 1) < 1e-9)
        #expect(abs(modelRecovered.w - 1) < 1e-9)
        let projected = mvp * local
        #expect(projected == SIMD4<Double>(70, 180, 330, 1))
        let recovered = inverse * projected
        #expect(abs(recovered.x - 1) < 1e-9)
        #expect(abs(recovered.y - 1) < 1e-9)
        #expect(abs(recovered.z - 1) < 1e-9)
        #expect(abs(recovered.w - 1) < 1e-9)
    }

    @Test("A singular MVP inverse falls back to finite identity")
    func singularModelViewProjectionInverseFallsBackToIdentity() throws {
        let object = WPEMetalObjectUniforms.uniformValues(
            origin: .zero,
            scale: .zero,
            angles: .zero
        )
        let model = try #require(object["g_ModelMatrix"])
        let inverse = try #require(WPEMetalObjectUniforms.cameraComposedValue(
            named: "g_ModelViewProjectionMatrixInverse",
            modelValue: model,
            viewProjectionValue: .vector([
                1, 0, 0, 0,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1
            ])
        ))
        let value = try #require(inverse.vectorValue)
        #expect(value == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        #expect(value.allSatisfy { $0.isFinite })
    }

    @Test("90° Z rotation maps +X to +Y (column-major sign convention)")
    func zRotationSignConvention() {
        let m = WPEMetalObjectUniforms.modelMatrix(
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, .pi / 2)
        )
        let x = m * SIMD4<Double>(1, 0, 0, 1)
        #expect(abs(x.x) < 1e-9)
        #expect(abs(x.y - 1) < 1e-9)
    }


}

/// `movingOneLayerRecomputesOnlyThatLayer` is the control group for
/// `staticSceneRecomputesNothingOnASecondFrame`: it proves `computeCount` still
/// moves, so a zero delta is a cache hit and not a dead counter.
@Suite("WPE object uniform cache")
struct WPEObjectUniformCacheTests {

    // MARK: - Fixtures

    private static func geometry(
        origin: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        scale: SIMD3<Double> = SIMD3<Double>(1, 1, 1),
        angles: SIMD3<Double> = SIMD3<Double>(0, 0, 0),
        alphaAnimation: WPESceneAnimatedValue? = nil
    ) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin,
            scale: scale,
            angles: angles,
            alignment: .center,
            size: CGSize(width: 10, height: 10),
            alpha: 1,
            alphaAnimation: alphaAnimation,
            color: SIMD3<Double>(1, 1, 1),
            colorAnimation: nil,
            brightness: 1
        )
    }

    private static func layer(
        id: String,
        geometry: WPERenderLayerGeometry,
        passCount: Int = 1,
        solidSeed: [Double]? = nil
    ) -> WPEPreparedRenderLayer {
        let constants: [String: WPESceneShaderConstantValue] =
            solidSeed.map { ["g_Color": .vector($0)] } ?? [:]
        let passes = (0..<passCount).map { index in
            WPERenderPass(
                id: "\(id).\(index)",
                phase: .material,
                shader: WPEBuiltinShaderKind.solidLayer.rawValue,
                source: .image("models/solid.json"),
                target: .scene,
                textures: [:],
                binds: [:],
                constants: constants,
                combos: [:],
                blending: "normal",
                cullMode: "nocull",
                depthTest: "disabled",
                depthWrite: "disabled"
            )
        }
        return WPEPreparedRenderLayer(
            graphLayer: WPERenderLayer(
                objectID: id,
                objectName: id,
                imagePath: "models/solid.json",
                materialPath: nil,
                geometry: geometry,
                compositeA: "\(id).a",
                compositeB: "\(id).b",
                localFBOs: [],
                passes: passes
            ),
            passes: passes.map { pass in
                WPEPreparedRenderPass(
                    pass: pass,
                    shader: nil,
                    textureBindings: [:],
                    comboValues: [:],
                    uniformValues: constants
                )
            }
        )
    }

    private static func frame(
        _ layers: [WPEPreparedRenderLayer],
        cache: WPEObjectUniformCache?,
        time: Double = 0
    ) -> (pipeline: WPEPreparedRenderPipeline, frameUniforms: WPEFrameUniformContext) {
        WPEPreparedRenderPipeline(layers: layers).addingMetalRuntimeUniforms(
            WPEMetalRuntimeUniforms(
                time: time,
                daytime: 0,
                brightness: 1,
                pointerPosition: SIMD2<Double>(0.5, 0.5)
            ),
            camera: .identity,
            objectUniformCache: cache
        )
    }

    private static func expectedValues(
        _ geometry: WPERenderLayerGeometry
    ) -> [String: WPESceneShaderConstantValue] {
        WPEMetalObjectUniforms.uniformValues(
            origin: geometry.origin, scale: geometry.scale, angles: geometry.angles
        )
    }

    @Test("Inherited authored quad retains the Windows nonuniform-parent MVP and rejects stale incomplete ancestry")
    func authoredQuadHierarchyMatchesCapturedShear() throws {
        let local = WPERenderLayerGeometry(origin: SIMD3(16, -12, 0), scale: SIMD3(1.2, 0.8, 1), angles: SIMD3(0, 0, 0.17),
                                           alignment: .center, size: CGSize(width: 192, height: 192), alpha: 1,
                                           color: SIMD3(repeating: 1), brightness: 1)
        let template = Self.layer(id: "quad", geometry: local)
        let program = WPEShaderProgram(name: "quad", vertexSource: "", fragmentSource: "", isBuiltin: false)
        let passes = template.passes.map { pass in
            WPEPreparedRenderPass(pass: pass.pass, shader: program, textureBindings: [:], comboValues: [:], uniformValues: [:])
        }
        let graph = WPERenderLayer(objectID: "quad", objectName: "quad", imagePath: "models/util/solidlayer.json", materialPath: nil,
                                   parentObjectID: "parent", geometry: local, localGeometry: local, compositeA: "a", compositeB: "b",
                                   localFBOs: [], passes: passes.map(\.pass))
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: passes)])
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 384, height: 192, auto: false),
                                            sceneCamera: .defaultCamera, perspectiveOverrideFOVDegrees: 30)
        let host = WPERenderObjectTransform(origin: SIMD3(192, 96, 0), scale: SIMD3(1.1, 0.9, 1), angles: SIMD3(0, 0, 0.09))
        let resolved = pipeline.resolvingSceneModelMatrices(origins: [:], scales: [:], angles: [:],
                                                            parentByID: ["quad": "parent"], hostTransforms: ["parent": host], camera: camera)
        let runtime = WPEMetalRuntimeUniforms(time: 0, daytime: 0.5, brightness: 1, pointerPosition: SIMD2(repeating: 0.5))
        let cache = WPEObjectUniformCache()
        let frame = resolved.addingMetalRuntimeUniforms(runtime, camera: camera, objectUniformCache: cache)
        #expect(frame.frameUniforms.affineModelMatrixPassIDs == ["quad.0"])
        let mvp = try #require(frame.frameUniforms.value(named: "g_ModelViewProjectionMatrix", passID: "quad.0")?.vectorValue)
        let expected = [0.0066629387, 0.0031136139, 0, 0, -0.0011044668, 0.0072225812, 0, 0, 0, 0, 0.00025, 0, 0.0963513851, -0.0955668688, 0.5, 1]
        for (actual, oracle) in zip(mvp, expected) {
            #expect(abs(actual - oracle) < 0.000001)
        }
        _ = resolved.addingMetalRuntimeUniforms(runtime, camera: camera, objectUniformCache: cache)
        #expect(cache.computeCount == 1)
        for (parents, hosts) in [(["quad": "parent"], [String: WPERenderObjectTransform]()),
                                 (["quad": "parent", "parent": "quad"], ["parent": host])] {
            let invalid = resolved.resolvingSceneModelMatrices(origins: [:], scales: [:], angles: [:],
                                                               parentByID: parents, hostTransforms: hosts, camera: camera)
            #expect(invalid.layers[0].modelMatrixOverride == nil)
            #expect(invalid.addingMetalRuntimeUniforms(runtime, camera: camera).frameUniforms.affineModelMatrixPassIDs.isEmpty)
        }
    }

    @Test("Model hierarchy preserves non-commuting rotation and affine shear across cached frame uniforms")
    func modelHierarchyRetainsAffineTransform() throws {
        let local = Self.geometry(origin: SIMD3(1, 0, 0), angles: SIMD3(0, 0, Double.pi / 4))
        let template = Self.layer(id: "model", geometry: local)
        let graph = WPERenderLayer(
            objectID: "model", objectName: "model", imagePath: "models/body.mdl", materialPath: nil,
            puppetPath: "models/body.mdl", parentObjectID: "parent", geometry: local, localGeometry: local,
            compositeA: "a", compositeB: "b", localFBOs: [], passes: template.graphLayer.passes
        )
        let pipeline = WPEPreparedRenderPipeline(layers: [.init(graphLayer: graph, passes: template.passes)])
        let host = WPERenderObjectTransform(origin: SIMD3(3, 4, 5), scale: SIMD3(2, 3, 4), angles: SIMD3(0, Double.pi / 2, 0))
        let resolved = pipeline.resolvingSceneModelMatrices(origins: [:], scales: [:], angles: [:],
                                                            parentByID: ["model": "parent"], hostTransforms: ["parent": host])
        let matrix = try #require(resolved.layers[0].modelMatrixOverride.flatMap(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor:)))
        let world = matrix * SIMD4<Double>(1, 0, 0, 1)
        #expect(abs(world.x - 3) < 1e-9)
        #expect(abs(world.y - (4 + 3 / sqrt(2))) < 1e-9)
        #expect(abs(world.z - (3 - 2 / sqrt(2))) < 1e-9)
        // A TRS rebuilt from Euler sums/component scale loses this shear.
        #expect(abs(simd_dot(matrix.columns.0, matrix.columns.1) - 2.5) < 1e-9)
        let cache = WPEObjectUniformCache()
        let first = Self.frame(resolved.layers, cache: cache)
        #expect(first.frameUniforms.objectUniformValuesByPassID["model.0"]?["g_ModelMatrix"]?.vectorValue == resolved.layers[0].modelMatrixOverride)
        _ = Self.frame(resolved.layers, cache: cache)
        #expect(cache.computeCount == 1)
        let moved = pipeline.resolvingSceneModelMatrices(origins: [:], scales: [:], angles: ["parent": .zero],
                                                         parentByID: ["model": "parent"], hostTransforms: ["parent": host])
        #expect(moved.layers[0].graphLayer.geometry == resolved.layers[0].graphLayer.geometry)
        let next = Self.frame(moved.layers, cache: cache)
        #expect(cache.computeCount == 2)
        #expect(next.frameUniforms.objectUniformValuesByPassID["model.0"]?["g_ModelMatrix"]?.vectorValue != resolved.layers[0].modelMatrixOverride)
        let modelInverse = try #require(next.frameUniforms.objectUniformValuesByPassID["model.0"]?["g_ModelMatrixInverse"]?.vectorValue)
        let inverse = try #require(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: modelInverse))
        let movedMatrix = try #require(moved.layers[0].modelMatrixOverride.flatMap(WPEMetalObjectUniforms.matrix4x4(fromColumnMajor:)))
        #expect(simd_length(inverse * movedMatrix * SIMD4<Double>(1, 2, 3, 1) - SIMD4(1, 2, 3, 1)) < 1e-9)
    }

    // MARK: - Criterion 1: a static scene recomputes nothing

    @Test("A static scene recomputes no object uniforms on a second frame")
    func staticSceneRecomputesNothingOnASecondFrame() {
        let layers = [
            Self.layer(id: "a", geometry: Self.geometry(origin: SIMD3<Double>(1, 2, 3))),
            Self.layer(id: "b", geometry: Self.geometry(scale: SIMD3<Double>(2, 3, 1)), passCount: 3)
        ]
        let cache = WPEObjectUniformCache()

        let first = Self.frame(layers, cache: cache).frameUniforms
        #expect(cache.computeCount == 2, "one matrix build per layer, not per pass")
        #expect(cache.mapRebuildCount == 1)

        let second = Self.frame(layers, cache: cache).frameUniforms
        #expect(cache.computeCount == 2, "a static second frame must build zero matrices")
        #expect(cache.mapRebuildCount == 1, "a static second frame must not rebuild the map")
        #expect(second.objectUniformValuesByPassID == first.objectUniformValuesByPassID)

        for passID in ["b.0", "b.1", "b.2"] {
            #expect(
                second.objectUniformValuesByPassID[passID]
                    == Self.expectedValues(layers[1].graphLayer.geometry)
            )
        }
    }

    // MARK: - Criterion 2: only the layer that moved recomputes

    @Test("Moving one layer recomputes only that layer")
    func movingOneLayerRecomputesOnlyThatLayer() {
        let a = Self.layer(id: "a", geometry: Self.geometry(origin: SIMD3<Double>(1, 0, 0)))
        let b = Self.layer(id: "b", geometry: Self.geometry(origin: SIMD3<Double>(2, 0, 0)))
        let c = Self.layer(id: "c", geometry: Self.geometry(origin: SIMD3<Double>(3, 0, 0)))
        let cache = WPEObjectUniformCache()
        _ = Self.frame([a, b, c], cache: cache)
        #expect(cache.computeCount == 3)

        let movedGeometry = Self.geometry(
            origin: SIMD3<Double>(9, 5, 0),
            scale: SIMD3<Double>(2, 2, 1),
            angles: SIMD3<Double>(0, 0, .pi / 2)
        )
        let movedB = Self.layer(id: "b", geometry: movedGeometry)
        let moved = Self.frame([a, movedB, c], cache: cache).frameUniforms

        #expect(cache.computeCount == 4, "exactly one layer moved, so exactly one recompute")
        #expect(cache.mapRebuildCount == 2)
        #expect(moved.objectUniformValuesByPassID["b.0"] == Self.expectedValues(movedGeometry))
        #expect(
            moved.objectUniformValuesByPassID["a.0"]
                == Self.expectedValues(a.graphLayer.geometry)
        )
        #expect(
            moved.objectUniformValuesByPassID["c.0"]
                == Self.expectedValues(c.graphLayer.geometry)
        )
    }

    @Test("A scale or angle change invalidates the memo just like an origin change")
    func scaleAndAngleChangesAlsoInvalidate() {
        let base = Self.geometry()
        let cache = WPEObjectUniformCache()
        _ = Self.frame([Self.layer(id: "a", geometry: base)], cache: cache)
        #expect(cache.computeCount == 1)

        let scaled = Self.geometry(scale: SIMD3<Double>(1, 1, 4))
        let afterScale = Self.frame([Self.layer(id: "a", geometry: scaled)], cache: cache)
        #expect(cache.computeCount == 2)
        #expect(afterScale.frameUniforms.objectUniformValuesByPassID["a.0"]
            == Self.expectedValues(scaled))

        let rotated = Self.geometry(scale: SIMD3<Double>(1, 1, 4), angles: SIMD3<Double>(0.25, 0, 0))
        let afterRotation = Self.frame([Self.layer(id: "a", geometry: rotated)], cache: cache)
        #expect(cache.computeCount == 3)
        #expect(afterRotation.frameUniforms.objectUniformValuesByPassID["a.0"]
            == Self.expectedValues(rotated))
    }

    // MARK: - Criterion 3: animated layers still advance

    @Test("An animated layer keeps resolving per frame while its matrices stay cached")
    func animatedLayerStillAdvancesWithCachedMatrices() throws {
        let animatedAlpha = WPESceneAnimatedValue(
            animation: WPESceneNumericAnimation(
                tracks: [[
                    .init(frame: 0, value: 1),
                    .init(frame: 90, value: 0)
                ]],
                fps: 30, length: 90, mode: "single", wrapLoop: false
            ),
            scalarFallback: 1,
            vectorFallback: nil
        )
        let animatedGeometry = Self.geometry(
            origin: SIMD3<Double>(4, 0, 0), alphaAnimation: animatedAlpha
        )
        let layers = [Self.layer(id: "a", geometry: animatedGeometry, solidSeed: [1, 1, 1, 1])]
        let cache = WPEObjectUniformCache()

        let atZero = Self.frame(layers, cache: cache, time: 0)
        #expect(cache.computeCount == 1)
        let alphaAtZero = try #require(
            atZero.pipeline.layers[0].passes[0].uniformValues["g_Color"]?.vectorValue
        )
        #expect(abs(alphaAtZero[3] - 1) < 1e-9)

        let atHalf = Self.frame(layers, cache: cache, time: 1.5)
        let alphaAtHalf = try #require(
            atHalf.pipeline.layers[0].passes[0].uniformValues["g_Color"]?.vectorValue
        )
        #expect(abs(alphaAtHalf[3] - 0.5) < 1e-9, "an animated tint must still advance with time")

        // The animation moves alpha, never origin/scale/angles, so the matrices
        // must be a cache hit on the second frame.
        #expect(cache.computeCount == 1)
        #expect(cache.mapRebuildCount == 1)
        #expect(
            atHalf.frameUniforms.objectUniformValuesByPassID["a.0"]
                == Self.expectedValues(animatedGeometry)
        )
    }

    // MARK: - Criterion 4: layer-set changes invalidate correctly

    @Test("A layer inserted ahead of an existing one does not shift cached matrices")
    func insertedLayerDoesNotShiftCachedMatrices() {
        let a = Self.layer(id: "a", geometry: Self.geometry(origin: SIMD3<Double>(1, 0, 0)))
        let b = Self.layer(id: "b", geometry: Self.geometry(origin: SIMD3<Double>(2, 0, 0)))
        let cache = WPEObjectUniformCache()
        _ = Self.frame([a, b], cache: cache)
        #expect(cache.computeCount == 2)

        // createLayer inserts by sortIndex, so a new layer can land at index 0
        // and slide every cached entry one slot along.
        let inserted = Self.layer(id: "z", geometry: Self.geometry(origin: SIMD3<Double>(7, 7, 7)))
        let after = Self.frame([inserted, a, b], cache: cache).frameUniforms

        #expect(cache.computeCount == 3, "only the new layer is new work")
        #expect(after.objectUniformValuesByPassID["z.0"]
            == Self.expectedValues(inserted.graphLayer.geometry))
        #expect(after.objectUniformValuesByPassID["a.0"]
            == Self.expectedValues(a.graphLayer.geometry))
        #expect(after.objectUniformValuesByPassID["b.0"]
            == Self.expectedValues(b.graphLayer.geometry))
    }

    @Test("A reload that reuses layer ids does not serve the previous scene's matrices")
    func reloadWithReusedLayerIDsInvalidates() {
        let cache = WPEObjectUniformCache()
        _ = Self.frame(
            [Self.layer(id: "a", geometry: Self.geometry(origin: SIMD3<Double>(1, 0, 0)), passCount: 2)],
            cache: cache
        )
        #expect(cache.computeCount == 1)

        let reloadedGeometry = Self.geometry(origin: SIMD3<Double>(-6, 8, 2))
        let reloaded = Self.frame(
            [Self.layer(id: "a", geometry: reloadedGeometry, passCount: 1)],
            cache: cache
        ).frameUniforms

        #expect(cache.computeCount == 2)
        #expect(reloaded.objectUniformValuesByPassID["a.0"] == Self.expectedValues(reloadedGeometry))
        #expect(
            reloaded.objectUniformValuesByPassID["a.1"] == nil,
            "a pass that left the pipeline must not survive in the map"
        )
    }

    @Test("Dropping a layer drops its passes from the map")
    func droppedLayerLeavesTheMap() {
        let a = Self.layer(id: "a", geometry: Self.geometry(origin: SIMD3<Double>(1, 0, 0)))
        let b = Self.layer(id: "b", geometry: Self.geometry(origin: SIMD3<Double>(2, 0, 0)))
        let cache = WPEObjectUniformCache()
        _ = Self.frame([a, b], cache: cache)

        let after = Self.frame([a], cache: cache).frameUniforms
        #expect(after.objectUniformValuesByPassID["b.0"] == nil)
        #expect(after.objectUniformValuesByPassID.count == 1)
        #expect(cache.computeCount == 2, "the surviving layer must not be recomputed")
    }

    // MARK: - Criterion 5: the cached frame context equals the uncached one

    @Test("A cached frame context is value-equal to the uncached one")
    func cachedFrameContextMatchesUncached() {
        let layers = [
            Self.layer(
                id: "a",
                geometry: Self.geometry(
                    origin: SIMD3<Double>(3, -4, 5),
                    scale: SIMD3<Double>(2, 0.5, 3),
                    angles: SIMD3<Double>(0.3, -0.7, 1.1)
                ),
                passCount: 2
            ),
            Self.layer(id: "b", geometry: Self.geometry(), passCount: 1),
            // Degenerate scale: the identity-normal fallback must survive caching.
            Self.layer(id: "c", geometry: Self.geometry(scale: SIMD3<Double>(0, 0, 0)))
        ]
        // `nil` runs the pre-cache arithmetic for every layer, so it is the
        // reference the memo has to reproduce.
        let uncached = Self.frame(layers, cache: nil, time: 2).frameUniforms

        let cache = WPEObjectUniformCache()
        _ = Self.frame(layers, cache: cache, time: 2)
        let cached = Self.frame(layers, cache: cache, time: 2).frameUniforms

        #expect(cached.objectUniformValuesByPassID == uncached.objectUniformValuesByPassID)
        #expect(cached.runtimeUniformValues == uncached.runtimeUniformValues)
        #expect(cached.cameraUniformValues == uncached.cameraUniformValues)
        #expect(cache.computeCount == 3, "the second identical frame added no work")
    }

    @Test("An empty pipeline yields an empty map without touching the cache")
    func emptyPipelineYieldsEmptyMap() {
        let cache = WPEObjectUniformCache()
        let frame = Self.frame([], cache: cache).frameUniforms
        #expect(frame.objectUniformValuesByPassID.isEmpty)
        #expect(cache.computeCount == 0)
        #expect(cache.mapRebuildCount == 0)
    }
}
