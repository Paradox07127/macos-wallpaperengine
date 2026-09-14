#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

struct WPEShaderTranspiler {

    /// ≤256 slots (4 KB) ride `setFragmentBytes`; above that `setFragmentBuffer`.
    /// Stereo `audio_responsive_oscilloscope` needs 258. Cap is 1024 (16 KB).
    static let uniformSlotMaximum = 1024
    /// Bounds literal varying initializer expansion in the Swift code generator.
    static let varyingElementMaximum = 1024
    /// Keep production on the original math; explicit 0 opts into the experiment, 1 selects reference.
    static let waterOptimizationsEnabled = ProcessInfo.processInfo.environment["WPE_DIAGNOSTIC_DISABLE_WATER_OPTIMIZATIONS"] == "0"

    /// Ceiling, not an allocation: 16 is Metal's sampler-index maximum (0–15).
    /// Used only where the count cannot yet be known: validation, `g_TextureN` parsing, and the pre-translation passes.
    static let customTextureSlotLimit = 16

    /// Highest declared `g_TextureN` index + 1, and never fewer than the sampler count (a non-`g_TextureN` sampler occupies its enumeration index).
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
        premultipliedOutput: Bool = false,
        waterOptimizationsEnabled: Bool = Self.waterOptimizationsEnabled
    ) throws -> WPEShaderTranslationResult {
        // fluidsimulation fragments read neighbour-offset varyings without declaring `g_Texture0Resolution`; inject it so reconstruction has a slot to read.
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
        // Sampler wrap/filter are not decided here: every `g_TextureN.sample` is rewritten to per-slot `wpeSamplerN` bound from TEXI flags.
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
        // Rewrite to `wpeSamplerN` in helper and main BEFORE resource threading, and after `linearSampler`-keyed narrowing/LOD so those still match the literal name.
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
            premultipliedOutput: premultipliedOutput,
            waterOptimizationsEnabled: waterOptimizationsEnabled
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
                defaultValue: u.defaultValue,
                requiredCombos: u.requiredCombos
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
