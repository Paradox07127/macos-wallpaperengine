import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

struct WPEScenePreflightTests {

    @Test("Image-only scene with built-in shaders classifies as native playable")
    func imageOnlyScenePlaysNatively() {
        let project = Self.makeProject(requiresWindowsPlugin: false)
        let document = Self.makeDocument(
            imageObjects: [Self.makeImageObject()],
            diagnostics: []
        )

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["scene.json", "materials/sky.json"]
        )

        #expect(result.tier == .nativePlayable)
        #expect(result.featureFlags.isEmpty)
    }

    @Test("Custom shader source now degrades (translator ships) instead of blocking")
    func customShaderDegradesAfterTranslator() {
        let project = Self.makeProject()
        let document = Self.makeDocument(imageObjects: [Self.makeImageObject()])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["scene.json", "shaders/genericimage4.frag", "shaders/genericimage4.vert"]
        )

        #expect(result.tier == .degradedPlayable)
        #expect(result.featureFlags.contains(.customShaderSource))
    }

    @Test("Particle objects classify as native — runtime ships")
    func particlesPlayNatively() {
        let project = Self.makeProject()
        let document = Self.makeDocument(
            imageObjects: [Self.makeImageObject()],
            particleObjects: [Self.makeParticleObject()]
        )

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: []
        )

        #expect(result.tier == .nativePlayable)
        #expect(result.featureFlags.contains(.particleObject))
    }

    @Test("Feature flags come from typed objects rather than diagnostic wording")
    func featureFlagsUseTypedObjects() throws {
        let payload: [String: Any] = [
            "camera": ["center": "0 0 0"],
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080, "auto": true]],
            "objects": [
                ["id": "bg", "name": "BG", "image": "materials/bg.png"],
                ["id": "sound", "name": "Loop", "sound": "sounds/loop.ogg"],
                ["id": "particle", "name": "Sparks", "particle": "particles/sparks.json"],
                ["id": "text", "name": "Title", "text": "Hello"],
                ["id": "light", "name": "Lamp", "light": "lpoint", "color": "1 1 1"],
            ],
        ]
        let document = try WPESceneDocumentParser.parse(
            data: JSONSerialization.data(withJSONObject: payload)
        )

        let result = WPEScenePreflight.classify(
            document: document,
            project: Self.makeProject(),
            scenePackageEntries: []
        )

        #expect(result.featureFlags.contains(.particleObject))
        #expect(result.featureFlags.contains(.textObject))
        #expect(result.featureFlags.contains(.soundObject))
        #expect(result.featureFlags.contains(.lightObject))
        #expect(result.tier == .runtimeSystemsRequired)
    }

    @Test("Diagnostic prose cannot fabricate feature flags")
    func diagnosticProseDoesNotDriveClassification() {
        let document = Self.makeDocument(
            imageObjects: [Self.makeImageObject()],
            diagnostics: [
                WPESceneDiagnostic(
                    severity: .info,
                    message: "Particle object Text Sound Light animationlayers unsupported"
                ),
            ]
        )

        let result = WPEScenePreflight.classify(
            document: document,
            project: Self.makeProject(),
            scenePackageEntries: []
        )

        #expect(result.featureFlags.isEmpty)
        #expect(result.tier == .nativePlayable)
    }

    @Test("Animation layers degrade — base image renders, mesh deformation deferred")
    func animationLayerDegrades() {
        let project = Self.makeProject()
        let layer = WPESceneAnimationLayer(id: 1, rate: 24, visible: true, blend: 1, animation: 0)
        let image = Self.makeImageObject(animationLayers: [layer])
        let document = Self.makeDocument(imageObjects: [image])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: []
        )

        #expect(result.tier == .degradedPlayable)
        #expect(result.featureFlags.contains(.animationLayer))
    }

    @Test("Windows plugin always unsupported")
    func windowsPluginUnsupported() {
        let project = Self.makeProject(requiresWindowsPlugin: true)
        let document = Self.makeDocument(imageObjects: [Self.makeImageObject()])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["bin/plugin.dll", "scene.json"]
        )

        #expect(result.tier == .unsupported)
        #expect(result.featureFlags.contains(.windowsPlugin))
    }

    @Test("Effect-only scene degrades")
    func effectOnlyDegrades() {
        let project = Self.makeProject()
        let effect = WPESceneImageEffect(
            id: "0",
            name: "vignette",
            fileRelativePath: "effects/vignette/effect.json",
            visible: true,
            passOverrides: []
        )
        let image = Self.makeImageObject(effects: [effect])
        let document = Self.makeDocument(imageObjects: [image])

        let result = WPEScenePreflight.classify(
            document: document,
            project: project,
            scenePackageEntries: ["scene.json"]
        )

        #expect(result.tier == .degradedPlayable)
        #expect(result.featureFlags.contains(.imageEffect))
        #expect(result.shaderImplementationInventory.isEmpty)
    }

    @Test("Effect override usertextures produce explicit metadata-only inventory")
    func effectUserTexturesProduceMetadataOnlyInventory() throws {
        let project = Self.makeProject()
        let effect = WPESceneImageEffect(
            id: "effect-7",
            name: "Dynamic input",
            fileRelativePath: "effects/dynamic/effect.json",
            visible: true,
            passOverrides: [WPESceneEffectPassOverride(
                id: 42,
                combos: [:],
                constants: [:],
                textures: [:],
                userTextures: [WPESceneUserTextureBinding(name: "$source", type: "system")]
            )]
        )
        let result = WPEScenePreflight.classify(
            document: Self.makeDocument(imageObjects: [Self.makeImageObject(effects: [effect])]),
            project: project,
            scenePackageEntries: []
        )

        let entry = try #require(result.shaderImplementationInventory.first)
        #expect(result.shaderImplementationInventory.count == 1)
        #expect(entry.stableEffectID == "1:effect:effect-7")
        #expect(entry.stablePassID == "1:effect:effect-7:pass:0")
        #expect(entry.authoredOverrideID == 42)
        #expect(entry.renderPassID == nil)
        #expect(entry.authoredEffectPath == "effects/dynamic/effect.json")
        #expect(entry.authoredShaderPath == nil)
        #expect(entry.classification == .unsupportedMetadataOnly)
        #expect(entry.consumerDisposition == .noRuntimeTextureProviderConsumer)
        #expect(entry.metadataKind == "usertextures")
    }

    @Test("Supported media usertextures are not reported as metadata-only")
    func mediaUserTexturesUseRuntimeConsumer() {
        let project = Self.makeProject()
        let effect = WPESceneImageEffect(
            id: "effect-media",
            name: "Media cover",
            fileRelativePath: "effects/media/effect.json",
            visible: true,
            passOverrides: [WPESceneEffectPassOverride(
                id: 7,
                combos: [:],
                constants: [:],
                textures: [:],
                userTextures: [
                    WPESceneUserTextureBinding(name: "$mediaThumbnail", type: "system"),
                    WPESceneUserTextureBinding(name: "$mediaPreviousThumbnail", type: "system"),
                ]
            )]
        )

        let result = WPEScenePreflight.classify(
            document: Self.makeDocument(imageObjects: [Self.makeImageObject(effects: [effect])]),
            project: project,
            scenePackageEntries: []
        )

        #expect(result.shaderImplementationInventory.isEmpty)
    }

    @Test("Mixed media and unsupported usertextures keep only the unsupported locus")
    func mixedUserTexturesRemainDiagnosable() throws {
        let project = Self.makeProject()
        let effect = WPESceneImageEffect(
            id: "effect-mixed",
            name: "Mixed input",
            fileRelativePath: "effects/mixed/effect.json",
            visible: true,
            passOverrides: [WPESceneEffectPassOverride(
                id: 8,
                combos: [:],
                constants: [:],
                textures: [:],
                userTextures: [
                    WPESceneUserTextureBinding(name: "$mediaThumbnail", type: "system"),
                    WPESceneUserTextureBinding(name: "$futureSystemTexture", type: "system"),
                ]
            )]
        )

        let result = WPEScenePreflight.classify(
            document: Self.makeDocument(imageObjects: [Self.makeImageObject(effects: [effect])]),
            project: project,
            scenePackageEntries: []
        )

        let entry = try #require(result.shaderImplementationInventory.first)
        #expect(result.shaderImplementationInventory.count == 1)
        #expect(entry.consumerDisposition == .noRuntimeTextureProviderConsumer)
        #expect(entry.metadataSources == ["effect-override"])
    }

    // MARK: - Fixtures

    private static func makeProject(requiresWindowsPlugin: Bool = false) -> WallpaperEngineProject {
        WallpaperEngineProject(
            workshopID: "100000001",
            title: "Test Scene",
            entryFile: "scene.json",
            type: .scene,
            previewFileName: nil,
            propertyCount: 0,
            dependencyWorkshopIDs: [],
            requiresWindowsPlugin: requiresWindowsPlugin
        )
    }

    private static func makeDocument(
        imageObjects: [WPESceneImageObject] = [],
        particleObjects: [WPESceneParticleObject] = [],
        diagnostics: [WPESceneDiagnostic] = []
    ) -> WPESceneDocument {
        WPESceneDocument(
            camera: .defaultCamera,
            general: .defaultGeneral,
            imageObjects: imageObjects,
            particleObjects: particleObjects,
            diagnostics: diagnostics
        )
    }

    private static func makeParticleObject() -> WPESceneParticleObject {
        WPESceneParticleObject(
            id: "particle",
            name: "Stars",
            particleRelativePath: "particles/stars.json",
            origin: .zero,
            scale: SIMD3<Double>(repeating: 1),
            angles: .zero,
            visible: true,
            alpha: 1,
            color: SIMD3<Double>(repeating: 1),
            parallaxDepth: .zero
        )
    }

    private static func makeImageObject(
        effects: [WPESceneImageEffect] = [],
        animationLayers: [WPESceneAnimationLayer] = []
    ) -> WPESceneImageObject {
        WPESceneImageObject(
            id: "1",
            name: "bg",
            imageRelativePath: "materials/bg.json",
            materialRelativePath: nil,
            origin: SIMD3<Double>(0, 0, 0),
            scale: SIMD3<Double>(1, 1, 1),
            angles: SIMD3<Double>(0, 0, 0),
            visible: true,
            alpha: 1,
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1,
            blendMode: .normal,
            alignment: .center,
            size: nil,
            effects: effects,
            animationLayers: animationLayers,
            parallaxDepth: SIMD2<Double>(0, 0)
        )
    }
}
