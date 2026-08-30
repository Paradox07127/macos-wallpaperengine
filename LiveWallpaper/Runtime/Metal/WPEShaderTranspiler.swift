#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// WPE-flavor GLSL → MSL for the canonical single-pass effect shader.
/// Unsupported shaders surface as `metalRendererUnsupported`.
struct WPEShaderTranspiler {

    /// ≤256 slots (4 KB) ride `setFragmentBytes`; above that `setFragmentBuffer`.
    /// Stereo `audio_responsive_oscilloscope` needs 258. Cap is 1024 (16 KB).
    static let uniformSlotMaximum = 1024

    static let customTextureSlotCount = 8

    static func translateFragment(
        shaderName: String,
        preprocessedSource: String,
        comboValues: [String: Int] = [:],
        premultipliedInputSlots: Set<Int> = [],
        premultipliedOutput: Bool = false
    ) throws -> WPEShaderTranslationResult {
        // fluidsimulation fragments read v_TexCoordLeftTop/RightBottom (one-texel
        // neighbour offsets their .vert derives from g_Texture0Resolution) without
        // declaring the resolution uniform themselves. Declare it here so the
        // varying reconstruction has a slot to read — the executor already packs
        // g_TextureNResolution by name for every declared uniform.
        var parseSource = preprocessedSource
        if preprocessedSource.contains("v_TexCoordLeftTop"),
           !preprocessedSource.contains("g_Texture0Resolution") {
            parseSource = "uniform vec4 g_Texture0Resolution;\n" + preprocessedSource
        }
        let scrubbedSource = Self.scrubFragmentOutDeclarations(parseSource)
        let activeSource = Self.stripInactivePreprocessorBranches(in: scrubbedSource)
        let lines = activeSource.components(separatedBy: "\n")

        var uniforms: [WPEUniformDecl] = []
        var samplers: [WPESamplerDecl] = []
        var varyings: [WPEVaryingDecl] = []
        var bodyLines: [String] = []

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                bodyLines.append(raw)
                continue
            }
            if trimmed.hasPrefix("#version") || trimmed.hasPrefix("#extension") {
                continue
            }
            if trimmed.hasPrefix("out vec4 wpe_fragColor")
                || trimmed.hasPrefix("out float4 wpe_fragColor")
                || trimmed.hasPrefix("out vec4 out_FragColor")
                || trimmed.hasPrefix("out float4 out_FragColor") {
                continue
            }
            if let sampler = WPESamplerDecl.parse(line: trimmed) {
                samplers.append(sampler)
                continue
            }
            let parsedUniforms = WPEUniformDecl.parseAll(line: trimmed)
            if !parsedUniforms.isEmpty {
                uniforms.append(contentsOf: parsedUniforms)
                continue
            }
            if let varying = WPEVaryingDecl.parse(line: trimmed) {
                varyings.append(varying)
                continue
            }
            bodyLines.append(raw)
        }

        let sortedSamplers = samplers.sorted { lhs, rhs in
            (Self.textureSlot(for: lhs.name) ?? .max) < (Self.textureSlot(for: rhs.name) ?? .max)
        }
        guard sortedSamplers.count <= Self.customTextureSlotCount else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' uses \(sortedSamplers.count) samplers; transpiler supports up to \(Self.customTextureSlotCount)"
            )
        }
        if let maxSlot = sortedSamplers.compactMap({ Self.textureSlot(for: $0.name) }).max(),
           maxSlot >= Self.customTextureSlotCount {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' binds texture slot \(maxSlot); transpiler supports slots 0–\(Self.customTextureSlotCount - 1)"
            )
        }
        // Sampler wrap (clamp vs repeat) and filter are NOT decided here anymore: every
        // `g_TextureN.sample` is rewritten to the per-slot runtime sampler `wpeSamplerN`
        // (`rewriteSamplersToPerSlot`), whose address/filter the executor binds from the
        // texture's TEXI flags. The old "annotate a sampler as noise → repeatSampler" heuristic is retired — it couldn't see per-texture ClampUVs and missed water-normal/flow maps (waterripple froze).
        let body = bodyLines.joined(separator: "\n")
        guard let mainRange = Self.locateMain(in: body) else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' has no recognizable `void main()` entry point"
            )
        }
        let preMain = String(body[..<mainRange.lowerBound])
        let mainBody = String(body[mainRange])
        let postMain = String(body[mainRange.upperBound...])

        let varyingTypesByName = Dictionary(
            varyings.map { ($0.name, $0.metalType) },
            uniquingKeysWith: { _, last in last }
        )
        let preserveTexCoordZW = shouldPreserveTexCoordZW(shaderName: shaderName, comboValues: comboValues)
        let translatedHelpers = applySubstitutions(
            preMain + "\n" + postMain,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW,
            premultipliedInputSlots: premultipliedInputSlots,
            uniforms: uniforms
        )
        let translatedMain = translateMain(
            mainBody,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW,
            premultipliedInputSlots: premultipliedInputSlots,
            premultiplyOutput: premultipliedOutput,
            uniforms: uniforms,
            functionDeclarations: preMain + "\n" + postMain
        )
        // Convert `g_TextureN.sample(linear|repeatSampler, …)` → the per-slot runtime sampler
        // `wpeSamplerN` in BOTH helper and main bodies BEFORE resource threading, so
        // `rewriteHelperResourceAccess` sees `wpeSamplerN` in a helper body and wires it into
        // that helper's signature/call (`samplerStateResources`). Runs after the `linearSampler`-keyed narrowing/LOD rewrites, so those still matched the literal name.
        let perSlotHelpers = Self.rewriteSamplersToPerSlot(translatedHelpers)
        let perSlotMain = Self.rewriteSamplersToPerSlot(translatedMain)
        let helperMutableGlobals = extractProgramScopeMutableDeclarations(from: perSlotHelpers)
        let helperResources = rewriteHelperResourceAccess(
            helpers: helperMutableGlobals.source,
            mainBody: perSlotMain,
            uniforms: uniforms,
            samplers: sortedSamplers,
            mutableGlobals: helperMutableGlobals.declarations
        )

        let msl = renderMSL(
            shaderName: shaderName,
            uniforms: uniforms,
            samplers: sortedSamplers,
            varyings: varyings,
            helpers: helperResources.helpers,
            mainBody: helperResources.mainBody,
            mutableGlobals: helperMutableGlobals.declarations,
            comboValues: comboValues,
            premultipliedInputSlots: premultipliedInputSlots,
            premultipliedOutput: premultipliedOutput
        )

        var layout: [WPEUniformSlot] = []
        var nextSlot = 0
        for u in uniforms {
            let slotCount: Int
            if let len = u.arrayLength {
                slotCount = len
            } else {
                slotCount = Self.slotCount(for: u.type)
            }
            layout.append(WPEUniformSlot(
                name: u.name,
                glslType: u.type,
                slot: nextSlot,
                slotCount: slotCount,
                arrayLength: u.arrayLength,
                materialName: u.materialName,
                defaultValue: u.defaultValue
            ))
            nextSlot += slotCount
        }
        guard nextSlot <= Self.uniformSlotMaximum else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' needs \(nextSlot) uniform slots; transpiler caps at \(Self.uniformSlotMaximum)"
            )
        }

        return WPEShaderTranslationResult(
            mslSource: msl,
            samplers: sortedSamplers.map(\.name),
            uniformLayout: layout,
            totalSlots: nextSlot
        )
    }

    static func slotCount(for glslType: String) -> Int {
        switch glslType {
        case "mat2": return 2
        case "mat3": return 3
        case "mat4": return 4
        default:    return 1
        }
    }

}
#endif
