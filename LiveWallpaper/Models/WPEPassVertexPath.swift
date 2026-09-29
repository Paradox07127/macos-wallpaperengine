#if !LITE_BUILD
import Foundation

/// One selection feeds both the PSO and its diagnostic record. These are generated builtin inputs,
/// separate from the original GLSL attribute declarations and the effect owner's transform.
enum WPEPassVertexPath: String, Codable, Sendable {
    case fullscreenQuad, objectQuad, shapeQuad, skewObjectQuad

    static func select(shape: Bool, object: Bool, skew: Bool) -> Self {
        if shape {
            return .shapeQuad
        }
        if object {
            return skew ? .skewObjectQuad : .objectQuad
        }
        return .fullscreenQuad
    }

    var functionOverride: String? {
        switch self {
        case .fullscreenQuad: nil
        case .objectQuad: "wpe_object_quad_vertex"
        case .shapeQuad: "wpe_shape_quad_vertex"
        case .skewObjectQuad: "wpe_skew_object_quad_vertex"
        }
    }

    func functionName(default name: String) -> String {
        functionOverride ?? name
    }

    var requiredVertexBufferIndices: [Int] {
        switch self {
        case .fullscreenQuad: []
        case .objectQuad, .shapeQuad: [1]
        case .skewObjectQuad: [1, 2]
        }
    }

    func traceRecord(defaultFunction name: String) -> [String: Any] {
        [
            "path": rawValue,
            "function": functionName(default: name),
            "inputSupply": "generated-builtin-geometry",
            "authoredVertexExecuted": false,
            "requiredVertexBufferIndices": requiredVertexBufferIndices,
            "bufferValues": "unrecorded",
        ]
    }
}
#endif
