#if !LITE_BUILD
import Foundation
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Import and planning retain authored seeds. The bounded parity VM owns init and per-frame execution.
private struct WPEAuthoredTransformSeedResolver: WPESceneTransformScriptResolving {
    func resolveVec3(script _: String, properties _: [String: WPESceneScriptPropertyValue],
                     seed _: SIMD3<Double>) -> SIMD3<Double>? {
        nil
    }
}

extension WPESceneDocumentParser {
    static func parse(data: Data) throws -> WPESceneDocument {
        try parse(data: data, userValues: [:])
    }

    static func parse(
        data: Data,
        userValues: [String: WallpaperEngineProjectPropertyValue]
    ) throws -> WPESceneDocument {
        try parse(data: data, userValues: userValues, makeTransformScriptResolver: { _, _ in WPEAuthoredTransformSeedResolver() })
    }
}
#endif
