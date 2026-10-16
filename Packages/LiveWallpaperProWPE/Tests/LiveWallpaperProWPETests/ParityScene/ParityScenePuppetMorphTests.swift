import Foundation
@testable import LiveWallpaperProWPE
import Testing

/// 140206ae0.c:333-343: inside the skinned block, mesh0's float4 position (format 0x10000) adds MORPHING.
@Suite("Puppet MORPHING combo")
struct ParityScenePuppetMorphTests {
    private func puppet(format: UInt32) -> WPEParityScenePuppet {
        WPEParityScenePuppet(vertices: [], indices: [], boneCount: 1, skinned: true,
                             vertexStream: WPEPuppetVertexStream(data: Data(), layout: WPEPuppetVertexLayout(format: format)))
    }

    @Test("Format 0x181000e morphs")
    func vec4PositionAddsMorphing() {
        #expect(puppet(format: 0x181000E).skinningCombos["MORPHING"] == 1)
    }

    @Test("A float3 position does not morph")
    func vec3PositionHasNoMorphing() {
        #expect(puppet(format: 0x180000F).skinningCombos["MORPHING"] == nil)
    }
}
