#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import simd

/// Per-object (per-layer) transform uniforms for WPE 2.8 model shaders.
///
/// Model, inverse-model, layer-model, and normal matrices are *object*-scoped,
/// so unlike the per-frame `WPEMetalRuntimeUniforms` they are merged per layer in
/// `WPEPreparedRenderPipeline.addingMetalRuntimeUniforms`.
///
/// 2.8's `generic4`/`chroma4`/`foliage4`/`fur4` vertex shaders switched from
/// `CAST3X3(g_ModelMatrix)` to an explicit inverse-transpose normal matrix
/// (`g_NormalModelMatrix`). Our custom-shader compiler is fragment-only today
/// (it never executes those vertex shaders), so these uniforms exist so any
/// 2.8 shader that *declares* them can pack a value instead of failing; the
/// transpiler only packs declared uniforms, so identity defaults stay zero-cost
/// for the existing 2D/orthographic scenes.
enum WPEMetalObjectUniforms {

    static let modelViewProjectionMatrixUniformName = "g_ModelViewProjectionMatrix"
    static let modelViewProjectionMatrixInverseUniformName = "g_ModelViewProjectionMatrixInverse"

    /// Camera/object counterparts are resolved by `WPEFrameUniformContext`,
    /// where both the pass-scoped model matrix and current camera VP are
    /// available. Keeping these names here makes the producer the ABI source of
    /// truth without baking a camera snapshot into the cross-frame object cache.
    static let cameraComposedUniformNames = [
        modelViewProjectionMatrixUniformName,
        modelViewProjectionMatrixInverseUniformName
    ]

    /// Object/layer matrices are 16-value column-major arrays;
    /// `g_NormalModelMatrix` is a 9-value column-major array.
    static func uniformValues(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>
    ) -> [String: WPESceneShaderConstantValue] {
        let model = modelMatrix(origin: origin, scale: scale, angles: angles)
        let modelInverse = safeInverse(model)
        let normal = normalMatrix(from: model)
        return [
            "g_ModelMatrix": .vector(flattenedColumnMajor(model)),
            "g_ModelMatrixInverse": .vector(flattenedColumnMajor(modelInverse)),
            // Official docs define this as the layer object's local↔world
            // matrix. This producer's input is exactly that layer geometry.
            "g_LayerModelMatrix": .vector(flattenedColumnMajor(model)),
            "g_NormalModelMatrix": .vector(flattenedColumnMajor(normal))
        ]
    }

    /// Strict column-vector counterpart of the existing producers: `VP · M`.
    /// This is the same multiplication order used by the scene-model Metal
    /// vertex path. The inverse name gets the mathematical inverse of that
    /// product, with the same finite identity fallback as other inverse ABIs.
    static func cameraComposedValue(
        named name: String,
        modelValue: WPESceneShaderConstantValue,
        viewProjectionValue: WPESceneShaderConstantValue
    ) -> WPESceneShaderConstantValue? {
        guard cameraComposedUniformNames.contains(name),
              let modelValues = modelValue.vectorValue,
              let viewProjectionValues = viewProjectionValue.vectorValue,
              let model = matrix4x4(fromColumnMajor: modelValues),
              let viewProjection = matrix4x4(fromColumnMajor: viewProjectionValues) else {
            return nil
        }
        let modelViewProjection = viewProjection * model
        let value = name == modelViewProjectionMatrixInverseUniformName
            ? safeInverse(modelViewProjection)
            : modelViewProjection
        return .vector(flattenedColumnMajor(value))
    }

    /// `M = T(origin) · Rz(angles.z) · Ry(angles.y) · Rx(angles.x) · S(scale)`.
    static func modelMatrix(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>
    ) -> simd_double4x4 {
        let rotation = rotationZ(angles.z) * rotationY(angles.y) * rotationX(angles.x)
        return translation(origin) * rotation * scaling(scale)
    }

