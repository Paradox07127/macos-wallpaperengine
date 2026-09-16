#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Frame-local presentation claims. Dictionaries retain their copy-on-write
/// storage; geometry/parent resolution remains in applyingLayerTransforms.
/// Capture visibility/alpha after their script ticks, before later scripts run.
struct WPEFrameOverlay: Equatable, Sendable {
    var visibility: [String: Bool]
    var alpha: [String: Double]
    var colors: [String: SIMD3<Double>]

    init(
        visibility: [String: Bool] = [:],
        alpha: [String: Double] = [:],
        colors: [String: SIMD3<Double>] = [:]
    ) {
        self.visibility = visibility
        self.alpha = alpha
        self.colors = colors
    }

    var isEmpty: Bool {
        visibility.isEmpty && alpha.isEmpty && colors.isEmpty
    }
}

extension WPEPreparedRenderPipeline {
    /// Apply visibility and both tint components in one layer traversal. Keep
    /// the original layer storage until the first effective change, including
    /// when a nonempty script overlay repeats the current presentation.
    func applyingFrameOverlay(_ overlay: WPEFrameOverlay) -> WPEPreparedRenderPipeline {
        guard !overlay.isEmpty else { return self }
        var changedLayers: [WPEPreparedRenderLayer]?
        for index in layers.indices {
            let layer = layers[index]
            let graph = layer.graphLayer
            let geometry = graph.geometry
            let visible = overlay.visibility[graph.objectID] ?? graph.visible
            // Matching values still claim an authored animation, exactly as
            // the individual alpha/color operations do.
            let alpha = overlay.alpha[graph.objectID].flatMap { value in
                geometry.alpha != value || geometry.alphaAnimation != nil ? value : nil
            }
            let color = overlay.colors[graph.objectID].flatMap { value in
                geometry.color != value || geometry.colorAnimation != nil ? value : nil
            }
            guard visible != graph.visible || alpha != nil || color != nil else { continue }
            let updatedGraph = graph.applyingPresentation(visible: visible, alpha: alpha, color: color)
            let updatedPasses = alpha != nil || color != nil
                ? Self.passesApplyingLayerTint(
                    layer.passes, geometry: updatedGraph.geometry,
                    updateColor: color != nil, updateAlpha: alpha != nil
                )
                : layer.passes
            if changedLayers == nil {
                changedLayers = layers
            }
            changedLayers![index] = WPEPreparedRenderLayer(
                graphLayer: updatedGraph,
                puppetModel: layer.puppetModel,
                passes: updatedPasses
            )
        }
        guard let changedLayers else { return self }
        return WPEPreparedRenderPipeline(layers: changedLayers)
    }

    func applyingLayerVisibility(_ visibility: [String: Bool]) -> WPEPreparedRenderPipeline {
        applyingFrameOverlay(WPEFrameOverlay(visibility: visibility))
    }

    func applyingLayerAlpha(_ alpha: [String: Double]) -> WPEPreparedRenderPipeline {
        applyingFrameOverlay(WPEFrameOverlay(alpha: alpha))
    }

    func applyingLayerColor(_ color: [String: SIMD3<Double>]) -> WPEPreparedRenderPipeline {
        applyingFrameOverlay(WPEFrameOverlay(colors: color))
    }

    /// Solid g_Color is bound from uniformValues, never geometry. Write tint through here or an override freezes at load-time color. Component-wise so alpha cannot clobber authored rgb.
    private static func passesApplyingLayerTint(
        _ passes: [WPEPreparedRenderPass],
        geometry: WPERenderLayerGeometry,
        updateColor: Bool,
        updateAlpha: Bool
    ) -> [WPEPreparedRenderPass] {
        var changedPasses: [WPEPreparedRenderPass]?
        for index in passes.indices {
            let pass = passes[index]
            guard pass.pass.constants["g_Color"] != nil,
                  Self.consumesLayerColor(pass.pass.shader) else { continue }
            let tint = updateColor ? geometry.color * geometry.brightness : nil
            let alpha = updateAlpha ? geometry.alpha : nil
            let existing = pass.uniformValues["g_Color"] ?? pass.pass.constants["g_Color"]
            // An animated g_Color must stay animated: record the claim and let
            // the per-frame resolve apply it on top of the sampled value.
            if case .animated = existing {
                let claim = WPELayerTintOverride(
                    color: tint ?? pass.layerTintOverride?.color,
                    alpha: alpha ?? pass.layerTintOverride?.alpha
                )
                guard claim != pass.layerTintOverride else { continue }
                if changedPasses == nil {
                    changedPasses = passes
                }
                changedPasses![index] = WPEPreparedRenderPass(
                    pass: pass.pass,
                    shader: pass.shader,
                    textureBindings: pass.textureBindings,
                    comboValues: pass.comboValues,
                    uniformValues: pass.uniformValues,
                    materialUniformNames: pass.materialUniformNames,
                    layerTintOverride: claim,
                    reusingAccess: pass.access
                )
                continue
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
            guard pass.uniformValues["g_Color"] != .vector(vector) else { continue }
            var values = pass.uniformValues
            values["g_Color"] = .vector(vector)
            if changedPasses == nil {
                changedPasses = passes
            }
            changedPasses![index] = WPEPreparedRenderPass(
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
        return changedPasses ?? passes
    }
}

private extension WPERenderLayer {
    /// Presentation-only replacement: preserve local transforms, shape points,
    /// parent/group routing and topology, and update group-buffer tint as well.
    func applyingPresentation(
        visible: Bool,
        alpha: Double?,
        color: SIMD3<Double>?
    ) -> WPERenderLayer {
        let changesTint = alpha != nil || color != nil
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
            geometry: changesTint ? geometry.applyingPresentation(alpha: alpha, color: color) : geometry,
            localGeometry: localGeometry,
            compositeA: compositeA,
            compositeB: compositeB,
            localFBOs: localFBOs,
            passes: passes,
            groupRenderTarget: groupRenderTarget,
            groupLocalGeometry: changesTint
                ? groupLocalGeometry?.applyingPresentation(alpha: alpha, color: color)
                : groupLocalGeometry,
            groupCompositeSource: groupCompositeSource,
            parallaxDepth: parallaxDepth,
            sortIndex: sortIndex
        )
    }
}

private extension WPERenderLayerGeometry {
    func applyingPresentation(alpha: Double?, color: SIMD3<Double>?) -> WPERenderLayerGeometry {
        WPERenderLayerGeometry(
            origin: origin,
            scale: scale,
            angles: angles,
            alignment: alignment,
            size: size,
            puppetMeshCenter: puppetMeshCenter,
            alpha: alpha ?? self.alpha,
            alphaAnimation: alpha == nil ? alphaAnimation : nil,
            color: color ?? self.color,
            colorAnimation: color == nil ? colorAnimation : nil,
            brightness: brightness,
            shapePoints: shapePoints
        )
    }
}
#endif
