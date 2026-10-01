#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import simd

/// A compiled stage pair is usable only when this draw can supply its declared inputs.
/// Declarations are conservative: unused required engine declarations may still reject admission.
enum WPEAuthoredVertexRejection: Equatable {
    case disabledForIsolation, geometryUnavailable, pipelineNotPrewarmed, stageUnavailable(String)
    case requiredUniformMissing(String), invalidMatrix(String), unverifiedEffectProjection3D
    case unverifiedFullscreenDepth, unverifiedFullscreenMVP, unverifiedEffectPositionContext

    var reason: String {
        switch self {
        case .disabledForIsolation: "authored-stage-disabled-for-isolation"
        case .geometryUnavailable: "authored-fullscreen-geometry-unavailable"
        case .pipelineNotPrewarmed: "authored-pipeline-not-prewarmed"
        case let .stageUnavailable(reason): reason
        case let .requiredUniformMissing(name): "required-vertex-uniform-missing:\(name)"
        case let .invalidMatrix(name): "invalid-vertex-matrix:\(name)"
        case .unverifiedFullscreenDepth: "fullscreen-depth-projection-unverified"
        case .unverifiedFullscreenMVP: "fullscreen-MVP-non-position-use-unverified"
        case .unverifiedEffectPositionContext: "effect-position-context-unverified"
        case .unverifiedEffectProjection3D: "effect-projection-3D-unverified"
        }
    }
}

extension WPEMetalRenderExecutor {
    func authoredVertexResolvedInputRejection(for pass: WPEPreparedRenderPass, result: WPEShaderCompileResult,
                                              textures: WPEMetalTextureSlotTable) -> WPEAuthoredVertexRejection? {
        guard let vertex = result.vertexStage else { return .stageUnavailable("authored-stage-unavailable") }
        let plans = uniformPlans(for: pass, layout: vertex.uniformLayout, stage: .vertex)
        for (index, uniform) in vertex.uniformLayout.enumerated()
            where plans[index].directPacking != nil || plans[index].textureResolutionSlot != nil
            || plans[index].textureRotationSlot != nil || plans[index].textureTranslationSlot != nil {
            let value = resolvedUniformValue(plan: plans[index], pass: pass, frame: frameUniformContext,
                                             texturesBySlot: textures, effectTextureProjection: nil)
            if value == nil {
                return .requiredUniformMissing(uniform.name)
            }
        }
        return nil
    }

    func authoredVertexRejection(for pass: WPEPreparedRenderPass, result: WPEShaderCompileResult,
                                 layer: WPERenderLayer, frameState: WPEMetalFrameState,
                                 effectTextureProjection: () -> simd_double4x4?) -> WPEAuthoredVertexRejection? {
        guard let vertex = result.vertexStage else { return .stageUnavailable("authored-stage-unavailable") }
        guard pass.pass.depthTest.lowercased() == "disabled", pass.pass.depthWrite.lowercased() == "disabled" else {
            return .unverifiedFullscreenDepth
        }
        let plans = uniformPlans(for: pass, layout: vertex.uniformLayout, stage: .vertex)
        for (index, uniform) in vertex.uniformLayout.enumerated() {
            if uniform.name == "g_ModelViewProjectionMatrix", uniform.materialName == nil {
                guard uniform.glslType == "mat4", uniform.arrayLength == nil else { return .invalidMatrix(uniform.name) }
                guard result.fullscreenMVPPositionOnly else { return .unverifiedFullscreenMVP }
                continue
            }
            if uniform.name == WPEMetalObjectUniforms.effectModelViewProjectionMatrixUniformName {
                guard uniform.materialName == nil else { return .unverifiedEffectPositionContext }
                guard uniform.glslType == "mat4", uniform.arrayLength == nil else { return .invalidMatrix(uniform.name) }
                guard result.fullscreenMVPPositionOnly else { return .unverifiedFullscreenMVP }
                guard !layer.isUtilityModelLayer else { return .geometryUnavailable }
                // The fresh oracle contract is the final ordinary layer effect.
                // Named FBOs, intermediate effects and inherited/group geometry
                // have different Windows position/matrix owners.
                guard layer.parentObjectID == nil, layer.groupRenderTarget == nil,
                      case .layerComposite = pass.pass.target,
                      layer.passes.last(where: {
                          if case .layerComposite = $0.target {
                              return true
                          }
                          return false
                      })?.id == pass.pass.id else {
                    return .unverifiedEffectPositionContext
                }
            }
            if plans[index].effectTextureProjectionInverse != nil {
                guard !frameState.cameraUniforms.usesPerspectiveProjection,
                      abs(frameState.cameraUniforms.sceneMotion.angles.x) < 0.000001,
                      abs(frameState.cameraUniforms.sceneMotion.angles.y) < 0.000001,
                      abs(layer.geometry.angles.x) < 0.000001, abs(layer.geometry.angles.y) < 0.000001 else {
                    return .unverifiedEffectProjection3D
                }
                guard let matrix = effectTextureProjection(), matrix.columns.0.allFinite,
                      matrix.columns.1.allFinite, matrix.columns.2.allFinite, matrix.columns.3.allFinite,
                      simd_determinant(matrix).isFinite, simd_determinant(matrix) != 0,
                      matrix.inverse.columns.0.allFinite, matrix.inverse.columns.1.allFinite,
                      matrix.inverse.columns.2.allFinite, matrix.inverse.columns.3.allFinite else { return .invalidMatrix(uniform.name) }
                continue
            }
            if uniform.materialName == nil, uniform.name.hasSuffix("Inverse"),
               WPEFrameUniformContext.canonicalNames.contains(uniform.name) {
                let base = String(uniform.name.dropLast("Inverse".count))
                guard let values = frameUniformContext.value(named: base, passID: pass.id)?.vectorValue,
                      let matrix = WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: values),
                      simd_determinant(matrix).isFinite, simd_determinant(matrix) != 0 else {
                    return .invalidMatrix(uniform.name)
                }
            }

            // A texture-derived declaration is checked after actual slot resolution.
            if plans[index].directPacking != nil {
                continue
            }
            let value = resolvedUniformValue(plan: plans[index], pass: pass, frame: frameUniformContext,
                                             texturesBySlot: nil, effectTextureProjection: nil)
            if value == nil, uniform.materialName == nil,
               uniform.name.hasPrefix("g_Model") || uniform.name.hasPrefix("g_View")
               || uniform.name.hasPrefix("g_Projection") || WPEFrameUniformContext.canonicalNames.contains(uniform.name) {
                return .requiredUniformMissing(uniform.name)
            }
        }
        return nil
    }
}

private extension SIMD4<Double> {
    var allFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite && w.isFinite
    }
}
#endif
