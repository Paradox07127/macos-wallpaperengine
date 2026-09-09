#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

/// WPE-flavor GLSL → MSL for the canonical single-pass effect shader.
/// Unsupported shaders surface as `metalRendererUnsupported`.
struct WPEShaderTranspiler {

    /// ≤256 slots (4 KB) ride `setFragmentBytes`; above that `setFragmentBuffer`.
    /// Stereo `audio_responsive_oscilloscope` needs 258. Cap is 1024 (16 KB).
    static let uniformSlotMaximum = 1024
    /// Bounds literal varying initializer expansion in the Swift code generator.
    static let varyingElementMaximum = 1024

    /// Ceiling, not an allocation: each shader declares only the slots it needs
    /// (`textureSlotCount(for:)`), the same way uniforms are sized per shader and merely
    /// capped by `uniformSlotMaximum`.
    ///
    /// 16 is a hard Metal limit, measured on Apple M5 Pro 2026-09-09: a fragment signature
    /// with 17 sampler arguments fails to compile with "'sampler' attribute parameter is
    /// out of bounds: must be between 0 and 15". Textures are not the constraint (16 bind
    /// fine); samplers are, and the generator emits one sampler per slot.
    ///
    /// Used only where the count cannot yet be known: validation, `g_TextureN` name
    /// parsing, and the two passes computed BEFORE translation (premultiplied-input
    /// detection and `TEX<N>FORMAT` macro emission).
    static let customTextureSlotLimit = 16

    /// Slots a shader actually occupies: highest declared `g_TextureN` index + 1, and never
    /// fewer than the sampler count — a sampler whose name is not `g_TextureN` has no
    /// parsed slot and falls back to its enumeration index, so it occupies one too.
    ///
    /// Sparse layouts make count and max-index differ: WPE's stock `chroma4` declares 8
    /// samplers (0-4, 6, 7, 8) but needs 9 bindings.
    static func textureSlotCount(for samplers: [WPESamplerDecl]) -> Int {
        var needed = samplers.count
        if let maxSlot = samplers.compactMap({ textureSlot(for: $0.name) }).max() {
            needed = max(needed, maxSlot + 1)
        }
        return needed
    }

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
        parseSource = Self.declaringVertexOnlyUniforms(in: parseSource, shaderName: shaderName)
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

        // Validate before substitutions or MSL generation can expand an authored
        // array. The same checked layout sizes both the host buffer and MSL.
        let layout = try validatedUniformLayout(uniforms, shaderName: shaderName)
        try validateVaryingExpansion(varyings, shaderName: shaderName)

        let sortedSamplers = samplers.sorted { lhs, rhs in
            (Self.textureSlot(for: lhs.name) ?? .max) < (Self.textureSlot(for: rhs.name) ?? .max)
        }
        guard sortedSamplers.count <= Self.customTextureSlotLimit else {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' uses \(sortedSamplers.count) samplers; transpiler supports up to \(Self.customTextureSlotLimit)"
            )
        }
        if let maxSlot = sortedSamplers.compactMap({ Self.textureSlot(for: $0.name) }).max(),
           maxSlot >= Self.customTextureSlotLimit {
            throw WPEShaderCompilerError.translationFailed(
                "shader '\(shaderName)' binds texture slot \(maxSlot); transpiler supports slots 0–\(Self.customTextureSlotLimit - 1)"
            )
        }
        let textureSlotCount = Self.textureSlotCount(for: sortedSamplers)
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
            totalUniformSlots: layout.totalSlots,
            samplers: sortedSamplers,
            textureSlotCount: textureSlotCount,
            varyings: varyings,
            helpers: helperResources.helpers,
            mainBody: helperResources.mainBody,
            mutableGlobals: helperMutableGlobals.declarations,
            comboValues: comboValues,
            premultipliedInputSlots: premultipliedInputSlots,
            premultipliedOutput: premultipliedOutput
        )

        return WPEShaderTranslationResult(
            mslSource: msl,
            samplers: sortedSamplers.map(\.name),
            uniformLayout: layout.slots,
            totalSlots: layout.totalSlots,
            textureSlotCount: textureSlotCount
        )
    }

    private static func validatedUniformLayout(
        _ uniforms: [WPEUniformDecl],
        shaderName: String
    ) throws -> (slots: [WPEUniformSlot], totalSlots: Int) {
        var slots: [WPEUniformSlot] = []
        var nextSlot = 0
        for u in uniforms {
            if u.arrayDimension != nil, u.arrayLength == nil {
                throw WPEShaderCompilerError.translationFailed(
                    "shader '\(shaderName)' uniform '\(u.name)' has an unsupported array dimension"
                )
            }
            let count = u.arrayLength ?? Self.slotCount(for: u.type)
            guard count > 0, count <= Self.uniformSlotMaximum - nextSlot else {
                throw WPEShaderCompilerError.translationFailed(
                    "shader '\(shaderName)' uniform '\(u.name)' requires a positive size within the \(Self.uniformSlotMaximum)-slot budget"
                )
            }
            slots.append(WPEUniformSlot(
                name: u.name,
                glslType: u.type,
                slot: nextSlot,
                slotCount: count,
                arrayLength: u.arrayLength,
                materialName: u.materialName,
                defaultValue: u.defaultValue
            ))
            nextSlot += count
        }
        return (slots, nextSlot)
    }

    private static func validateVaryingExpansion(
        _ varyings: [WPEVaryingDecl],
        shaderName: String
    ) throws {
        var remaining = Self.varyingElementMaximum
        for varying in varyings {
            if let dimension = varying.arrayDimension, varying.arrayLength == nil {
                let digits = dimension.first == "+" || dimension.first == "-"
                    ? dimension.dropFirst() : dimension[...]
                let isIntegerLiteral = !digits.isEmpty && digits.utf8.allSatisfy { (48...57).contains($0) }
                guard !dimension.isEmpty, !isIntegerLiteral else {
                    throw WPEShaderCompilerError.translationFailed(
                        "shader '\(shaderName)' varying '\(varying.name)' has an invalid array dimension"
                    )
                }
                // Symbolic dimensions stay compact MSL declarations; their
                // existing reconstruction does not expand a Swift array.
            }
            let count = varying.arrayLength ?? 1
            guard count > 0, count <= remaining else {
                throw WPEShaderCompilerError.translationFailed(
                    "shader '\(shaderName)' varying '\(varying.name)' requires a positive size within the \(Self.varyingElementMaximum)-element expansion budget"
                )
            }
            remaining -= count
        }
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
