#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Frame-global uniforms resolved once per frame instead of being merged into
/// every pass's `uniformValues`. Same precedence as the old merge: these were
/// inserted last, so a frame-global name always beats authored/scripted values.
struct WPEFrameUniformContext: Sendable {
    let runtimeUniformValues: [String: WPESceneShaderConstantValue]
    let cameraUniformValues: [String: WPESceneShaderConstantValue]
    /// Direct object/layer matrices per prepared-pass id. Camera-composed MVP
    /// counterparts are resolved from this map plus `cameraUniformValues`.
    let objectUniformValuesByPassID: [String: [String: WPESceneShaderConstantValue]]

    static let empty = WPEFrameUniformContext(
        runtimeUniformValues: [:],
        cameraUniformValues: [:],
        objectUniformValuesByPassID: [:]
    )

    /// Runtime and camera key sets are disjoint.
    func frameValue(named name: String) -> WPESceneShaderConstantValue? {
        runtimeUniformValues[name] ?? cameraUniformValues[name]
    }

    /// All three key sets are disjoint.
    func value(named name: String, passID: String) -> WPESceneShaderConstantValue? {
        if let value = objectUniformValuesByPassID[passID]?[name] { return value }
        if WPEMetalObjectUniforms.cameraComposedUniformNames.contains(name),
           let model = objectUniformValuesByPassID[passID]?["g_ModelMatrix"],
           let viewProjection = cameraUniformValues["g_ViewProjectionMatrix"],
           let value = WPEMetalObjectUniforms.cameraComposedValue(
               named: name,
               modelValue: model,
               viewProjectionValue: viewProjection
           ) {
            return value
        }
        return frameValue(named: name)
    }

    func value(lowercasedName: String, passID: String) -> WPESceneShaderConstantValue? {
        guard let canonical = Self.canonicalNameByLowercased[lowercasedName] else { return nil }
        return value(named: canonical, passID: passID)
    }

    /// Derived from the producers so a new uniform cannot drift off this index.
    static let canonicalNameByLowercased: [String: String] = {
        var map: [String: String] = [:]
        for key in allCanonicalNames { map[key.lowercased()] = key }
        return map
    }()

    /// Built from `allCanonicalNames` rather than the lowercased map, which
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
            + WPEMetalObjectUniforms.cameraComposedUniformNames
    }()
}
#endif
