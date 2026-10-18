#if !LITE_BUILD
import LiveWallpaperProWPE

/// Named structs, not labeled tuples: stored labeled-tuple properties would crash Swift 6.x Sendable synthesis.
struct SceneRendererDiagnostics: Sendable {
    struct ShaderErrors: Sendable {
        struct Entry: Sendable {
            let shader: String
            let reason: String
        }

        let count: Int
        let entries: [Entry]
    }

    struct GPUErrors: Sendable {
        let count: Int
        let last: String?
    }

    let loadDiagnostics: SceneLoadDiagnostic?
    let resolution: WPEResolutionDiagnosticsSnapshot
    let shaderErrors: ShaderErrors
    let gpuErrors: GPUErrors
    var compatibilitySummary = ""
}
#endif
