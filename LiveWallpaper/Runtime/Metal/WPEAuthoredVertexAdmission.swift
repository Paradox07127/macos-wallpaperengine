#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import simd

/// A compiled stage pair is usable only when this draw can supply its declared inputs.
/// Declarations are conservative: unused required engine declarations may still reject admission.
enum WPEAuthoredVertexRejection: Equatable {
    case disabledForIsolation, geometryUnavailable, pipelineNotPrewarmed, stageUnavailable(String)
    case requiredUniformMissing(String), invalidMatrix(String), unverifiedEffectProjection3D
    case unverifiedFullscreenDepth, unverifiedFullscreenMVP, unverifiedEffectPositionContext, unverifiedObjectQuadSpace
    case unverifiedInheritedObjectMatrix

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
        case .unverifiedObjectQuadSpace: "object-quad-position-space-unverified"
        case .unverifiedInheritedObjectMatrix: "inherited-object-matrix-producer-unverified"
        case .unverifiedEffectPositionContext: "effect-position-context-unverified"
        case .unverifiedEffectProjection3D: "effect-projection-3D-unverified"
        }
    }
}

extension WPEMetalRenderExecutor {
    static func canSupplyAuthoredObjectQuad(layer: WPERenderLayer, camera: WPEMetalCameraUniforms) -> Bool {
        let geometry = layer.geometry
        guard !layer.isUtilityModelLayer, layer.attachment == nil, layer.groupRenderTarget == nil,
              layer.parentObjectID == nil || layer.localGeometry != nil,
              layer.puppetPath == nil, geometry.alignment == .center,
              let size = geometry.size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              Float(size.width / 2).isFinite, Float(size.height / 2).isFinite,
              geometry.origin.x.isFinite, geometry.origin.y.isFinite, abs(geometry.origin.z) < 0.000001,
              // centeredOrigin reads 0...1 as a scene fraction; g_ModelMatrix would take it as pixels.
              !(0 ... 1).contains(geometry.origin.x), !(0 ... 1).contains(geometry.origin.y),
              geometry.scale.x.isFinite, geometry.scale.y.isFinite, geometry.scale.x > 0, geometry.scale.y > 0,
              geometry.angles.z.isFinite, abs(geometry.angles.x) < 0.000001, abs(geometry.angles.y) < 0.000001,
              camera.hasCapturedFlatDrawProjection, !camera.usesPerspectiveProjection,
              !camera.usesObjectPerspective(objectID: layer.id),
              abs(camera.sceneMotion.angles.x) < 0.000001, abs(camera.sceneMotion.angles.y) < 0.000001 else { return false }
        if let points = geometry.shapePoints {
            guard points.count == 4, points.allSatisfy({
                Float(($0.x - 0.5) * size.width).isFinite && Float((0.5 - $0.y) * size.height).isFinite
            }) else { return false }
        }
        return true
    }

    /// Captured WPE POSITION/TEXCOORD inputs, expanded in captured Windows triangle-list order.
    static func authoredObjectQuadInputs(layer: WPERenderLayer) -> [SIMD4<Float>] {
        guard let size = layer.geometry.size else { return [] }
        let points = layer.geometry.shapePoints ?? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        guard points.count == 4 else { return [] }
        return [0, 2, 1, 0, 3, 2].map { index in
            let point = points[index]
            return SIMD4(Float((point.x - 0.5) * size.width), Float((0.5 - point.y) * size.height),
                         Float(point.x), Float(point.y))
        }
    }

