#if !LITE_BUILD
import Foundation

extension WPEShaderTranspiler {
    /// Real vertex execution uses the common dialect transformations only.
    /// The linked fragment receives these outputs through rasterizer interpolation.
    static func translateFullscreenVertex(
        shaderName: String, preprocessedSource: String, link: WPEShaderStageLink,
        comboValues: [String: Int] = [:], premultipliedInputSlots: Set<Int> = [],
        execution: WPEVertexExecution = .authoredFullscreen
    ) throws -> WPEShaderTranslationResult {
        let active = stripInactivePreprocessorBranches(in: preprocessedSource)
        let source = link.removingStageDeclarations(from: active, stage: .vertex)
        var uniforms: [WPEUniformDecl] = []
        var samplers: [WPESamplerDecl] = []
        var bodyLines: [String] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#version") || trimmed.hasPrefix("#extension") {
                continue
            }
            if let sampler = WPESamplerDecl.parse(line: trimmed) {
                samplers.append(sampler); continue
            }
            let parsed = WPEUniformDecl.parseAll(line: trimmed)
            if !parsed.isEmpty {
                uniforms.append(contentsOf: parsed); continue
            }
            bodyLines.append(line)
        }
        let layout = try validatedUniformLayout(uniforms, shaderName: shaderName)
        let sortedSamplers = samplers.sorted { (textureSlot(for: $0.name) ?? .max) < (textureSlot(for: $1.name) ?? .max) }
        let textureSlots = textureSlotCount(for: sortedSamplers)
        guard textureSlots <= customTextureSlotLimit else {
            throw WPEShaderCompilerError.translationFailed("authored vertex texture interface exceeds slot budget")
        }
        let body = bodyLines.joined(separator: "\n")
        guard let mainRange = locateMain(in: body) else {
            throw WPEShaderCompilerError.translationFailed("authored vertex has no main entry point")
        }
        let main = String(body[mainRange])
        guard let open = main.firstIndex(of: "{"), let close = main.lastIndex(of: "}") else {
            throw WPEShaderCompilerError.translationFailed("malformed authored vertex entry point")
        }
        let helperSource = String(body[..<mainRange.lowerBound]) + "\n" + String(body[mainRange.upperBound...])
        let stageTypes = Dictionary(link.interface.variables.filter {
            $0.key.stage == .vertex && $0.arrayDimensions.isEmpty
                && [.attribute, .varyingOutput].contains($0.kind)
        }.map { ($0.key.name, WPEUniformDecl.mapType($0.glslType)) }, uniquingKeysWith: { _, last in last })
        let helpers = rewriteSamplersToPerSlot(applySubstitutions(helperSource, varyingTypesByName: stageTypes, premultipliedInputSlots: premultipliedInputSlots, uniforms: uniforms, stage: .vertex))
        let inner = rewriteSamplersToPerSlot(applySubstitutions(
            String(main[main.index(after: open) ..< close]), rewriteProgramScopeConsts: false,
            varyingTypesByName: stageTypes, premultipliedInputSlots: premultipliedInputSlots, uniforms: uniforms, functionDeclarations: helperSource, stage: .vertex
        ))
        let globals = extractProgramScopeMutableDeclarations(from: helpers)
        // Helper output writes use the same by-reference threading as authored globals.
        // Array outputs passed through helpers need an array-reference ABI of their own.
        guard !link.varyings.contains(where: { v in
            v.isArray && maskComments(globals.source).range(of: "\\b" + NSRegularExpression.escapedPattern(for: v.name) + "\\b", options: .regularExpression) != nil
        }) else { throw WPEShaderCompilerError.translationFailed("vertex helpers consuming varying arrays are not supported") }
        var resources = globals.declarations
        resources += link.varyings.filter { !$0.isArray }.map {
            ProgramScopeMutableDecl(metalType: $0.metalType, name: $0.name, initializer: "{}")
        }
        resources.append(ProgramScopeMutableDecl(metalType: "float4", name: "gl_Position", initializer: "{}"))
        let threaded = rewriteHelperResourceAccess(helpers: globals.source, mainBody: inner,
                                                   uniforms: uniforms, samplers: sortedSamplers, mutableGlobals: resources)
        // Reuse the math/compatibility prelude, without a fragment entry point or varyings.
        let prelude = renderMSL(shaderName: shaderName, uniforms: uniforms, totalUniformSlots: layout.totalSlots,
                                samplers: sortedSamplers, textureSlotCount: textureSlots, varyings: [],
                                helpers: threaded.helpers, mainBody: "return float4(0);", comboValues: comboValues,
                                premultipliedInputSlots: premultipliedInputSlots,
                                matrixInverseRequired: maskComments(threaded.mainBody).contains("wpe_glsl_inverse"))
        guard let fragmentEntry = prelude.range(of: "fragment float4 wpe_translated_fragment(") else {
            throw WPEShaderCompilerError.translationFailed("missing generated prelude boundary")
        }
        var out = String(prelude[..<fragmentEntry.lowerBound]).replacingOccurrences(
            of: "struct WPEStageIn {\n    float4 position [[position]];\n    float2 uv;\n};", with: link.stageInDeclaration
        )
        var parameters = ["uint vertexID [[vertex_id]]"]
        if execution == .authoredObjectQuad {
            parameters.append("constant float2& positionScale [[buffer(2)]]")
        }
        if !uniforms.isEmpty {
            parameters.append("constant WPEUniforms& u [[buffer(0)]]")
        }
        for slot in 0 ..< textureSlots {
            parameters.append("texture2d<float> tex\(slot) [[texture(\(slot))]]")
        }
        for slot in 0 ..< textureSlots {
            parameters.append("sampler wpeSampler\(slot) [[sampler(\(slot))]]")
        }
        let entry = execution == .authoredObjectQuad ? "wpe_authored_object_quad_vertex" : "wpe_authored_fullscreen_vertex"
        out += "vertex WPEStageIn \(entry)(\(parameters.joined(separator: ", "))) {\n"
        out += "    const float2 positions[4] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};\n"
        out += "    const float2 uvs[4] = {float2(0,1), float2(1,1), float2(0,0), float2(1,0)};\n"
        out += "    WPEStageIn out;\n    float4 gl_Position = {};\n"
        for attribute in link.interface.variables(stage: .vertex, kind: .attribute) {
            let position = execution == .authoredObjectQuad ? "positions[vertexID] * positionScale" : "positions[vertexID]"
            let value: String = if attribute.key.name == "a_Position" {
                attribute.glslType == "vec4" ? "float4(\(position), 0, 1)" : "float3(\(position), 0)"
            } else {
                attribute.glslType == "vec4" ? "float4(uvs[vertexID], 0, 0)" : "uvs[vertexID]"
            }
            out += "    [[maybe_unused]] \(WPEUniformDecl.mapType(attribute.glslType)) \(attribute.key.name) = \(value);\n"
        }
        for (index, sampler) in sortedSamplers.enumerated() {
            out += "    [[maybe_unused]] auto \(sampler.name) = tex\(textureSlot(for: sampler.name) ?? index);\n"
        }
        out += uniformDeclarationLines(uniforms).joined(separator: "\n") + "\n"
        for varying in link.varyings {
            out += "    [[maybe_unused]] \(varying.declaration) = {};\n"
        }
        for global in globals.declarations {
            out += "    [[maybe_unused]] \(global.metalType) \(global.name) = \(global.initializer);\n"
        }
        var finish = "out.position = gl_Position;\nout.uv = uvs[vertexID];\n"
        for v in link.varyings {
            for element in 0 ..< v.elementCount {
                finish += "out.\(v.field(element)) = \(v.name)\(v.isArray ? "[\(element)]" : "");\n"
            }
        }
        finish += "return out;\n"
        out += markLocalVariableDeclarationsMaybeUnused(threaded.mainBody).replacingOccurrences(
            of: #"\breturn\s*;"#, with: "{\n" + finish + "}", options: .regularExpression
        ) + "\n" + finish + "}\n"
        return WPEShaderTranslationResult(mslSource: out, samplers: sortedSamplers.map(\.name),
                                          uniformLayout: layout.slots, totalSlots: layout.totalSlots,
                                          textureSlotCount: textureSlots)
    }
}
#endif
