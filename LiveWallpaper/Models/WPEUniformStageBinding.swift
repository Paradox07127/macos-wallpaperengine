#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// Only ambiguous cross-stage names need separate values. Ordinary same-definition
/// uniforms continue sharing the existing flat pass values and hot update path.
struct WPEUniformStageBinding: Equatable, Sendable {
    let materialName: String?
    /// Authored/script override, never a default copied from the other stage.
    var value: WPESceneShaderConstantValue?

    static func resolved(_ bindings: [WPEShaderBindingKey: Self], at time: Double,
                         authoredUpdates: [String: WPESceneShaderConstantValue]?) -> [WPEShaderBindingKey: Self] {
        guard !bindings.isEmpty else { return bindings }
        var result = bindings.mapValues { binding in
            Self(materialName: binding.materialName, value: binding.value?.resolved(at: time))
        }
        if let authoredUpdates {
            for (key, binding) in result {
                if let alias = binding.materialName, let value = authoredUpdates[alias] {
                    result[key]?.value = value
                } else if let value = authoredUpdates[key.name] {
                    result[key]?.value = value
                }
            }
        }
        return result
    }

    static func updating(_ bindings: [WPEShaderBindingKey: Self], shaderName: String,
                         value: WPESceneShaderConstantValue?) -> [WPEShaderBindingKey: Self] {
        guard !bindings.isEmpty else { return bindings }
        var result = bindings
        for key in result.keys where key.name == shaderName {
            result[key]?.value = value
        }
        return result
    }
}
#endif
