#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE
import simd

/// Per-object (per-layer) transform uniforms for WPE 2.8 model shaders. Unlike the
/// per-frame `WPEMetalRuntimeUniforms`, `g_ModelMatrix`/`g_NormalModelMatrix` are
/// object-scoped, merged per layer in
/// `WPEPreparedRenderPipeline.addingMetalRuntimeUniforms`.
///
/// 2.8's `generic4`/`chroma4`/`foliage4`/`fur4` vertex shaders switched from
/// `CAST3X3(g_ModelMatrix)` to an explicit inverse-transpose `g_NormalModelMatrix`.
/// Our compiler is fragment-only (never executes those vertex shaders), so these
/// uniforms just let any 2.8 shader that declares them pack a value instead of
/// failing; the transpiler only packs declared uniforms, so identity defaults stay
/// zero-cost for existing 2D/orthographic scenes.
enum WPEMetalObjectUniforms {

    /// `g_ModelMatrix` (16, column-major) + `g_NormalModelMatrix` (9, column-major).
    static func uniformValues(
        origin: SIMD3<Double>,
        scale: SIMD3<Double>,
        angles: SIMD3<Double>
    ) -> [String: WPESceneShaderConstantValue] {
        let model = modelMatrix(origin: origin, scale: scale, angles: angles)
        let normal = normalMatrix(from: model)
        return [
            "g_ModelMatrix": .vector(flattenedColumnMajor(model)),
            "g_NormalModelMatrix": .vector(flattenedColumnMajor(normal))
        ]
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

/// Cross-frame memo for `WPEMetalObjectUniforms.uniformValues`, plus the pass-id map
/// `WPEPreparedRenderPipeline.addingMetalRuntimeUniforms` hands to
/// `WPEFrameUniformContext`. Both matrices are a pure function of
/// `origin`/`scale`/`angles`, so an unmoved layer reuses last frame's dictionary and a
/// fully static scene reuses the whole map — without this it paid two `[Double]`
/// allocations, a matrix inverse per layer, and a dictionary insert per pass, every
/// frame, before the `needsRebuild` early-out.
///
/// Deliberately NOT `Sendable`: one instance per `WPEMetalRenderExecutor`, each
/// confined to its own display's off-main render thread. Non-`Sendable` makes that
/// compiler-checked — the box can't cross isolation domains — so two displays sharing
/// the same immutable pipeline value still get one cache each.
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
