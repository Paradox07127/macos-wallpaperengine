#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Testing

@Suite("WPE authored stage interface")
struct WPEShaderInterfaceTests {
    @Test func stageIdentityRetainsSameNameWithDifferentTypes() throws {
        let interface = WPEShaderInterfaceParser.parse(
            vertex: "uniform mat4 shared; attribute vec3 a_Position; varying vec2 v_UV;",
            fragment: "uniform vec2 shared; varying vec2 v_UV; uniform sampler2D g_Texture7;"
        )
        #expect(interface.issues.isEmpty)
        #expect(interface.variable(.init(stage: .vertex, name: "shared"))?.glslType == "mat4")
        #expect(interface.variable(.init(stage: .fragment, name: "shared"))?.glslType == "vec2")
        #expect(interface.variables(stage: .fragment, kind: .texture).map(\.key.name) == ["g_Texture7"])
        #expect(try JSONDecoder().decode(WPEShaderInterface.self, from: JSONEncoder().encode(interface)) == interface)
    }

    @Test func scannerIgnoresCommentsBodiesAndInactiveBranches() {
        let source = """
        /* varying vec4 v_Fake; #if 0 */
        #define ENABLED 0
        #if ENABLED
        varying vec3 v_UV;
        #else
        varying vec2 v_UV;
        #endif
        uniform vec4 colors[2], tail;
        void helper(in vec2 input) { vec2 local = input; }
        void main() { /* uniform mat4 hidden; */ gl_Position = vec4(1.0); }
        """
        let interface = WPEShaderInterfaceParser.parse(vertex: source, fragment: "varying vec2 v_UV;")
        #expect(interface.issues.isEmpty)
        #expect(interface.variables.count == 4)
        #expect(interface.variable(.init(stage: .vertex, name: "colors"))?.arrayDimensions == ["2"])
        #expect(interface.variable(.init(stage: .vertex, name: "tail"))?.arrayDimensions == [])
    }

    @Test func linksLocationsAndReportsShapeInterpolationAndMissingOutput() {
        let interface = WPEShaderInterfaceParser.parse(
            vertex: "layout(location = 3) flat out vec2 producer[2]; varying vec4 mismatch;",
            fragment: "layout(location = 3) in vec2 renamed[3]; varying vec2 mismatch; varying float absent;"
        )
        #expect(interface.issues.filter { $0.code == .varyingTypeMismatch }.map(\.name) == ["renamed", "mismatch"])
        #expect(interface.issues.filter { $0.code == .varyingInterpolationMismatch }.map(\.name) == ["renamed"])
        #expect(interface.issues.filter { $0.code == .missingVertexOutput }.map(\.name) == ["absent"])
    }

    @Test func incompleteDeclarationsArePreservedOrDiagnosed() {
        let interface = WPEShaderInterfaceParser.parse(
            vertex: "uniform mat4 matrices[COUNT][2]; uniform float x; uniform vec2 x; uniform Broken { vec4 value; } block;",
            fragment: "uniform float unsized[]; uniform float malformed[;"
        )
        #expect(interface.variable(.init(stage: .vertex, name: "matrices"))?.arrayDimensions == ["COUNT", "2"])
        #expect(interface.issues.filter { $0.code == .unresolvedArrayExtent }.count == 2)
        #expect(interface.issues.filter { $0.code == .duplicateDeclaration }.map(\.name) == ["x"])
        #expect(interface.issues.filter { $0.code == .unsupportedDeclaration }.count == 2)
    }

    @Test func unknownTypeAndLayoutStayLimitedAndCRLFIsNormalized() {
        let interface = WPEShaderInterfaceParser.parse(
            vertex: "layout(location = -1) out Unknown value;\r\nuniform mat4 matrices;",
            fragment: "in Unknown value;"
        )
        #expect(interface.hasVertexSource && interface.hasFragmentSource)
        #expect(interface.issues.filter { $0.code == .unsupportedDeclaration }.count == 2)
        #expect(interface.variable(.init(stage: .vertex, name: "matrices"))?.glslType == "mat4")
    }

    #if DEBUG
    @Test func coverageSeparatesDefaultsHostGapsAndAuthoredStageExecution() {
        let interface = WPEShaderInterfaceParser.parse(
            vertex: "uniform mat4 g_EffectTextureProjectionMatrixInverse; varying vec2 v_UV;",
            fragment: "uniform float u_Amount; varying vec2 v_UV; uniform float mystery;"
        )
        let layout = [
            slot("g_EffectTextureProjectionMatrixInverse", "mat4", 0, 4),
            slot("u_Amount", "float", 4, 1), slot("mystery", "float", 5, 1),
        ]
        let coverage = WPEShaderSemanticCoverage.observedCustomDraw(
            passID: "layer.effect.0", shaderName: "fixture", sourceClassification: "official-source",
            sourceFingerprint: "pin", interface: interface, layout: layout,
            sources: [.missing, .authoredDefault, .missing]
        )
        #expect(coverage.entries.contains { $0.feature == .authoredVertexExecution && $0.status == .missing })
        #expect(coverage.entries.contains { $0.feature == .visualFidelity && $0.status == .unverified })
        let supplied = coverage.entries.filter { $0.feature == .uniformSupply && $0.stage == .fragment }
        #expect(supplied.map(\.status) == [.missing, .supported, .unverified])
        #expect(coverage.entries.contains { $0.stage == .vertex && $0.feature == .uniformSupply && $0.status == .unverified })
        #expect(JSONSerialization.isValidJSONObject(coverage.jsonObject()))
        let summary = WPEShaderSemanticCoverage.Summary([coverage, coverage])
        #expect(summary.observedDraws == 2)
        #expect(summary.uniquePasses == 1)
        #expect(summary.counts.first { $0.feature == .authoredVertexExecution }?.affectedPasses == 1)
    }

    @Test func provenanceCountMismatchCannotReportBindingsAsSupported() {
        let coverage = WPEShaderSemanticCoverage.observedCustomDraw(
            passID: "fixture", shaderName: "fixture", sourceClassification: nil, sourceFingerprint: nil,
            interface: nil, layout: [slot("g_Time", "float", 0, 1)], sources: []
        )
        #expect(coverage.entries.first { $0.feature == .uniformSupply }?.status == .unverified)
        #expect(coverage.entries.first { $0.feature == .authoredVertexExecution }?.status == .unverified)
        #expect(WPEShaderSemanticCoverage.Summary([]).observedEntries == 0)
    }

    private func slot(_ name: String, _ type: String, _ index: Int, _ count: Int) -> WPEUniformSlot {
        WPEUniformSlot(name: name, glslType: type, slot: index, slotCount: count, arrayLength: nil,
                       materialName: nil, defaultValue: nil, requiredCombos: [:])
    }
    #endif
}
#endif
