#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

@Suite("WPE on-demand video residency")
struct WPEOnDemandVideoResidencyTests {
    private static let videoKey = "materials/video/clip.mp4"

    private static func pass(
        _ id: String,
        source: WPETextureReference,
        target: WPERenderTarget
    ) -> WPEPreparedRenderPass {
        WPEPreparedRenderPass(
            pass: WPERenderPass(
                id: id,
                phase: .material,
                shader: "genericimage2",
                source: source,
                target: target,
                textures: [:],
                binds: [:],
                constants: [:],
                combos: [:],
                blending: "normal",
                cullMode: "nocull",
                depthTest: "disabled",
                depthWrite: "disabled"
            ),
            shader: nil,
            textureBindings: [:],
            comboValues: [:],
            uniformValues: [:]
        )
    }

    private static func layer(
        _ objectID: String,
        visible: Bool,
        imagePath: String = "",
        passes: [WPEPreparedRenderPass]
    ) -> WPEPreparedRenderLayer {
        WPEPreparedRenderLayer(
            graphLayer: WPERenderLayer(
                objectID: objectID,
                objectName: objectID,
                visible: visible,
                imagePath: imagePath,
                materialPath: nil,
                geometry: .identity,
                compositeA: "_rt_imageLayerComposite_\(objectID)_a",
                compositeB: "_rt_imageLayerComposite_\(objectID)_b",
                localFBOs: [],
                passes: passes.map(\.pass)
            ),
            passes: passes
        )
    }

    private static func neededKeys(_ layers: [WPEPreparedRenderLayer]) -> Set<String> {
        let graph = WPEMetalSceneRenderer.onDemandVideoKeysByConsumerLayer(
            layers: layers,
            videoKeyByLayerID: ["video": [videoKey]]
        )
        return WPEMetalSceneRenderer.neededOnDemandVideoKeys(
            in: layers,
            keysByConsumerID: graph
        )
    }

