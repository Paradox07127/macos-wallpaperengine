#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE

/// Frozen pre-overlay traversal. Keep independent from production helpers so
/// differential tests and opt-in timing compare against the original algorithm.
/// Reuse access metadata in both paths to isolate traversal/presentation costs.
extension WPEPreparedRenderPipeline {
    func legacyApplyingLayerVisibility(_ visibility: [String: Bool]) -> WPEPreparedRenderPipeline {
        guard !visibility.isEmpty else { return self }
        var didChange = false
        let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
            let resolved = visibility[layer.graphLayer.objectID] ?? layer.graphLayer.visible
            guard resolved != layer.graphLayer.visible else { return layer }
            didChange = true
            return WPEPreparedRenderLayer(
                graphLayer: layer.graphLayer.legacyApplyingVisible(resolved),
                puppetModel: layer.puppetModel,
                passes: layer.passes
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    /// Script layer alpha override (clears authored alpha animation).
    func legacyApplyingLayerAlpha(_ alpha: [String: Double]) -> WPEPreparedRenderPipeline {
        guard !alpha.isEmpty else { return self }
        var didChange = false
        let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
            guard let value = alpha[layer.graphLayer.objectID] else { return layer }
            let geometry = layer.graphLayer.geometry
            guard geometry.alpha != value || geometry.alphaAnimation != nil else { return layer }
            didChange = true
            let graphLayer = layer.graphLayer.legacyApplyingAlpha(value)
            return WPEPreparedRenderLayer(
                graphLayer: graphLayer,
                puppetModel: layer.puppetModel,
                passes: Self.legacyPassesApplyingLayerTint(
                    layer.passes, geometry: graphLayer.geometry,
                    updateColor: false, updateAlpha: true
                )
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    /// Script layer color override (clears authored color animation).
    func legacyApplyingLayerColor(_ color: [String: SIMD3<Double>]) -> WPEPreparedRenderPipeline {
        guard !color.isEmpty else { return self }
        var didChange = false
        let newLayers = layers.map { layer -> WPEPreparedRenderLayer in
            guard let value = color[layer.graphLayer.objectID] else { return layer }
            let geometry = layer.graphLayer.geometry
            guard geometry.color != value || geometry.colorAnimation != nil else { return layer }
            didChange = true
            let graphLayer = layer.graphLayer.legacyApplyingColor(value)
            return WPEPreparedRenderLayer(
                graphLayer: graphLayer,
                puppetModel: layer.puppetModel,
                passes: Self.legacyPassesApplyingLayerTint(
                    layer.passes, geometry: graphLayer.geometry,
                    updateColor: true, updateAlpha: false
                )
            )
        }
        guard didChange else { return self }
        return WPEPreparedRenderPipeline(layers: newLayers)
    }

    /// Solid g_Color is bound from uniformValues, never geometry. Write tint through here or an override freezes at load-time color. Component-wise so alpha cannot clobber authored rgb.
    private static func legacyPassesApplyingLayerTint(
        _ passes: [WPEPreparedRenderPass],
        geometry: WPERenderLayerGeometry,
        updateColor: Bool,
        updateAlpha: Bool
    ) -> [WPEPreparedRenderPass] {
        passes.map { pass in
            guard pass.pass.constants["g_Color"] != nil,
                  Self.legacyConsumesLayerColor(pass.pass.shader) else { return pass }
            let tint = updateColor ? geometry.color * geometry.brightness : nil
            let alpha = updateAlpha ? geometry.alpha : nil
            let existing = pass.uniformValues["g_Color"] ?? pass.pass.constants["g_Color"]
            // An animated g_Color must stay animated: record the claim and let
            // the per-frame resolve apply it on top of the sampled value.
            if case .animated = existing {
                return WPEPreparedRenderPass(
                    pass: pass.pass,
                    shader: pass.shader,
                    textureBindings: pass.textureBindings,
                    comboValues: pass.comboValues,
                    uniformValues: pass.uniformValues,
                    materialUniformNames: pass.materialUniformNames,
                    layerTintOverride: WPELayerTintOverride(
                        color: tint ?? pass.layerTintOverride?.color,
                        alpha: alpha ?? pass.layerTintOverride?.alpha
                    ),
                    reusingAccess: pass.access
                )
            }
            var vector = existing?.vectorValue ?? [1, 1, 1, 1]
            while vector.count < 4 {
                vector.append(1)
            }
            if let tint {
                vector[0] = tint.x
                vector[1] = tint.y
                vector[2] = tint.z
            }
            if let alpha {
                vector[3] = alpha
            }
            var values = pass.uniformValues
            values["g_Color"] = .vector(vector)
            return WPEPreparedRenderPass(
                pass: pass.pass,
                shader: pass.shader,
                textureBindings: pass.textureBindings,
                comboValues: pass.comboValues,
                uniformValues: values,
                materialUniformNames: pass.materialUniformNames,
                layerTintOverride: pass.layerTintOverride,
                reusingAccess: pass.access
            )
        }
    }

    private static func legacyConsumesLayerColor(_ shader: String) -> Bool {
        switch WPEBuiltinShaderName.normalized(shader) {
        case WPEBuiltinShaderKind.solidLayer.rawValue, WPEBuiltinShaderKind.solidColor.rawValue:
            true
        default:
            false
        }
    }
}

private extension WPERenderLayer {
    func legacyApplyingVisible(_ visible: Bool) -> WPERenderLayer {
        WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    /// Overrides the layer's alpha (clearing the authored alpha animation so a
    /// later `resolved(at:)` keeps the script-driven value).
    func legacyApplyingAlpha(_ alpha: Double) -> WPERenderLayer {
        let g = geometry
        let overridden = WPERenderLayerGeometry(
            origin: g.origin,
            scale: g.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: alpha,
            alphaAnimation: nil,
            color: g.color,
            colorAnimation: g.colorAnimation,
            brightness: g.brightness,
            shapePoints: g.shapePoints
        )
        // Live alpha must update groupLocalGeometry (group-buffer draw source).
        let overriddenGroupLocal = groupLocalGeometry.map { gl in
            WPERenderLayerGeometry(
                origin: gl.origin,
                scale: gl.scale,
                angles: gl.angles,
                alignment: gl.alignment,
                size: gl.size,
                puppetMeshCenter: gl.puppetMeshCenter,
                alpha: alpha,
                alphaAnimation: nil,
                color: gl.color,
                colorAnimation: gl.colorAnimation,
                brightness: gl.brightness,
                shapePoints: gl.shapePoints
            )
        }
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: overridden,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: overriddenGroupLocal,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }

    func legacyApplyingColor(_ color: SIMD3<Double>) -> WPERenderLayer {
        let g = geometry
        let overridden = WPERenderLayerGeometry(
            origin: g.origin,
            scale: g.scale,
            angles: g.angles,
            alignment: g.alignment,
            size: g.size,
            puppetMeshCenter: g.puppetMeshCenter,
            alpha: g.alpha,
            alphaAnimation: g.alphaAnimation,
            color: color,
            colorAnimation: nil,
            brightness: g.brightness,
            shapePoints: g.shapePoints
        )
        let overriddenGroupLocal = groupLocalGeometry.map { gl in
            WPERenderLayerGeometry(
                origin: gl.origin,
                scale: gl.scale,
                angles: gl.angles,
                alignment: gl.alignment,
                size: gl.size,
                puppetMeshCenter: gl.puppetMeshCenter,
                alpha: gl.alpha,
                alphaAnimation: gl.alphaAnimation,
                color: color,
                colorAnimation: nil,
                brightness: gl.brightness,
                shapePoints: gl.shapePoints
            )
        }
        return WPERenderLayer(
            objectID: objectID,
            objectName: objectName,
            visible: visible,
            imagePath: imagePath,
            materialPath: materialPath,
            puppetPath: puppetPath,
            parentObjectID: parentObjectID,
            attachment: attachment,
            animationLayers: animationLayers,
            authoredJSON: authoredJSON,
            geometry: overridden,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: overriddenGroupLocal,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }
}
#endif
