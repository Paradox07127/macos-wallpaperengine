#if !LITE_BUILD
@testable import LiveWallpaper
import Metal
import Testing

@Suite("WPE renderer cache identity")
struct WPERendererOwnershipCharacterizationTests {
    @Test("real PSO and render-target keys include output-affecting options")
    func productionPureIdentityKeys() {
        let basePSO = pipelineKey()
        let psoVariants: Set<WPEMetalPipelineKey> = [
            basePSO,
            pipelineKey(vertex: "wpe_object_quad_vertex"),
            pipelineKey(fragment: "wpe_copy_fragment"),
            pipelineKey(blend: "additive"),
            pipelineKey(color: .rgba16Float),
            pipelineKey(depth: .depth32Float),
        ]
        #expect(psoVariants.count == 6)

        let baseTarget = WPEMetalRenderTargetKey(
            name: "scene",
            width: 1920,
            height: 1080,
            format: "rgba8",
            pixelFormat: .rgba8Unorm_srgb
        )
        let targetVariants: Set<WPEMetalRenderTargetKey> = [
            baseTarget,
            WPEMetalRenderTargetKey(
                name: "scene",
                width: 3840,
                height: 2160,
                format: "rgba8",
                pixelFormat: .rgba8Unorm_srgb
            ),
            WPEMetalRenderTargetKey(
                name: "scene",
                width: 1920,
                height: 1080,
                format: "rgba16f",
                pixelFormat: .rgba16Float
            ),
        ]
        #expect(targetVariants.count == 3)
    }

    private func pipelineKey(
        vertex: String = "wpe_fullscreen_vertex",
        fragment: String = "wpe_generic_fragment",
        blend: String = "normal",
        alphaWritePolicy: WPEMetalAlphaWritePolicy = .all,
        color: MTLPixelFormat = .rgba8Unorm_srgb,
        depth: MTLPixelFormat = .invalid
    ) -> WPEMetalPipelineKey {
        WPEMetalPipelineKey(
            vertexName: vertex,
            fragmentName: fragment,
            blendMode: blend,
            alphaWritePolicy: alphaWritePolicy,
            colorPixelFormat: color,
            depthPixelFormat: depth
        )
    }
}
#endif
