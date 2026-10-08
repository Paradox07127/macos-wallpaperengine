#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("Projected composelayer routing")
struct WPEProjectedComposeRoutingTests {
    private typealias Models = WPEMetalSceneCaptureUtilityModels
    private static let scene = CGSize(width: 3840, height: 2160)
    private static let kinds: [WPEUtilityModelKind?] = [nil] + WPEUtilityModelKind.allCases
    private static let sizes: [CGSize?] = [
        nil, CGSize(width: 3840, height: 2160), CGSize(width: 400, height: 300), CGSize(width: 1, height: 1),
    ]
    private static let scales: [SIMD3<Double>] = [
        SIMD3(1, 1, 1), SIMD3(1.3, 1.3, 1.5), SIMD3(-1, 1, 1), SIMD3(0.2, 0.2, 1),
    ]
    private static let angleSet: [SIMD3<Double>] = [
        .zero, SIMD3(2.5, -2.5, 0) * .pi / 180, SIMD3(0, 0, .pi), SIMD3(.pi, 0, 0),
    ]

    private static func geometry(
        size: CGSize?, scale: SIMD3<Double> = SIMD3(1.3, 1.3, 1.5), angles: SIMD3<Double> = .zero,
        origin: SIMD3<Double> = SIMD3(1920, 1080, 0)
    ) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin, scale: scale, angles: angles, alignment: .center,
            size: size, alpha: 1, color: SIMD3(1, 1, 1), brightness: 1
        )
    }

    private static func layer(
        path: String = "models/util/composelayer.json", geometry: WPERenderLayerGeometry,
        localFBOs: [WPERenderFBO] = []
    ) -> WPERenderLayer {
        WPERenderLayer(
            objectID: "2077", objectName: "Compose", imagePath: path,
            materialPath: "materials/util/composelayer.json", geometry: geometry,
            compositeA: "_rt_imageLayerComposite_2077_a", compositeB: "_rt_imageLayerComposite_2077_b",
            localFBOs: localFBOs, passes: []
        )
    }

    private static func forEachGridPoint(_ body: (WPEUtilityModelKind?, WPERenderLayerGeometry) -> Void) {
        for kind in kinds {
            for size in sizes {
                for scale in scales {
                    for angles in angleSet {
                        body(kind, geometry(size: size, scale: scale, angles: angles))
                    }
                }
            }
        }
    }

    @Test("Omitting composePerspective routes exactly like passing false")
    func omittedFlagMatchesFalse() {
        Self.forEachGridPoint { kind, geometry in
            #expect(Models.outputGeometry(kind: kind, geometry: geometry, sceneSize: Self.scene)
                == Models.outputGeometry(kind: kind, geometry: geometry, sceneSize: Self.scene, composePerspective: false))
        }
    }

    @Test("Only a sized composelayer routes to projected when the perspective bit is set")
    func perspectiveBitRoutesComposeLayersOnly() {
        Self.forEachGridPoint { kind, geometry in
            let routed = Models.outputGeometry(kind: kind, geometry: geometry, sceneSize: Self.scene, composePerspective: true)
            if kind == .composeLayer, geometry.size != nil {
                #expect(routed == .projected, "\(String(describing: kind)) \(geometry)")
            } else {
                #expect(routed == .fullscreen, "\(String(describing: kind)) \(geometry)")
            }
        }
        let elisa = Self.geometry(size: Self.scene, angles: SIMD3(2.5, -2.5, 0) * .pi / 180)
        #expect(Models.outputGeometry(path: "models/util/composelayer.json", geometry: elisa, sceneSize: Self.scene) == .fullscreen)
        #expect(Models.outputGeometry(
            path: "models/util/composelayer.json", geometry: elisa, sceneSize: Self.scene, composePerspective: true
        ) == .projected)
    }

    @Test("The memo keys on the perspective bit")
    func memoKeysOnPerspectiveBit() {
        let memo = WPESceneCaptureOutputGeometryMemo()
        let geometry = Self.geometry(size: Self.scene)
        let layer = Self.layer(geometry: geometry)
        #expect(memo.outputGeometry(layer: layer, geometry: geometry, sceneSize: Self.scene) == .fullscreen)
        #expect(memo.outputGeometry(layer: layer, geometry: geometry, sceneSize: Self.scene, composePerspective: true) == .projected)
        #expect(memo.outputGeometry(layer: layer, geometry: geometry, sceneSize: Self.scene, composePerspective: false) == .fullscreen)
    }

    @Test("A sampled full-cover composelayer with a non-identity transform captures through its own transform")
    func sampledCoverRoutesToSubregion() {
        let scaled = Self.geometry(size: Self.scene, scale: SIMD3(1.5, 1.5, 1.5))
        func route(_ geometry: WPERenderLayerGeometry, sampled: Bool, perspective: Bool = false) -> Models.OutputGeometry {
            Models.outputGeometry(
                kind: .composeLayer, geometry: geometry, sceneSize: Self.scene,
                composePerspective: perspective, sampledByOtherLayers: sampled
            )
        }
        #expect(route(scaled, sampled: true) == .subregion)
        #expect(route(scaled, sampled: false) == .fullscreen)
        #expect(Models.outputGeometry(kind: .composeLayer, geometry: scaled, sceneSize: Self.scene) == .fullscreen)
        #expect(route(scaled, sampled: true, perspective: true) == .projected)
        #expect(route(Self.geometry(size: Self.scene, scale: SIMD3(1, 1, 1)), sampled: true) == .fullscreen)
        let offCenter = Self.geometry(size: Self.scene, scale: SIMD3(1, 1, 1), origin: SIMD3(1900, 1080, 0))
        #expect(route(offCenter, sampled: true) == .subregion)
        #expect(route(offCenter, sampled: false) == .fullscreen)
        #expect(Models.outputGeometry(
            kind: .fullScreenLayer, geometry: scaled, sceneSize: Self.scene, sampledByOtherLayers: true
        ) == .fullscreen)
    }

    @Test("The memo keys on the sampled-by-other-layers bit")
    func memoKeysOnSampledBit() {
        let memo = WPESceneCaptureOutputGeometryMemo()
        let geometry = Self.geometry(size: Self.scene, scale: SIMD3(1.5, 1.5, 1.5))
        let layer = Self.layer(geometry: geometry)
        #expect(memo.outputGeometry(layer: layer, geometry: geometry, sceneSize: Self.scene) == .fullscreen)
        #expect(memo.outputGeometry(layer: layer, geometry: geometry, sceneSize: Self.scene, sampledByOtherLayers: true) == .subregion)
        #expect(memo.outputGeometry(layer: layer, geometry: geometry, sceneSize: Self.scene, sampledByOtherLayers: false) == .fullscreen)
    }

    private static func preparedLayer(_ id: String, reads: WPETextureReference) -> WPEPreparedRenderLayer {
        let composite = WPERenderTargetNames.ImageLayerComposite.make(objectID: id)
        let raw = WPERenderPass(
            id: "\(id).0", phase: .material, shader: "compose", source: reads, target: .layerComposite(name: composite.a),
            textures: [0: reads], binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull",
            depthTest: "disabled", depthWrite: "disabled"
        )
        let pass = WPEPreparedRenderPass(
            pass: raw, shader: WPEShaderProgram(name: "compose", vertexSource: "", fragmentSource: "", isBuiltin: true),
            textureBindings: [0: reads], comboValues: [:], uniformValues: [:]
        )
        let layer = WPERenderLayer(
            objectID: id, objectName: id, imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer.json", geometry: geometry(size: scene),
            compositeA: composite.a, compositeB: composite.b, localFBOs: [], passes: [raw]
        )
        return WPEPreparedRenderLayer(graphLayer: layer, passes: [pass])
    }

    @Test("Only layer composites read by another layer count as sampled")
    func sampledCompositeObjectIDs() {
        let producer = Self.preparedLayer("1576", reads: .fbo("_rt_FullFrameBuffer"))
        let consumer = Self.preparedLayer("2077", reads: .fbo("_rt_imageLayerComposite_1576_a"))
        let selfReader = Self.preparedLayer("9", reads: .fbo("_rt_imageLayerComposite_9_b"))
        typealias Topology = WPEMetalRenderExecutor.FBOAliasTopology
        #expect(Topology.sampledCompositeObjectIDs(in: [producer, consumer]) == ["1576"])
        #expect(Topology.sampledCompositeObjectIDs(in: [producer, selfReader]).isEmpty)
        #expect(Topology.sampledCompositeObjectIDs(in: [producer]).isEmpty)
    }

    @Test("A sampled full-cover composelayer's composite and local FBO keep the authored size")
    func sampledCoverTargetsUseAuthoredSize() {
        let authored = CGSize(width: 3800, height: 2140)
        let layer = Self.layer(
            geometry: Self.geometry(size: authored, scale: SIMD3(1.5, 1.5, 1.5)),
            localFBOs: [WPERenderFBO(name: "blur", scale: 1, format: "rgba8888")]
        )
        #expect(WPEMetalRenderTargetPool.layerLocalFBOPixelSize(fboName: "blur", layer: layer, sceneSize: Self.scene) == Self.scene)
        #expect(WPEMetalRenderTargetPool.layerLocalFBOPixelSize(
            fboName: "blur", layer: layer, sceneSize: Self.scene, sampledByOtherLayers: true
        ) == authored)
    }

    @Test("A projected composelayer's local FBO uses the authored size")
    func projectedLocalFBOUsesAuthoredSize() {
        let authored = CGSize(width: 3000, height: 1700)
        let layer = Self.layer(
            geometry: Self.geometry(size: authored), localFBOs: [WPERenderFBO(name: "blur", scale: 1, format: "rgba8888")]
        )
        #expect(WPEMetalRenderTargetPool.layerLocalFBOPixelSize(fboName: "blur", layer: layer, sceneSize: Self.scene) == Self.scene)
        #expect(WPEMetalRenderTargetPool.layerLocalFBOPixelSize(
            fboName: "blur", layer: layer, sceneSize: Self.scene, composePerspective: true
        ) == authored)
    }
}
#endif
