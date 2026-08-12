#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import simd

enum WPETextRenderMode: Equatable, Sendable {
    case direct
    case offscreen
}

/// Turns a scene's text objects into graph layers so paint order, effects and
/// parent transforms stay in the same executor pass stream as image objects.
///
/// Wallpaper Engine routes text through the scene graph: plain text draws its
/// glyph mesh directly in paint order, while text with effects/background or a
/// linked consumer uses a local intermediate. RenderDoc on 2780710296 shows the
/// text draws before the character compositing at pass #23, so a post-render
/// overlay (what we did until 2026-08-07) cannot preserve occlusion or effects.
///
/// The first material pass is a renderer-owned glyph-mesh pass. For Direct text
/// the graph builder fuses that pass into the scene target. Offscreen text writes
/// the glyph mesh straight into the layer composite before its effect chain.
/// There is deliberately no separate per-object rgba16Float glyph texture.
enum WPETextLayerSynthesis {
    static let glyphPassShader = "wpe_text_glyph"

    /// Synthetic path used only to route the graph builder. It never resolves
    /// to an asset; the special glyph pass consumes a runtime mesh payload.
    static func renderPath(objectID: String, mode: WPETextRenderMode) -> String {
        let component = mode == .direct ? "direct" : "offscreen"
        return "__wpetext__/\(component)/\(objectID).layer"
    }

    static func isTargetPath(_ path: String) -> Bool {
        path.hasPrefix("__wpetext__/")
    }

    static func isOffscreenPath(_ path: String) -> Bool {
        path.hasPrefix("__wpetext__/offscreen/")
    }

    static func isGlyphPassShader(_ shader: String) -> Bool {
        shader == glyphPassShader
    }

    /// The offscreen text surface's size in scene pixels: the block plus WPE's padding
    /// gutter on every side (`padding` is documented as "increases the geometry
    /// around the font characters", and 2955378002's `padding: 31` measures as
    /// exactly block+62 in the capture).
    ///
    /// The current live block plus the authored padding gutter. Windows L1
    /// captures measure this exact extent, and WPE recomputes it after SetText.
    /// No authored box, headroom multiplier or guessed future string participates.
    static func targetSize(blockSize: CGSize, padding: Double) -> CGSize {
        let gutter = max(padding, 0) * 2
        return CGSize(
            width: max(blockSize.width + gutter, 1).rounded(.up),
            height: max(blockSize.height + gutter, 1).rounded(.up)
        )
    }

    /// The layer's quad centre in author space (+y up): the object's origin
    /// shifted by the anchored block's centre, so the alignment rules stay
    /// exactly where `WPETextBlockLayout.anchorOffset` puts them.
    ///
    /// Block-local (0,0) is the FIRST BASELINE at the block's left edge, so the
    /// block box runs from `+ascender` down to `+ascender − height` — hence the
    /// `+ ascender` term. `angles.z` rotates the offset because WPE rotates the
    /// block about the object origin while the quad shader rotates about the
    /// quad centre; pre-rotating the centre offset makes the two agree.
    static func layerOrigin(
        textOrigin: SIMD3<Double>,
        anchorOffset: SIMD2<Double>,
        blockSize: CGSize,
        ascender: Double,
        angles: SIMD3<Double>,
        scale: SIMD3<Double>
    ) -> SIMD3<Double> {
        let centreX = (anchorOffset.x + blockSize.width * 0.5) * scale.x
        let centreY = (anchorOffset.y + ascender - blockSize.height * 0.5) * scale.y
        let cosZ = cos(angles.z)
        let sinZ = sin(angles.z)
        return SIMD3<Double>(
            textOrigin.x + centreX * cosZ - centreY * sinZ,
            textOrigin.y + centreX * sinZ + centreY * cosZ,
            textOrigin.z
        )
    }

    /// Where the glyph mesh puts the object origin inside the CURRENT exact-size
    /// offscreen surface, in top-left y-down pixels. Direct mode does not create
    /// this surface, but uses the same layout values for scene placement.
    static func meshOriginInTarget(
        blockSize: CGSize,
        anchorOffset: SIMD2<Double>,
        ascender: Double,
        targetSize: CGSize
    ) -> SIMD2<Double> {
        SIMD2<Double>(
            targetSize.width * 0.5 - blockSize.width * 0.5 - anchorOffset.x,
            targetSize.height * 0.5 - blockSize.height * 0.5 + anchorOffset.y + ascender
        )
    }

    /// Builds the synthetic image object for one text object. `blockSize`,
    /// `anchorOffset` and `ascender` come from the load-time layout;
    /// `targetSize` from `targetSize(blockSize:padding:)`.
    static func imageObject(
        for object: WPESceneTextObject,
        mode: WPETextRenderMode = .offscreen,
        blockSize: CGSize,
        anchorOffset: SIMD2<Double>,
        ascender: Double,
        targetSize: CGSize
    ) -> WPESceneImageObject {
        let origin = layerOrigin(
            textOrigin: object.origin,
            anchorOffset: anchorOffset,
            blockSize: blockSize,
            ascender: ascender,
            angles: object.angles,
            scale: object.scale
        )
        let localOrigin = object.localOrigin.map {
            layerOrigin(
                textOrigin: $0,
                anchorOffset: anchorOffset,
                blockSize: blockSize,
                ascender: ascender,
                // Text objects carry no LOCAL angles (the schema never parsed
                // one), so `WPESceneImageObject` falls back to `angles` for the
                // local geometry — rotate the local centre offset with it.
                angles: object.angles,
                scale: object.localScale ?? object.scale
            )
        }
        return WPESceneImageObject(
            id: object.id,
            name: object.name,
            imageRelativePath: renderPath(objectID: object.id, mode: mode),
            materialRelativePath: renderPath(objectID: object.id, mode: mode),
            copyBackground: false,
            parentObjectID: object.parentObjectID,
            origin: origin,
            scale: object.scale,
            angles: object.angles,
            localOrigin: localOrigin,
            localScale: object.localScale,
            localAngles: nil,
            visible: object.visible,
            alpha: object.alpha,
            alphaAnimation: object.alphaAnimation,
            // The text surface is already tinted (the mesh shader folds
            // `color x brightness`), so the layer must not tint it twice.
            color: SIMD3<Double>(1, 1, 1),
            brightness: 1,
            blendMode: .normal,
            alignment: .center,
            size: targetSize,
            effects: object.effects,
            animationLayers: [],
            parallaxDepth: object.parallaxDepth
            // No scripts: the TEXT object still owns them, and every one of
            // them already publishes into a map the layer path reads by object
            // id (origin/scale/angles → `applyingLayerTransforms`, visible/alpha
            // → `liveLayerVisibilityIncludingText`). Copying them here would
            // build a second runtime per script.
        )
    }
}
#endif
