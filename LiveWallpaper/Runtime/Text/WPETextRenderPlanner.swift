#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import simd

/// The exact layout state used by both the render graph and the glyph encoder.
/// It is recomputed only when layout-affecting text state changes; no guessed
/// headroom or authored target size participates in the allocation.
struct WPETextLayoutSnapshot: Equatable {
    let blockSize: CGSize
    let anchorOffset: SIMD2<Double>
    let ascender: Double
    let surfaceSize: CGSize
    let meshOrigin: SIMD2<Double>

    var centerOffsetFromObjectOrigin: SIMD2<Double> {
        SIMD2<Double>(
            anchorOffset.x + blockSize.width / 2,
            anchorOffset.y + ascender - blockSize.height / 2
        )
    }
}

struct WPETextRenderPlan {
    let object: WPESceneTextObject
    let mode: WPETextRenderMode
    let copiesSceneBackground: Bool
    let initialLayout: WPETextLayoutSnapshot
    let imageObject: WPESceneImageObject

    var renderPath: String { imageObject.imageRelativePath }
}

struct WPETextLayoutCacheEntry {
    let key: String
    let snapshot: WPETextLayoutSnapshot
}

/// Per-frame glyph data consumed by the renderer-owned `wpe_text_glyph` pass.
/// Direct text uses scene coordinates; offscreen text uses target-local pixels.
struct WPETextRenderPayload {
    let mode: WPETextRenderMode
    let mesh: WPETextMeshPayload?
    let backgroundColor: SIMD4<Float>?
    let copiesSceneBackground: Bool
}

extension WPESceneDocument {
    func appendingImageObjects(_ extra: [WPESceneImageObject]) -> WPESceneDocument {
        guard !extra.isEmpty else { return self }
        var copy = self
        copy.imageObjects.append(contentsOf: extra)
        return copy
    }
}

enum WPETextRenderPlanner {
    static func plans(
        for document: WPESceneDocument,
        fonts: WPETextFontResolver
    ) -> [WPETextRenderPlan] {
        let linkedSourceIDs = Set(document.imageObjects.flatMap(\.dependencies))
        return document.textObjects.map {
            plan(for: $0, fonts: fonts, isLinkedSource: linkedSourceIDs.contains($0.id))
        }
    }

    static func plan(
        for object: WPESceneTextObject,
        fonts: WPETextFontResolver,
        isLinkedSource: Bool = false
    ) -> WPETextRenderPlan {
        let mode = renderMode(for: object, isLinkedSource: isLinkedSource)
        let copiesSceneBackground = object.effects.contains { $0.visible || $0.visibleScript != nil }
            || object.copyBackground
            || isLinkedSource
        let layout = snapshot(for: object, fonts: fonts)
        return WPETextRenderPlan(
            object: object,
            mode: mode,
            copiesSceneBackground: copiesSceneBackground,
            initialLayout: layout,
            imageObject: WPETextLayerSynthesis.imageObject(
                for: object,
                mode: mode,
                blockSize: layout.blockSize,
                anchorOffset: layout.anchorOffset,
                ascender: layout.ascender,
                targetSize: layout.surfaceSize
            )
        )
    }

    /// A plain independent text
    /// object can render directly; effects or framebuffer dependencies require
    /// a layer-sized intermediate surface.
    static func renderMode(
        for object: WPESceneTextObject,
        isLinkedSource: Bool
    ) -> WPETextRenderMode {
        let hasEffect = object.effects.contains { $0.visible || $0.visibleScript != nil }
        if hasEffect || object.copyBackground || object.opaqueBackground || isLinkedSource {
            return .offscreen
        }
        return .direct
    }

    static func layoutKey(for object: WPESceneTextObject) -> String {
        [
            object.text,
            object.fontRelativePath ?? "",
            String(object.pointSize),
            String(object.letterSpacing),
            object.horizontalAlignment,
            object.verticalAlignment,
            String(object.maxWidth ?? -1),
            String(object.maxRows ?? -1),
            String(object.limitUseEllipsis),
            String(object.padding)
        ].joined(separator: "\u{1F}")
    }

    static func snapshot(
        for object: WPESceneTextObject,
        fonts: WPETextFontResolver
    ) -> WPETextLayoutSnapshot {
        guard let layout = WPETextLayoutEngine.layout(
            text: object.text,
            font: fonts.font(for: object),
            letterSpacing: object.letterSpacing,
            horizontalAlignment: object.horizontalAlignment,
            maxWidth: object.maxWidth,
            maxRows: object.maxRows,
            ellipsis: object.limitUseEllipsis
        ) else {
            // A scripted empty string still needs a graph node so it can become
            // visible later. The 1x1 surface is geometry only and allocates no
            // dedicated text texture in Direct mode.
            return WPETextLayoutSnapshot(
                blockSize: .zero,
                anchorOffset: .zero,
                ascender: 0,
                surfaceSize: CGSize(width: 1, height: 1),
                meshOrigin: SIMD2<Double>(0.5, 0.5)
            )
        }

        let blockSize = layout.blockSize
        let anchorOffset = layout.anchorOffset(
            horizontalAlignment: object.horizontalAlignment,
            verticalAlignment: object.verticalAlignment
        )
        let ascender = layout.metrics.ascender.rounded(.up)
        let surfaceSize = WPETextLayerSynthesis.targetSize(
            blockSize: blockSize,
            padding: object.padding
        )
        return WPETextLayoutSnapshot(
            blockSize: blockSize,
            anchorOffset: anchorOffset,
            ascender: ascender,
            surfaceSize: surfaceSize,
            meshOrigin: WPETextLayerSynthesis.meshOriginInTarget(
                blockSize: blockSize,
                anchorOffset: anchorOffset,
                ascender: ascender,
                targetSize: surfaceSize
            )
        )
    }
}
#endif