    @Test("A missing source always loads; a still source reloads only when a decoder slot is free")
    func stillSourcePromotesOnlyWhenAdmissionHasVacancy() {
        #expect(WPEMetalSceneRenderer.shouldStartOnDemandVideoLoad(
            hasResidentSource: false, isLiveDecoder: false, admissionHasVacancy: false
        ))
        #expect(!WPEMetalSceneRenderer.shouldStartOnDemandVideoLoad(
            hasResidentSource: true, isLiveDecoder: true, admissionHasVacancy: true
        ))
        #expect(!WPEMetalSceneRenderer.shouldStartOnDemandVideoLoad(
            hasResidentSource: true, isLiveDecoder: false, admissionHasVacancy: false
        ), "no vacancy → keep the still rather than thrashing rebuilds")
        #expect(WPEMetalSceneRenderer.shouldStartOnDemandVideoLoad(
            hasResidentSource: true, isLiveDecoder: false, admissionHasVacancy: true
        ), "hidden release freeing a ticket must rebuild a visible still")
    }

    @Test("A hidden video layer whose FBO nothing visible samples is releasable")
    func hiddenVideoWritingAnUnreadFBOIsReleasable() {
        let video = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_VideoBlur")),
            Self.pass("video.1", source: .fbo("_rt_VideoBlur"), target: .scene),
        ])
        let background = Self.layer("bg", visible: true, passes: [
            Self.pass("bg.0", source: .image("bg.png"), target: .scene),
        ])

        // 不是废话:这个 layer 不满足“每个 pass 都 target .scene”的形状,
        // 以此为判据的实现根本不会索引到这个视频。
        #expect(!video.passes.allSatisfy { pass in
            if case .scene = pass.pass.target { return true }
            return false
        })
        #expect(Self.neededKeys([video, background]).isEmpty)
    }

    /// 反误释放对照组:只看视频层自身可见性的判断会在这里释放源,
    /// 可见的 overlay 就采到占位纹理。
    @Test("A hidden video layer whose FBO a VISIBLE layer samples is NOT releasable")
    func hiddenVideoFeedingAVisibleConsumerIsNotReleasable() {
        let video = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_VideoBlur")),
        ])
        let overlay = Self.layer("overlay", visible: true, passes: [
            Self.pass("overlay.0", source: .fbo("_rt_VideoBlur"), target: .scene),
        ])

        #expect(Self.neededKeys([video, overlay]) == [Self.videoKey])
    }

    @Test("Consumption is followed transitively through a chain of hidden layers")
    func transitiveConsumerChainKeepsTheVideoResident() {
        let video = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_One")),
        ])
        // Hidden, but the executor still encodes an FBO-targeting pass of a hidden
        // layer, so the video's pixels really do reach _rt_Two.
        let middle = Self.layer("middle", visible: false, passes: [
            Self.pass("middle.0", source: .fbo("_rt_One"), target: .fbo(name: "_rt_Two")),
        ])
        let tail = Self.layer("tail", visible: true, passes: [
            Self.pass("tail.0", source: .fbo("_rt_Two"), target: .scene),
        ])

        #expect(Self.neededKeys([video, middle, tail]) == [Self.videoKey])
        let hiddenTail = Self.layer("tail", visible: false, passes: tail.passes)
        #expect(Self.neededKeys([video, middle, hiddenTail]).isEmpty)
    }

    @Test("A video written into several FBOs is kept by a consumer of any one of them")
    func multipleWrittenFBOsAreUnioned() {
        let video = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_One")),
            Self.pass("video.1", source: .image(Self.videoKey), target: .fbo(name: "_rt_Two")),
            Self.pass("video.2", source: .fbo("_rt_Two"), target: .scene),
        ])
        // 没有“唯一写者”可以作为键。
        let overlay = Self.layer("overlay", visible: true, passes: [
            Self.pass("overlay.0", source: .fbo("_rt_Two"), target: .scene),
        ])

        #expect(Self.neededKeys([video, overlay]) == [Self.videoKey])
    }

    @Test("A scene-alias read does not make a layer a consumer")
    func sceneAliasReadsDoNotPropagate() {
        let video = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .scene),
        ])
        // `_rt_FullFrameBuffer` is the scene composed so far. The hidden video's
        // `.scene` pass is skipped by the executor, so it contributes nothing.
        let postProcess = Self.layer("post", visible: true, passes: [
            Self.pass("post.0", source: .fbo("_rt_FullFrameBuffer"), target: .scene),
        ])

        #expect(Self.neededKeys([video, postProcess]).isEmpty)
    }

    @Test("A hidden group child's layer-group write does not propagate to the group parent")
    func layerGroupWritesDoNotPropagate() {
        // 隐藏层的 `_rt_layerGroup_*` pass 就是它的可见输出,executor 会像
        // 跳过 `.scene` 一样跳过它。
        let video = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_layerGroup_g")),
        ])
        let group = Self.layer("g", visible: true, passes: [
            Self.pass("g.0", source: .fbo("_rt_layerGroup_g"), target: .scene),
        ])

        #expect(Self.neededKeys([video, group]).isEmpty)
    }

    @Test("A visible video layer keeps its own source resident")
    func visibleVideoLayerKeepsItsSource() {
        let video = Self.layer("video", visible: true, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_VideoBlur")),
            Self.pass("video.1", source: .fbo("_rt_VideoBlur"), target: .scene),
        ])

        #expect(Self.neededKeys([video]) == [Self.videoKey])
    }

    @Test("Two layers sharing one video keep it while either is visible")
    func sharedVideoKeyAggregatesAcrossLayers() {
        let hidden = Self.layer("videoA", visible: false, passes: [
            Self.pass("videoA.0", source: .image(Self.videoKey), target: .scene),
        ])
        let visible = Self.layer("videoB", visible: true, passes: [
            Self.pass("videoB.0", source: .image(Self.videoKey), target: .scene),
        ])
        let shared: [String: Set<String>] = ["videoA": [Self.videoKey], "videoB": [Self.videoKey]]

        let graph = WPEMetalSceneRenderer.onDemandVideoKeysByConsumerLayer(
            layers: [hidden, visible],
            videoKeyByLayerID: shared
        )
        #expect(WPEMetalSceneRenderer.neededOnDemandVideoKeys(
            in: [hidden, visible],
            keysByConsumerID: graph
        ) == [Self.videoKey])

        let bothHidden = [hidden, Self.layer("videoB", visible: false, passes: visible.passes)]
        #expect(WPEMetalSceneRenderer.neededOnDemandVideoKeys(
            in: bothHidden,
            keysByConsumerID: graph
        ).isEmpty)
    }

    @Test("A scene with no video layers builds an empty graph")
    func noVideoLayersBuildsEmptyGraph() {
        let background = Self.layer("bg", visible: true, passes: [
            Self.pass("bg.0", source: .image("bg.png"), target: .scene),
        ])

        #expect(WPEMetalSceneRenderer.onDemandVideoKeysByConsumerLayer(
            layers: [background],
            videoKeyByLayerID: [:]
        ).isEmpty)
        #expect(WPEMetalSceneRenderer.neededOnDemandVideoKeys(
            in: [background],
            keysByConsumerID: [:]
        ).isEmpty)
    }

    @Test("A cycle between two layers' FBOs terminates")
    func mutuallyReferencingLayersTerminate() {
        let video = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_One")),
            Self.pass("video.1", source: .fbo("_rt_Two"), target: .scene),
        ])
        let feedback = Self.layer("feedback", visible: false, passes: [
            Self.pass("feedback.0", source: .fbo("_rt_One"), target: .fbo(name: "_rt_Two")),
        ])

        #expect(Self.neededKeys([video, feedback]).isEmpty)
    }

    // MARK: - Edge losses that release a texture a visible layer still samples

    /// 一个 layer 可以把一个视频作为 source、另一个绑在 shader 槽上。
    @Test("A visible layer sampling two videos keeps both resident")
    func aLayerSamplingTwoVideosKeepsBoth() {
        let otherKey = "materials/video/other.mp4"
        let visible = Self.layer("both", visible: true, passes: [
            Self.pass("both.0", source: .image(Self.videoKey), target: .scene),
        ])
        let hidden = Self.layer("hiddenOther", visible: false, passes: [
            Self.pass("hiddenOther.0", source: .image(otherKey), target: .scene),
        ])
        // otherKey 绑在 shader 槽上,不是该层的 source。
        let graph = WPEMetalSceneRenderer.onDemandVideoKeysByConsumerLayer(
            layers: [visible, hidden],
            videoKeyByLayerID: ["both": [Self.videoKey, otherKey], "hiddenOther": [otherKey]]
        )
        let needed = WPEMetalSceneRenderer.neededOnDemandVideoKeys(
            in: [visible, hidden],
            keysByConsumerID: graph
        )
        #expect(needed.contains(Self.videoKey))
        #expect(needed.contains(otherKey), "the shader-slot video is still on screen")
    }

    /// `.previous` resolves to the pass's own target, so a visible layer reading
    /// the previous value of an FBO a hidden video feeds is a real consumer.
    @Test("A visible layer reading .previous of a fed FBO keeps the video resident")
    func previousReadCountsAsSampling() {
        let hiddenVideo = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_Feed")),
        ])
        // `.previous` 必须是唯一的连边:在 source 里也写 `_rt_Feed` 会让这条边
        // 绕过 `.previous` 处理而存在。
        let visible = Self.layer("consumer", visible: true, passes: [
            Self.pass("consumer.0", source: .previous, target: .fbo(name: "_rt_Feed")),
        ])

        #expect(Self.neededKeys([hiddenVideo, visible]).contains(Self.videoKey))
    }

    /// `thisScene.createLayer` clones carry a fresh objectID the load-time graph
    /// never indexed, but they keep the template's image path.
    @Test("A script-created clone inherits its template's consumer entry")
    func createdCloneInheritsTemplateEntry() {
        let templatePath = "materials/clip.tex"
        let hiddenTemplate = Self.layer("template", visible: false, imagePath: templatePath, passes: [
            Self.pass("template.0", source: .image(Self.videoKey), target: .scene),
        ])
        let graph = WPEMetalSceneRenderer.onDemandVideoKeysByConsumerLayer(
            layers: [hiddenTemplate],
            videoKeyByLayerID: ["template": [Self.videoKey]]
        )
        let byPath = WPEMetalSceneRenderer.onDemandVideoKeysByImagePath(
            layers: [hiddenTemplate],
            keysByConsumerID: graph
        )
        let clone = Self.layer("created:1", visible: true, imagePath: templatePath, passes: [
            Self.pass("created:1.0", source: .image(Self.videoKey), target: .scene),
        ])

        #expect(WPEMetalSceneRenderer.neededOnDemandVideoKeys(
            in: [hiddenTemplate, clone],
            keysByConsumerID: graph,
            keysByImagePath: byPath
        ).contains(Self.videoKey))

        // Control: with the template hidden and no clone on screen, it still releases.
        #expect(WPEMetalSceneRenderer.neededOnDemandVideoKeys(
            in: [hiddenTemplate],
            keysByConsumerID: graph,
            keysByImagePath: byPath
        ).isEmpty)
    }

    /// executor 先剥掉一层 `_rt_` 再匹配,所以 `_rt__rt_Feed` 能解析到
    /// 写者的 `_rt_Feed`。
    @Test("A doubled _rt_ prefix still matches its writer")
    func doubledRuntimePrefixMatches() {
        let hiddenVideo = Self.layer("video", visible: false, passes: [
            Self.pass("video.0", source: .image(Self.videoKey), target: .fbo(name: "_rt_Feed")),
        ])
        let visible = Self.layer("consumer", visible: true, passes: [
            Self.pass("consumer.0", source: .fbo("_rt__rt_Feed"), target: .scene),
        ])

        #expect(Self.neededKeys([hiddenVideo, visible]).contains(Self.videoKey))
    }
}
#endif
