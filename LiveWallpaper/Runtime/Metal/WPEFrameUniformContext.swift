#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Frame-global uniforms resolved once per frame instead of being merged into
/// every pass's `uniformValues` dictionary (which rebuilt ~20 String-keyed
/// entries per pass per frame). Lookup preserves the old merge precedence:
/// these dictionaries were inserted LAST into the merged dict, so for any
/// frame-global name the frame value always beat authored/scripted pass values.
struct WPEFrameUniformContext: Sendable {
    let runtimeUniformValues: [String: WPESceneShaderConstantValue]
    let cameraUniformValues: [String: WPESceneShaderConstantValue]
    /// `g_ModelMatrix`/`g_NormalModelMatrix` per prepared-pass id — object
    /// scoped, so each layer's passes share one CoW dictionary instance.
    let objectUniformValuesByPassID: [String: [String: WPESceneShaderConstantValue]]

    static let empty = WPEFrameUniformContext(
        runtimeUniformValues: [:],
        cameraUniformValues: [:],
        objectUniformValuesByPassID: [:]
    )

    /// Frame-scoped (runtime + camera) value. The two key sets are disjoint,
    /// so the probe order carries no precedence.
    func frameValue(named name: String) -> WPESceneShaderConstantValue? {
        runtimeUniformValues[name] ?? cameraUniformValues[name]
    }

    /// Frame + object value for a specific pass (all three key sets are
    /// disjoint).
    func value(named name: String, passID: String) -> WPESceneShaderConstantValue? {
        if let value = objectUniformValuesByPassID[passID]?[name] { return value }
        return frameValue(named: name)
    }

    func value(lowercasedName: String, passID: String) -> WPESceneShaderConstantValue? {
        guard let canonical = Self.canonicalNameByLowercased[lowercasedName] else { return nil }
        return value(named: canonical, passID: passID)
    }

    /// The frame-global key NAMES are a fixed set, so the case-insensitive
    /// index is process-static. Derived from the real producers (not a literal
    /// list) so it cannot drift when a uniform is added.
    static let canonicalNameByLowercased: [String: String] = {
        var map: [String: String] = [:]
        for key in allCanonicalNames { map[key.lowercased()] = key }
        return map
    }()

    /// Every name `value(named:passID:)` can possibly resolve. Built from the
    /// producers rather than from `canonicalNameByLowercased.values`, which
    /// would drop one side of a case-variant collision.
    static let canonicalNames: Set<String> = Set(allCanonicalNames)

    private static let allCanonicalNames: [String] = {
        let runtime = WPEMetalRuntimeUniforms(
            time: 0,
            daytime: 0,
            brightness: 0,
            pointerPosition: SIMD2<Double>(0, 0),
            audioSpectrumLeft: [],
            audioSpectrumRight: []
        )
        return Array(runtime.uniformValues.keys)
            + Array(WPEMetalCameraUniforms.identity.uniformValues.keys)
            + Array(WPEMetalObjectUniforms.uniformValues(
                origin: SIMD3<Double>(0, 0, 0),
                scale: SIMD3<Double>(1, 1, 1),
                angles: SIMD3<Double>(0, 0, 0)
            ).keys)
    }()
}
#endif