    /// The fresh oracle scope is a flat root, identity camera motion and no
    /// nonzero mouse term. Dynamic cursor/camera and inherited parallax stay guarded.
    func applyingAuthoredRootParallaxDrawProjection(
        to context: inout WPEFrameUniformContext, pipeline: WPEPreparedRenderPipeline,
        camera: WPEMetalCameraUniforms, parallax: WPECameraParallaxFrame, sceneSize: CGSize
    ) {
        guard parallax.amount != 0, camera.sceneMotion == .identity, sceneSize == camera.renderSize,
              parallax.influence == 0 || parallax.smoothed == .zero else { return }
        for prepared in pipeline.layers {
            let layer = prepared.graphLayer
            guard layer.parentObjectID == nil, layer.parallaxDepth != .zero,
                  Self.canSupplyAuthoredObjectQuad(layer: layer, camera: camera) else { continue }
            let center = Self.centeredOrigin(of: layer.geometry, sceneSize: sceneSize)
            let offset = parallax.pixelOffset(objectCenter: parallaxObjectCenter(for: layer, fallback: center),
                                              depth: layer.parallaxDepth, sceneSize: sceneSize)
            guard offset.x.isFinite, offset.y.isFinite,
                  let view = WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: camera.shaderDrawViewProjectionMatrix(objectID: layer.id)) else { continue }
            var translation = matrix_identity_double4x4
            translation.columns.3 = SIMD4(Double(offset.x), Double(offset.y), 0, 1)
            let values = WPEMetalObjectUniforms.flattenedColumnMajor(view * translation)
            for pass in prepared.passes where pass.shader?.isBuiltin == false {
                // The per-pass context also feeds fallback fragments, so only an admissible authored quad may see the offset MVP.
                guard case .scene = pass.pass.target, let result = authoredShaderResultByPassID[pass.id],
                      result.vertexStage?.execution == .authoredObjectQuad,
                      !result.uniformLayout.contains(where: {
                          $0.materialName == nil && ($0.name.hasPrefix("g_Model") || $0.name.hasPrefix("g_Layer") || $0.name == "g_NormalModelMatrix")
                      }) else { continue }
                context.drawViewProjectionMatrixByPassID[pass.id] = .vector(values)
                context.parallaxDrawMatrixPassIDs.insert(pass.id)
            }
        }
    }

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
        if vertex.execution == .authoredObjectQuad {
            guard case .scene = pass.pass.target,
                  Self.canSupplyAuthoredObjectQuad(layer: layer, camera: frameState.cameraUniforms) else { return .unverifiedObjectQuadSpace }
            if layer.parallaxDepth != .zero, frameState.cameraParallax.amount != 0 {
                guard frameUniformContext.parallaxDrawMatrixPassIDs.contains(pass.id) else { return .unverifiedObjectQuadSpace }
                // Only VS draw MVP was measured. Fragment model/layer inputs
                // (including its MVP) have no captured parallax owner yet.
                guard !result.uniformLayout.contains(where: {
                    $0.materialName == nil && ($0.name.hasPrefix("g_Model") || $0.name.hasPrefix("g_Layer") || $0.name == "g_NormalModelMatrix")
                }) else { return .unverifiedObjectQuadSpace }
            }
            if layer.parentObjectID != nil {
                guard frameUniformContext.affineModelMatrixPassIDs.contains(pass.id),
                      let values = frameUniformContext.value(named: "g_ModelMatrix", passID: pass.id)?.vectorValue,
                      let model = WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: values),
                      abs(model.columns.0.z) < 0.000001, abs(model.columns.1.z) < 0.000001,
                      abs(model.columns.2.x) < 0.000001, abs(model.columns.2.y) < 0.000001,
                      abs(model.columns.3.z) < 0.000001,
                      model.columns.0.x * model.columns.1.y - model.columns.1.x * model.columns.0.y > 0 else {
                    return .unverifiedInheritedObjectMatrix
                }
            }
        }
        let plans = uniformPlans(for: pass, layout: vertex.uniformLayout, stage: .vertex)
        for (index, uniform) in vertex.uniformLayout.enumerated() {
            if vertex.execution == .authoredObjectQuad, uniform.materialName == nil,
               frameUniformContext.parallaxDrawMatrixPassIDs.contains(pass.id),
               (uniform.name.hasPrefix("g_Model") && !["g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse"].contains(uniform.name))
               || uniform.name.hasPrefix("g_Layer") || uniform.name == "g_NormalModelMatrix" {
                // The measured displacement belongs to draw MVP, not a claim
                // about other model/layer uniforms under active parallax.
                return .unverifiedObjectQuadSpace
            }
            if ["g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse"].contains(uniform.name), uniform.materialName == nil {
                guard uniform.glslType == "mat4", uniform.arrayLength == nil else { return .invalidMatrix(uniform.name) }
                if vertex.execution == .authoredFullscreen {
                    guard result.fullscreenMVPPositionOnly else { return .unverifiedFullscreenMVP }
                    continue
                }
                guard let values = frameUniformContext.value(named: uniform.name, passID: pass.id)?.vectorValue,
                      WPEMetalObjectUniforms.matrix4x4(fromColumnMajor: values) != nil else { return .invalidMatrix(uniform.name) }
            }
            if vertex.execution == .authoredObjectQuad, uniform.name.hasPrefix("g_Effect") {
                return .unverifiedObjectQuadSpace
            }
            if vertex.execution == .authoredObjectQuad, uniform.materialName == nil,
               !frameState.cameraUniforms.hasCapturedOrthographicShaderGlobals,
               uniform.name.hasPrefix("g_View") || uniform.name == "g_EyePosition" {
                // A measured flat draw MVP does not establish global camera uniforms
                // when a perspective override camera exists.
                return .unverifiedObjectQuadSpace
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
                      !frameState.cameraUniforms.usesObjectPerspective(objectID: layer.id),
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
            if value == nil, vertex.execution == .authoredObjectQuad, uniform.materialName == nil, uniform.name.hasPrefix("g_") {
                return .requiredUniformMissing(uniform.name)
            }
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
