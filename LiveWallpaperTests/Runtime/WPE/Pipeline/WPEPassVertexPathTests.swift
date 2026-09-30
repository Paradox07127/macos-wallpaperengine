#if !LITE_BUILD
@testable import LiveWallpaper
import Testing

@Suite("WPE draw vertex path contract")
struct WPEPassVertexPathTests {
    @Test func geometryAndPipelineSelectionShareOneDecision() {
        #expect(WPEPassVertexPath.select(shape: true, object: true, skew: true) == .shapeQuad)
        #expect(WPEPassVertexPath.select(shape: false, object: true, skew: true) == .skewObjectQuad)
        #expect(WPEPassVertexPath.select(shape: false, object: true, skew: false) == .objectQuad)
        #expect(WPEPassVertexPath.select(shape: false, object: false, skew: true) == .fullscreenQuad)
        #expect(WPEPassVertexPath.fullscreenQuad.functionName(default: "compiled-vs") == "compiled-vs")
        #expect(WPEPassVertexPath.objectQuad.functionName(default: "compiled-vs") == "wpe_object_quad_vertex")
        #expect(WPEPassVertexPath.shapeQuad.requiredVertexBufferIndices == [1])
        #expect(WPEPassVertexPath.skewObjectQuad.requiredVertexBufferIndices == [1, 2])
    }
}
#endif
