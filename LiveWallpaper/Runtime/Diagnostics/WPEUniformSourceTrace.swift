#if !LITE_BUILD && DEBUG
import Foundation

enum WPEUniformValueSource: Equatable {
    case derived(WPEMetalRenderExecutor.DirectUniformPacking)
    case frameContext(String)
    case passValue(String)
    case stagePassValue(WPEShaderBindingKey)
    case passConstant(String)
    case effectTextureProjection(inverse: Bool)
    case effectModelViewProjectionXYW
    case fullscreenVertexMVP
    case unreferencedEngineDeclaration
    case authoredDefault
    case missing

    var traceValue: [String: Any] {
        switch self {
        case let .derived(packing):
            switch packing {
            case .texelSize: ["kind": "scene-derived", "key": "g_TexelSize", "scope": "scene"]
            case .texelSizeHalf: ["kind": "scene-derived", "key": "g_TexelSizeHalf", "scope": "scene"]
            case .screen: ["kind": "scene-derived", "key": "g_Screen", "scope": "scene"]
            case let .textureResolution(slot): texture(slot, property: "resolution")
            case let .textureMipMapInfo(slot): texture(slot, property: "mip-level-count")
            case let .textureRotation(slot): texture(slot, property: "rotation")
            case let .textureTranslation(slot): texture(slot, property: "translation")
            }
        case let .frameContext(key): ["kind": "frame-context", "key": key, "scope": "frame/pass"]
        case let .passValue(key): ["kind": "pass-value", "key": key, "scope": "pass"]
        case let .stagePassValue(key): ["kind": "stage-pass-value", "stage": key.stage.rawValue, "key": key.name, "scope": "pass/stage"]
        case let .passConstant(key): ["kind": "pass-constant", "key": key, "scope": "pass"]
        case let .effectTextureProjection(inverse):
            [
                "kind": "layer-derived",
                "key": inverse
                    ? WPEMetalObjectUniforms.effectTextureProjectionMatrixInverseUniformName
                    : WPEMetalObjectUniforms.effectTextureProjectionMatrixUniformName,
                "scope": "layer",
            ]
        case .effectModelViewProjectionXYW: ["kind": "draw-derived", "key": WPEMetalObjectUniforms.effectModelViewProjectionMatrixUniformName, "scope": "final-ordinary-layer-normalized-position-XYW"]
        case .fullscreenVertexMVP: ["kind": "draw-derived", "key": "g_ModelViewProjectionMatrix", "scope": "fullscreen-clip-geometry"]
        case .unreferencedEngineDeclaration: ["kind": "unreferenced-engine-declaration", "scope": "declared-ABI-only-no-admitted-read"]
        case .authoredDefault: ["kind": "authored-default", "scope": "declaration"]
        case .missing: ["kind": "missing", "scope": "none"]
        }
    }

    private func texture(_ slot: Int, property: String) -> [String: Any] {
        ["kind": "texture-derived", "textureSlot": slot, "property": property, "scope": "binding"]
    }
}

extension WPEMetalRenderExecutor {
    /// Scope the collector to the actual packing call; failed or nested probes cannot leak sources to another draw.
    func withUniformSourceTracing<Value>(
        enabled: Bool = true,
        _ pack: () throws -> Value
    ) rethrows -> (Value, [WPEUniformValueSource]?) {
        let previous = uniformSourceTrace
        uniformSourceTrace = enabled ? [] : nil
        defer { uniformSourceTrace = previous }
        let value = try pack()
        return (value, uniformSourceTrace)
    }

    func recordUniformSource(_ source: WPEUniformValueSource) {
        uniformSourceTrace?.append(source)
    }
}
#endif
