#if !LITE_BUILD
import CoreGraphics
import Foundation
import LiveWallpaperProWPE
import simd

enum WPETextRenderMode: Equatable, Sendable {
    case direct
    case offscreen
}

/// Direct fuses the glyph mesh into the scene target; Offscreen writes it into the layer composite before its effect chain — deliberately no separate per-object rgba16Float glyph texture.
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

    /// Live block plus WPE's padding gutter on every side (`padding` × 2). No authored box, headroom multiplier or guessed future string participates.
    static func targetSize(blockSize: CGSize, padding: Double) -> CGSize {
        let gutter = max(padding, 0) * 2
        return CGSize(
            width: max(blockSize.width + gutter, 1).rounded(.up),
            height: max(blockSize.height + gutter, 1).rounded(.up)
        )
    }

    /// Block-local (0,0) is the first baseline at the left edge, so the box runs `+ascender` down to `+ascender − height`. Pre-rotate by `angles.z` because WPE rotates about the object origin while the quad shader rotates about the quad centre.
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

    /// Object origin inside the current exact-size offscreen surface, in top-left y-down pixels.
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
                // Text objects carry no local angles (the schema never parsed one), so rotate the local centre offset with `angles`.
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
            // No scripts: the TEXT object still owns them; copying them here would build a second runtime per script.
        )
    }
}
#endif
