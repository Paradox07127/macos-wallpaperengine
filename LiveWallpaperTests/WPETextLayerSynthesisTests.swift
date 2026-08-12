#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import Testing
@testable import LiveWallpaper

struct WPETextLayerSynthesisTests {
    private func fonts() -> WPETextFontResolver {
        WPETextFontResolver(resolver: WPEMultiRootResourceResolver(
            primaryRootURL: FileManager.default.temporaryDirectory,
            dependencyMounts: []
        ))
    }

    private func textObject(
        text: String = "12:34",
        textScript: String? = nil,
        effects: [WPESceneImageEffect] = [],
        padding: Double = 32,
        copyBackground: Bool = false,
        opaqueBackground: Bool = false
    ) -> WPESceneTextObject {
        WPESceneTextObject(
            id: "t7", name: "Clock", text: text, textScript: textScript,
            fontRelativePath: nil, pointSize: 32,
            color: SIMD3<Double>(1, 0.5, 0.25), brightness: 2, alpha: 0.75,
            origin: SIMD3<Double>(1000, 800, 0), scale: SIMD3<Double>(2, 2, 1),
            visible: true,
            horizontalAlignment: "center", verticalAlignment: "center",
            maxWidth: nil, parallaxDepth: SIMD2<Double>(4, 0), padding: padding,
            copyBackground: copyBackground, opaqueBackground: opaqueBackground,
            effects: effects
        )
    }

    @Test("Surface is exactly current block plus WPE padding")
    func targetSizeIsExact() {
        #expect(WPETextLayerSynthesis.targetSize(
            blockSize: CGSize(width: 400, height: 100), padding: 31
        ) == CGSize(width: 462, height: 162))
    }

    @Test("Changing live text recomputes an exact surface instead of reserving headroom")
    func liveTextResizesExactly() {
        let resolver = fonts()
        let short = textObject(text: "DAY", textScript: "export function update(v) { return v }")
        let long = short.withLiveText("WEDNESDAY", alpha: 1, color: nil)
        let shortLayout = WPETextRenderPlanner.snapshot(for: short, fonts: resolver)
        let longLayout = WPETextRenderPlanner.snapshot(for: long, fonts: resolver)
        // Both sides bound as CGFloat on purpose. `blockSize.width + padding * 2`
        // mixes CGFloat with Double, and inside `#expect`'s generic binary-operation
        // check the SE-0307 implicit conversion does not apply the way it does for a
        // plain `==` — under Swift 6.3.3 that comparison reports false for
        // bit-identical operands (measured: both 0x4071_4000_0000_0000).
        let expectedShortWidth: CGFloat = ceil(shortLayout.blockSize.width + short.padding * 2)
        let expectedLongWidth: CGFloat = ceil(longLayout.blockSize.width + long.padding * 2)
        #expect(longLayout.surfaceSize.width > shortLayout.surfaceSize.width)
        #expect(shortLayout.surfaceSize.width == expectedShortWidth)
        #expect(longLayout.surfaceSize.width == expectedLongWidth)
    }

    @Test("Empty scripted text retains a 1x1 graph node without a text texture")
    func emptyScriptedTextKeepsGraphNode() {
        let plan = WPETextRenderPlanner.plan(
            for: textObject(text: "", textScript: "export function update() { return 'LIVE'; }"),
            fonts: fonts()
        )
        #expect(plan.initialLayout.surfaceSize == CGSize(width: 1, height: 1))
        #expect(plan.mode == .direct)
        #expect(WPETextLayerSynthesis.isTargetPath(plan.renderPath))
    }

    @Test("Plain text is Direct; effects and framebuffer dependencies are Offscreen")
    func renderModeMatchesWPE() {
        let effect = WPESceneImageEffect(
            id: "e", name: "opacity", fileRelativePath: "effects/opacity/effect.json",
            visible: true, passOverrides: []
        )
        #expect(WPETextRenderPlanner.renderMode(for: textObject(), isLinkedSource: false) == .direct)
        #expect(WPETextRenderPlanner.renderMode(
            for: textObject(effects: [effect]), isLinkedSource: false
        ) == .offscreen)
        #expect(WPETextRenderPlanner.renderMode(
            for: textObject(copyBackground: true), isLinkedSource: false
        ) == .offscreen)
        #expect(WPETextRenderPlanner.renderMode(
            for: textObject(opaqueBackground: true), isLinkedSource: false
        ) == .offscreen)
        #expect(WPETextRenderPlanner.renderMode(for: textObject(), isLinkedSource: true) == .offscreen)
        #expect(WPETextRenderPlanner.plan(
            for: textObject(effects: [effect]), fonts: fonts()
        ).copiesSceneBackground)
        #expect(!WPETextRenderPlanner.plan(
            for: textObject(opaqueBackground: true), fonts: fonts()
        ).copiesSceneBackground)
    }

    @Test("Synthetic text layer carries graph state and never double-tints")
    func syntheticLayerState() {
        let object = textObject()
        let layout = WPETextRenderPlanner.snapshot(for: object, fonts: fonts())
        let layer = WPETextLayerSynthesis.imageObject(
            for: object,
            mode: .direct,
            blockSize: layout.blockSize,
            anchorOffset: layout.anchorOffset,
            ascender: layout.ascender,
            targetSize: layout.surfaceSize
        )
        #expect(layer.imageRelativePath == "__wpetext__/direct/t7.layer")
        #expect(layer.materialRelativePath == layer.imageRelativePath)
        #expect(layer.size == layout.surfaceSize)
        #expect(layer.scale == object.scale)
        #expect(layer.parallaxDepth == object.parallaxDepth)
        #expect(layer.color == SIMD3<Double>(1, 1, 1))
        #expect(layer.brightness == 1)
    }

    @Test("Layer centre rotates around the text object origin")
    func layerOriginRotatesAboutAnchor() {
        let origin = WPETextLayerSynthesis.layerOrigin(
            textOrigin: SIMD3<Double>(1000, 800, 0),
            anchorOffset: SIMD2<Double>(0, 0),
            blockSize: CGSize(width: 200, height: 100),
            ascender: 50,
            angles: SIMD3<Double>(0, 0, .pi / 2),
            scale: SIMD3<Double>(1, 1, 1)
        )
        #expect(abs(origin.x - 1000) < 1e-9)
        #expect(abs(origin.y - 900) < 1e-9)
    }

    @Test("Offscreen mesh baseline obeys the exact WPE padding gutter")
    func meshPenMatchesGutter() {
        let padding = 31.0
        let ascender = 80.0
        let block = CGSize(width: 400, height: 110)
        let target = WPETextLayerSynthesis.targetSize(blockSize: block, padding: padding)
        let anchor = SIMD2<Double>(0, -ascender)
        let mesh = WPETextLayerSynthesis.meshOriginInTarget(
            blockSize: block, anchorOffset: anchor, ascender: ascender, targetSize: target
        )
        #expect(abs(mesh.x + anchor.x - padding) < 1e-9)
        #expect(abs(mesh.y - anchor.y - (padding + ascender)) < 1e-9)
    }
}
#endif
