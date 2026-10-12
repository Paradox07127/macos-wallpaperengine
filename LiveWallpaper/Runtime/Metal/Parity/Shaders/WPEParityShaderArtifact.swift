#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// One WPE shader program compiled by `wpe-shaderc` (HLSL → DXC → Metal Shader Converter).
struct WPEParityShaderArtifact: Sendable {
    struct Stage: Sendable {
        let metallib: Data
        let reflection: WPEStageReflection
        /// Function name inside `metallib`; Metal Shader Converter keeps the HLSL entry point name.
        let functionName: String
    }

    let vertex: Stage
    let fragment: Stage
    /// `nil` unless the program has a WPE geometry shader.
    let geometry: Stage?
}
#endif