    /// `transpose(inverse(mat3(model)))`. Falls back to identity when the
    /// upper-left 3×3 is (near-)singular — a zero/degenerate scale would
    /// otherwise produce NaN/Inf in the inverse.
    static func normalMatrix(from model: simd_double4x4) -> simd_double3x3 {
        let upper = simd_double3x3(
            SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
            SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
            SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z)
        )
        guard abs(simd_determinant(upper)) >= 1e-8 else {
            return matrix_identity_double3x3
        }
        return upper.inverse.transpose
    }

    /// A singular matrix has no inverse. Identity is the finite fail-closed
    /// value already used by the normal-matrix producer; malformed/non-finite
    /// inverse results take the same path.
    static func safeInverse(_ matrix: simd_double4x4) -> simd_double4x4 {
        let determinant = simd_determinant(matrix)
        guard determinant.isFinite, determinant != 0 else {
            return matrix_identity_double4x4
        }
        let inverse = matrix.inverse
        guard flattenedColumnMajor(inverse).allSatisfy(\.isFinite) else {
            return matrix_identity_double4x4
        }
        return inverse
    }

    static func matrix4x4(fromColumnMajor values: [Double]) -> simd_double4x4? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        return simd_double4x4(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        )
    }

    static func flattenedColumnMajor(_ m: simd_double4x4) -> [Double] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z, m.columns.0.w,
            m.columns.1.x, m.columns.1.y, m.columns.1.z, m.columns.1.w,
            m.columns.2.x, m.columns.2.y, m.columns.2.z, m.columns.2.w,
            m.columns.3.x, m.columns.3.y, m.columns.3.z, m.columns.3.w
        ]
    }

    static func flattenedColumnMajor(_ m: simd_double3x3) -> [Double] {
        [
            m.columns.0.x, m.columns.0.y, m.columns.0.z,
            m.columns.1.x, m.columns.1.y, m.columns.1.z,
            m.columns.2.x, m.columns.2.y, m.columns.2.z
        ]
    }

    // MARK: - Column-major simd builders

    private static func translation(_ t: SIMD3<Double>) -> simd_double4x4 {
        var m = matrix_identity_double4x4
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    private static func scaling(_ s: SIMD3<Double>) -> simd_double4x4 {
        simd_double4x4(diagonal: SIMD4(s.x, s.y, s.z, 1))
    }

    private static func rotationX(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    private static func rotationY(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(
            SIMD4(c, 0, -s, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0),
            SIMD4(0, 0, 0, 1)
        )
    }

    private static func rotationZ(_ a: Double) -> simd_double4x4 {
        let c = cos(a), s = sin(a)
        return simd_double4x4(
            SIMD4(c, s, 0, 0),
            SIMD4(-s, c, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(0, 0, 0, 1)
        )
    }
}

/// Cross-frame memo for `WPEMetalObjectUniforms.uniformValues`, plus the
/// pass-id map `WPEPreparedRenderPipeline.addingMetalRuntimeUniforms` hands to
/// `WPEFrameUniformContext`.
///
/// Both matrices are a pure function of `origin`/`scale`/`angles` (see
/// `uniformValues` above — it reads nothing else), so a layer that did not move
/// reuses last frame's dictionary, and a scene where no layer moved reuses the
/// whole map. Without this a fully static scene still paid two `[Double]`
/// allocations plus a matrix inverse per layer and a dictionary insert per
/// pass, every frame, *before* the `needsRebuild` early-out.
///
/// Deliberately NOT `Sendable`: one instance per `WPEMetalRenderExecutor`, and
/// each executor is confined to its own display's off-main render thread. Being
/// non-`Sendable` is what makes that compiler-checked — the box cannot be
/// captured into another isolation domain, and nothing here is global or
/// static, so two displays sharing the same immutable pipeline value still get
/// one cache each.
final class WPEObjectUniformCache {

    /// The complete input of `WPEMetalObjectUniforms.uniformValues`.
    private struct TransformKey: Equatable {
        let origin: SIMD3<Double>
        let scale: SIMD3<Double>
        let angles: SIMD3<Double>
    }

    /// Ordered mirror of the layer array the map was built from.
    private struct LayerEntry {
        let layerID: String
        let transform: TransformKey
        let passIDs: [String]
    }

    private var entries: [LayerEntry] = []
    /// Memo consulted when the map has to be rebuilt (a layer moved, or the
    /// layer set changed). Keyed by layer id, but the transform is re-checked
    /// on every hit — so a recycled id can only ever hit on a transform that
    /// produces the identical matrices.
    private var memoByLayerID: [String: (transform: TransformKey, values: [String: WPESceneShaderConstantValue])] = [:]
    private var valuesByPassID: [String: [String: WPESceneShaderConstantValue]] = [:]

    /// Test seam: how many times the matrices were actually built.
    private(set) var computeCount = 0
    /// Test seam: how many times the pass-id map was rebuilt.
    private(set) var mapRebuildCount = 0

    func resetCounters() {
        computeCount = 0
        mapRebuildCount = 0
    }

    func objectUniformValuesByPassID(
        for layers: [WPEPreparedRenderLayer]
    ) -> [String: [String: WPESceneShaderConstantValue]] {
        if isUnchanged(layers) { return valuesByPassID }
        mapRebuildCount += 1

        var nextEntries: [LayerEntry] = []
        nextEntries.reserveCapacity(layers.count)
        var nextMemo: [String: (transform: TransformKey, values: [String: WPESceneShaderConstantValue])] = [:]
        nextMemo.reserveCapacity(layers.count)
        var nextValuesByPassID: [String: [String: WPESceneShaderConstantValue]] = [:]
        nextValuesByPassID.reserveCapacity(valuesByPassID.count)

        for layer in layers {
            let geometry = layer.graphLayer.geometry
            let key = TransformKey(
                origin: geometry.origin, scale: geometry.scale, angles: geometry.angles
            )
            let values: [String: WPESceneShaderConstantValue]
            if let memo = memoByLayerID[layer.id], memo.transform == key {
                values = memo.values
            } else {
                computeCount += 1
                values = WPEMetalObjectUniforms.uniformValues(
                    origin: key.origin, scale: key.scale, angles: key.angles
                )
            }
            var passIDs: [String] = []
            passIDs.reserveCapacity(layer.passes.count)
            for pass in layer.passes {
                // Last writer wins on a duplicated pass id, matching the
                // pre-cache loop this replaced.
                nextValuesByPassID[pass.pass.id] = values
                passIDs.append(pass.pass.id)
            }
            nextEntries.append(
                LayerEntry(layerID: layer.id, transform: key, passIDs: passIDs)
            )
            nextMemo[layer.id] = (key, values)
        }

        entries = nextEntries
        // Replaced, not merged: a layer that left the pipeline (reload, a
        // createLayer state going invisible) must not keep its slot alive.
        memoByLayerID = nextMemo
        valuesByPassID = nextValuesByPassID
        return valuesByPassID
    }

    /// Layer identity, transform and pass ids all have to match in order, so a
    /// runtime insertion or a reload can never serve a stale map.
    private func isUnchanged(_ layers: [WPEPreparedRenderLayer]) -> Bool {
        guard entries.count == layers.count else { return false }
        for (entry, layer) in zip(entries, layers) {
            guard entry.layerID == layer.id else { return false }
            let geometry = layer.graphLayer.geometry
            guard entry.transform.origin == geometry.origin,
                  entry.transform.scale == geometry.scale,
                  entry.transform.angles == geometry.angles else { return false }
            guard entry.passIDs.count == layer.passes.count else { return false }
            for (cachedID, pass) in zip(entry.passIDs, layer.passes) where cachedID != pass.pass.id {
                return false
            }
        }
        return true
    }
}
#endif
