#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

extension WPEShaderTranspiler {
    // MARK: - Type / intrinsic substitutions

    static func markLocalVariableDeclarationsMaybeUnused(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("[[maybe_unused]]"),
                  !trimmed.hasPrefix("for "),
                  !trimmed.hasPrefix("for("),
                  line.range(
                    of: #"^\s*(?:const\s+)?(?:auto|float(?:[234](?:x[234])?)?|int[234]?|uint[234]?|bool[234]?)\s+[A-Za-z_][A-Za-z0-9_]*(?:\s*\[[^\]]+\])?\s*(?:=|;)"#,
                    options: .regularExpression
                  ) != nil else {
                return line
            }

            let indentEnd = line.firstIndex { !$0.isWhitespace } ?? line.startIndex
            return String(line[..<indentEnd]) + "[[maybe_unused]] " + String(line[indentEnd...])
        }.joined(separator: "\n")
    }

    /// Apply token-level substitutions for the GLSL→MSL gap.
    static func applySubstitutions(
        _ source: String,
        rewriteProgramScopeConsts: Bool = true,
        varyingTypesByName: [String: String] = [:],
        preserveTexCoordZW: Bool = false,
        premultipliedInputSlots: Set<Int> = [],
        repeatSamplers: Set<String> = [],
        uniforms: [WPEUniformDecl] = [],
        // `main`'s body is substituted separately from the helper block it calls into, so the
        // helper sources come along to keep the function-signature table complete.
        functionDeclarations: String = ""
    ) -> String {
        var s = source

        for (glsl, msl) in [
            ("ivec4", "int4"), ("ivec3", "int3"), ("ivec2", "int2"),
            ("uvec4", "uint4"), ("uvec3", "uint3"), ("uvec2", "uint2"),
            ("bvec4", "bool4"), ("bvec3", "bool3"), ("bvec2", "bool2"),
            ("vec4", "float4"), ("vec3", "float3"), ("vec2", "float2"),
            ("mat4", "float4x4"), ("mat3", "float3x3"), ("mat2", "float2x2")
        ] {
            s = wordReplace(s, find: glsl, replace: msl)
        }

        s = wordReplace(s, find: "frac", replace: "fract")
        s = wordReplace(s, find: "atan2", replace: "atan2")
        s = wordReplace(s, find: "lerp", replace: "mix")
        // GLSL derivative builtins → MSL spelling (no sign change: WPE's ddx/ddy
        // map straight to dfdx/dfdy; the GL-only ddy(-x) negation is not wanted).
        s = wordReplace(s, find: "dFdx", replace: "dfdx")
        s = wordReplace(s, find: "dFdy", replace: "dfdy")
        s = rewriteSmoothstepCalls(s)

        if rewriteProgramScopeConsts {
            s = rewriteProgramScopeConstDeclarations(s)
        }
        s = rewriteReservedIdentifiers(s)
        s = canonicalizeTextureSampleAliases(s)
        s = rewriteTextureLodCalls(s, premultipliedInputSlots: premultipliedInputSlots, repeatSamplers: repeatSamplers)
        s = rewriteTextureCalls(s, premultipliedInputSlots: premultipliedInputSlots, repeatSamplers: repeatSamplers)
        s = rewriteTexCoordTextureSampleUVFallback(s)
        s = rewriteTextureSampleNarrowing(s)
        s = rewriteVector4TextureSampleLocalsInSampleCoordinates(s)
        s = rewriteSwizzledMixAssignments(s)
        s = rewriteUnsignedFloatModuloAssignments(s)
        s = rewriteFloatAssignmentsFromVectorExpressions(s)
        s = rewritePointerPositionFloatAssignments(s)
        s = rewriteTextureResolutionVector2Assignments(s)
        s = rewriteVectorConstructorNarrowing(s)
        s = rewriteTexCoordVector2Arithmetic(s, varyingTypesByName: varyingTypesByName)
        s = rewriteTexCoordMaskUVFallback(
            s,
            varyingTypesByName: varyingTypesByName,
            preserveTexCoordZW: preserveTexCoordZW
        )
        s = rewriteGLSLArrayConstructors(s)
        s = rewriteArrayCopyInitialization(s)
        s = rewriteFloatArraySubscripts(s)
        s = rewriteHLSLImplicitConversions(s, uniforms: uniforms, functionDeclarations: functionDeclarations)

        s = rewriteReferenceParameters(s)

        s = stripInParameterQualifier(s)

        return s
    }

    /// GLSL leaves `smoothstep(edge0, edge1, x)` undefined when the two edges
    /// are equal. Several WPE audio shaders intentionally collapse smoothing to
    /// zero at rest; Metal can turn the resulting division by zero into NaNs
    /// that then pollute premultiplied alpha. Route calls through a finite helper
    /// that behaves like a hard threshold for degenerate edges.
    private static func rewriteSmoothstepCalls(_ source: String) -> String {
        let pattern = #"(?<![:A-Za-z0-9_])smoothstep\s*\("#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "wpe_smoothstep("
        )
    }

    private static func canonicalizeTextureSampleAliases(_ source: String) -> String {
        source.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#define texSample2D")
                || trimmed.hasPrefix("#define texSample2DLod")
                || trimmed.hasPrefix("#define texture2D") {
                return "// disabled texture sample alias macro: \(line)"
            }

            var rewritten = wordReplace(line, find: "texSample2DLod", replace: "textureLod")
            rewritten = wordReplace(rewritten, find: "texSample2D", replace: "texture")
            rewritten = wordReplace(rewritten, find: "texture2D", replace: "texture")
            return rewritten
        }.joined(separator: "\n")
    }

    /// Metal requires program-scope variables to live in the constant address
    /// space, while computed initializers must avoid global constructors.
    private static func rewriteProgramScopeConstDeclarations(_ source: String) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var depth = 0
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            var line = String(source[lineStart..<lineEnd])
            if depth == 0 {
                line = rewriteProgramScopeConstLine(line)
            }
            result += line
            if lineEnd < source.endIndex {
                result.append("\n")
            }

            for ch in line {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth = max(0, depth - 1)
                }
            }

            guard lineEnd < source.endIndex else { break }
            lineStart = source.index(after: lineEnd)
        }

        return result
    }

    private static func rewriteProgramScopeConstLine(_ line: String) -> String {
        let typePattern = #"(?:float|half|int|uint|bool)(?:[234](?:x[234])?)?"#
        let declarationPattern = #"^(\s*)const\s+(\#(typePattern))\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+);\s*$"#
        if let regex = try? NSRegularExpression(pattern: declarationPattern),
           let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
           let indentRange = Range(match.range(at: 1), in: line),
           let nameRange = Range(match.range(at: 3), in: line),
           let rhsRange = Range(match.range(at: 4), in: line) {
            let rhs = String(line[rhsRange])
            if programScopeInitializerNeedsExpansion(rhs) {
                return "\(line[indentRange])#define \(line[nameRange]) (\(rhs))"
            }
        }

        let pattern = #"^(\s*)const\s+(\#(typePattern))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return line
        }
        return regex.stringByReplacingMatches(
            in: line,
            range: NSRange(line.startIndex..., in: line),
            withTemplate: "$1constant $2"
        )
    }

    private static func programScopeInitializerNeedsExpansion(_ rhs: String) -> Bool {
        if rhs.range(of: #"\b[ug]_[A-Za-z0-9_]*\b"#, options: .regularExpression) != nil {
            return true
        }
        let functionNames = [
            "abs", "acos", "asin", "atan", "ceil", "clamp", "cos", "cross", "distance",
            "dot", "exp", "floor", "fract", "length", "log", "max", "min", "mix",
            "normalize", "pow", "reflect", "refract", "round", "sign", "sin", "smoothstep",
            "sqrt", "step", "tan"
        ]
        let joined = functionNames.joined(separator: "|")
        let pattern = #"(?<![A-Za-z0-9_])(\#(joined))\s*\("#
        return rhs.range(of: pattern, options: .regularExpression) != nil
    }

    struct ProgramScopeMutableDecl: Hashable {
        let metalType: String
        let name: String
        let initializer: String

        var helperParameterType: String {
            "thread \(metalType)&"
        }
    }

    /// GLSL permits writable globals as per-fragment scratch state; MSL rejects
    /// non-`constant` program-scope variables. Move simple scratch declarations
    /// into `wpe_translated_fragment` and thread them through helper references.
    static func extractProgramScopeMutableDeclarations(
        from source: String
    ) -> (source: String, declarations: [ProgramScopeMutableDecl]) {
        var declarations: [ProgramScopeMutableDecl] = []
        var output: [String] = []
        var depth = 0

        for line in source.components(separatedBy: "\n") {
            if depth == 0, let declaration = parseProgramScopeMutableDeclarationLine(line) {
                declarations.append(declaration)
            } else {
                output.append(line)
            }

            for ch in line {
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth = max(0, depth - 1)
                }
            }
        }

        return (output.joined(separator: "\n"), declarations)
    }

    private static func parseProgramScopeMutableDeclarationLine(_ line: String) -> ProgramScopeMutableDecl? {
        let typePattern = #"(?:float|half|int|uint|bool)(?:[234](?:x[234])?)?"#
        let pattern = #"^\s*(?!const\b)(?!constant\b)(\#(typePattern))\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=\s*(.*?))?\s*;\s*(?://.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let typeRange = Range(match.range(at: 1), in: line),
              let nameRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let metalType = String(line[typeRange])
        let initializer: String
        if match.range(at: 3).location != NSNotFound,
           let initializerRange = Range(match.range(at: 3), in: line) {
            initializer = String(line[initializerRange]).trimmingCharacters(in: .whitespaces)
        } else {
            initializer = zeroInitializer(forMetalType: metalType)
        }

        return ProgramScopeMutableDecl(
            metalType: metalType,
            name: String(line[nameRange]),
            initializer: initializer.isEmpty ? zeroInitializer(forMetalType: metalType) : initializer
        )
    }

    private static func zeroInitializer(forMetalType metalType: String) -> String {
        if metalType == "bool" { return "false" }
        if metalType.hasPrefix("bool") { return "\(metalType)(false)" }
        if metalType == "int" || metalType == "uint" { return "0" }
        if metalType.hasPrefix("int") || metalType.hasPrefix("uint") { return "\(metalType)(0)" }
        if metalType == "float" || metalType == "half" { return "0.0" }
        return "\(metalType)(0.0)"
    }

    /// Rewrite WPE shaders that use GLSL-style float modulo for an unsigned bucket index.
    private static func rewriteUnsignedFloatModuloAssignments(_ source: String) -> String {
        let pattern = #"\buint\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]+?)\s*%\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "uint $1 = uint(fmod(float($2), float($3)));"
        )
    }

    /// Some WPE workshop shaders use HLSL-style inference in local declarations,
    /// e.g. `float pointer = g_PointerPosition.xy * speed;`. Infer the MSL type
    /// for obvious vector expressions, but leave texture samples alone because
    /// `texture(...).r` style scalar extraction is a separate compatibility rule.
    private static func rewriteFloatAssignmentsFromVectorExpressions(_ source: String) -> String {
        let pattern = #"\bfloat\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]*(?:\.[xyzwrgba]{2,4}|float[234]\s*\()[^;\n]*);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result),
                  let rhsRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let rhs = String(result[rhsRange])
            guard !rhs.contains(".sample("), !rhs.contains("texture") else {
                continue
            }
            let name = result[nameRange]
            result.replaceSubrange(fullRange, with: "auto \(name) = \(rhs);")
        }
        return result
    }

    /// WPE's cursor uniform is a vec2, but several workshop shaders declare
    /// derived pointer offsets as `float` and rely on HLSL-style inference.
    private static func rewritePointerPositionFloatAssignments(_ source: String) -> String {
        let pattern = #"\bfloat\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;\n]*\bg_PointerPosition\b[^;\n]*);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result),
                  let rhsRange = Range(match.range(at: 2), in: result) else {
                continue
            }
            let rhs = String(result[rhsRange])
            guard !rhs.contains(".sample("), !rhs.contains("texture") else {
                continue
            }
            let name = result[nameRange]
            result.replaceSubrange(fullRange, with: "auto \(name) = \(rhs);")
        }
        return result
    }

    /// WPE shaders sometimes use `g_TextureNResolution` as a vec2 scale in
    /// compound assignments, even though the uniform is declared as vec4.
    private static func rewriteTextureResolutionVector2Assignments(_ source: String) -> String {
        let declarationPattern = #"\bfloat2\s+([A-Za-z_][A-Za-z0-9_]*)\b"#
        guard let declarationRegex = try? NSRegularExpression(pattern: declarationPattern) else {
            return source
        }
        let declarationMatches = declarationRegex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        )
        let vector2Names = declarationMatches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[range])
        }
        guard !vector2Names.isEmpty else {
            return source
        }

        var result = source
        for name in vector2Names {
            let escapedName = NSRegularExpression.escapedPattern(for: name)
            let pattern = #"(\b"# + escapedName + #"\s*[+\-*/]?=\s*[^;\n]*?)\b(g_Texture[0-9]+Resolution)\b(?!\s*\.)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range(at: 0), in: result),
                      let prefixRange = Range(match.range(at: 1), in: result),
                      let resolutionRange = Range(match.range(at: 2), in: result) else {
                    continue
                }
                result.replaceSubrange(
                    fullRange,
                    with: "\(result[prefixRange])\(result[resolutionRange]).xy"
                )
            }
        }
        return result
    }

    /// Metal texture2d sampling requires float2 UVs. WPE often carries extra
    /// UV data in zw and passes the full v_TexCoord vector to texture().
    private static func rewriteTexCoordTextureSampleUVFallback(_ source: String) -> String {
        // Also narrow the 3-arg LOD form `.sample(linearSampler, v_TexCoord, level(lod))`,
        // not just the 2-arg form, so vec3/vec4 v_TexCoord shaders that sample with an
        // explicit LOD still resolve to a float2 coordinate.
        let pattern = #"(\.sample\s*\(\s*linearSampler\s*,\s*)v_TexCoord(\s*(?:,\s*level\s*\([^;\n]+\))?\))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "$1v_TexCoord.xy$2"
        )
    }

    /// Texture-sample locals are float4, but WPE effects also use them as 2D
    /// offset vectors inside later texture coordinates.
    private static func rewriteVector4TextureSampleLocalsInSampleCoordinates(_ source: String) -> String {
        let declarationPattern = #"\bfloat4\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:[A-Za-z_][A-Za-z0-9_]*\.sample|wpe_unpremultiply_sample)\s*\("#
        guard let declarationRegex = try? NSRegularExpression(pattern: declarationPattern) else {
            return source
        }
        let names = declarationRegex.matches(
            in: source,
            range: NSRange(source.startIndex..., in: source)
        ).compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[range])
        }
        guard !names.isEmpty else {
            return source
        }

        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        let needle = ".sample("

        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                var cursor = source.index(index, offsetBy: needle.count)
                var depth = 1
                var commaIndex: String.Index?
                while cursor < source.endIndex && depth > 0 {
                    let ch = source[cursor]
                    if ch == "(" { depth += 1 }
                    else if ch == ")" { depth -= 1 }
                    else if ch == "," && depth == 1 && commaIndex == nil {
                        commaIndex = cursor
                    }
                    if depth > 0 {
                        cursor = source.index(after: cursor)
                    }
                }
                if let comma = commaIndex, cursor < source.endIndex {
                    let coordinateStart = source.index(after: comma)
                    var coordinate = String(source[coordinateStart..<cursor])
                    for name in names {
                        coordinate = wordReplaceUnlessMemberAccess(coordinate, find: name, replace: "\(name).xy")
                    }
                    result += source[index..<coordinateStart]
                    result += coordinate
                    result += ")"
                    index = source.index(after: cursor)
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Metal will not implicitly narrow a float4 constructor into float3.
    private static func rewriteVectorConstructorNarrowing(_ source: String) -> String {
        let pattern = #"\bfloat3\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(float4\s*\([^;\n]+\))\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "float3 $1 = $2.rgb;"
        )
    }

    /// Rename GLSL identifiers that are legal in WPE shaders but reserved by Metal.
    private static func rewriteReservedIdentifiers(_ source: String) -> String {
        var result = wordReplace(source, find: "kernel", replace: "kernelValues")
        result = wordReplace(result, find: "or", replace: "orValue")
        result = wordReplace(result, find: "fragment", replace: "fragmentValue")
        return result
    }

    /// GLSL permits assigning a texture sample to narrower vector/scalar locals.
    /// Metal samples return float4, so make the intended channel extraction explicit.
    private static func rewriteTextureSampleNarrowing(_ source: String) -> String {
        let samplePattern = #"(?:[A-Za-z_][A-Za-z0-9_]*\.sample|wpe_unpremultiply_sample)\([^;\n]+\)"#
        let pattern = #"\b(float|float2|float3)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*("# + samplePattern + #")\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let typeRange = Range(match.range(at: 1), in: result),
                  let nameRange = Range(match.range(at: 2), in: result),
                  let rhsRange = Range(match.range(at: 3), in: result) else {
                continue
            }
            let type = String(result[typeRange])
            let name = result[nameRange]
            let rhs = result[rhsRange]
            let swizzle: String
            switch type {
            case "float":
                swizzle = ".r"
            case "float2":
                swizzle = ".rg"
            case "float3":
                swizzle = ".rgb"
            default:
                continue
            }
            result.replaceSubrange(fullRange, with: "\(type) \(name) = \(rhs)\(swizzle);")
        }
        return result
    }

    /// GLSL permits `color.rgb = mix(color, replacementRgb, mask)`, relying on
    /// assignment narrowing. Metal requires the mixed vector widths to match.
    private static func rewriteSwizzledMixAssignments(_ source: String) -> String {
        let pattern = #"\b([A-Za-z_][A-Za-z0-9_]*)\.(rgb|xyz|rg|xy)\s*=\s*mix\s*\(\s*\1\s*,"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: "$1.$2 = mix($1.$2,"
        )
    }

    /// WPE workshop shaders often declare v_TexCoord as vec3/vec4 while using
    /// it as a vec2 UV in arithmetic.
    private static func rewriteTexCoordVector2Arithmetic(
        _ source: String,
        varyingTypesByName: [String: String]
    ) -> String {
        let pattern = #"\bv_TexCoord\s*([+\-])\s*((?:float2|CAST2)\s*\()"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        var result = regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "v_TexCoord.xy $1 $2"
        )

        guard let texCoordType = varyingTypesByName["v_TexCoord"],
              ["float3", "float4"].contains(texCoordType) else {
            return result
        }

        let declarationPattern = #"\bfloat2\s+([A-Za-z_][A-Za-z0-9_]*)\b"#
        guard let declarationRegex = try? NSRegularExpression(pattern: declarationPattern) else {
            return result
        }
        let vector2Names = Set(
            declarationRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
                .compactMap { match -> String? in
                    guard let range = Range(match.range(at: 1), in: result) else {
                        return nil
                    }
                    return String(result[range])
                }
        )
        guard !vector2Names.isEmpty else {
            return result
        }

        result = result.components(separatedBy: "\n").map { line in
            rewriteTexCoordVector2AssignmentLine(line, vector2Names: vector2Names)
        }.joined(separator: "\n")
        return result
    }

    private static func rewriteTexCoordVector2AssignmentLine(
        _ line: String,
        vector2Names: Set<String>
    ) -> String {
        guard line.contains("v_TexCoord"),
              let semicolon = line.firstIndex(of: ";"),
              let equal = line.firstIndex(of: "=") else {
            return line
        }
        let lhs = String(line[..<equal])
        let isVector2Declaration = lhs.range(
            of: #"\bfloat2\s+[A-Za-z_][A-Za-z0-9_]*\s*$"#,
            options: .regularExpression
        ) != nil
        let isKnownVector2Assignment = vector2Names.contains(lhs.trimmingCharacters(in: .whitespaces))
        guard isVector2Declaration || isKnownVector2Assignment else {
            return line
        }

        let rhsStart = line.index(after: equal)
        let rhs = String(line[rhsStart..<semicolon])
        let rewritten = wordReplaceUnlessMemberAccess(rhs, find: "v_TexCoord", replace: "v_TexCoord.xy")
        guard rewritten != rhs else {
            return line
        }
        return String(line[..<rhsStart]) + rewritten + String(line[semicolon...])
    }

    /// Metal accepts aggregate array initializers, not GLSL constructor syntax
    /// such as `float2[n](...)`.
    private static func rewriteGLSLArrayConstructors(_ source: String) -> String {
        let typePattern = #"(?:(?:float[234]x[234])|(?:(?:float|int|uint|bool)(?:[234])?))"#
        let pattern = #"\b(const\s+)?("# + typePattern + #")\s+([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*\]\s*=\s*("# + typePattern + #")\s*\[\s*([A-Za-z_][A-Za-z0-9_]*|\d+)\s*\]\s*\(([^;\n]+)\)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        var result = source
        var renamedArrays: [(from: String, to: String)] = []
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: result),
                  let declarationTypeRange = Range(match.range(at: 2), in: result),
                  let nameRange = Range(match.range(at: 3), in: result),
                  let declarationCountRange = Range(match.range(at: 4), in: result),
                  let constructorTypeRange = Range(match.range(at: 5), in: result),
                  let constructorCountRange = Range(match.range(at: 6), in: result),
                  let valuesRange = Range(match.range(at: 7), in: result) else {
                continue
            }
            let declarationType = String(result[declarationTypeRange])
            let constructorType = String(result[constructorTypeRange])
            let declarationCount = String(result[declarationCountRange])
            let constructorCount = String(result[constructorCountRange])
            guard declarationType == constructorType, declarationCount == constructorCount else {
                continue
            }
            let qualifier: String
            if match.range(at: 1).location != NSNotFound,
               let qualifierRange = Range(match.range(at: 1), in: result) {
                qualifier = String(result[qualifierRange])
            } else {
                qualifier = ""
            }
            let outputQualifier = qualifier == "const " && isTopLevel(fullRange.lowerBound, in: result) ? "constant " : qualifier
            let name = String(result[nameRange])
            let outputName = name == "kernel" ? "kernelValues" : name
            if outputName != name {
                renamedArrays.append((from: name, to: outputName))
            }
            let values = result[valuesRange]
            result.replaceSubrange(
                fullRange,
                with: "\(outputQualifier)\(declarationType) \(outputName)[\(declarationCount)] = { \(values) };"
            )
        }
        for renamedArray in renamedArrays {
            result = wordReplace(result, find: renamedArray.from, replace: renamedArray.to)
        }
        return result
    }

    private static func isTopLevel(_ index: String.Index, in source: String) -> Bool {
        var depth = 0
        var cursor = source.startIndex
        while cursor < index {
            if source[cursor] == "{" {
                depth += 1
            } else if source[cursor] == "}" {
                depth = max(0, depth - 1)
            }
            cursor = source.index(after: cursor)
        }
        return depth == 0
    }

    /// GLSL allows initializing a local array by copying another array
    /// (`float left[N] = g_AudioSpectrum32Left;`), but MSL requires an initializer list.
    /// Bind a reference instead (`thread float (&left)[N] = g_AudioSpectrum32Left;`) — the local
    /// is read-only here, so an alias is equivalent and avoids the (illegal) copy.
    private static func rewriteArrayCopyInitialization(_ source: String) -> String {
        let typePattern = #"(?:float|int|uint|bool)(?:[234])?"#
        let pattern = #"(?m)^([ \t]*)("# + typePattern + #")\s+([A-Za-z_]\w*)\s*\[\s*([A-Za-z_0-9]+)\s*\]\s*=\s*([A-Za-z_]\w*)\s*;"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "$1thread $2 (&$3)[$4] = $5;"
        )
    }

    /// MSL array subscripts must be integers, but WPE shaders routinely index with a `float`
    /// loop/bin variable (`float i = floor(...); left[i]`). Wrap subscripts that use a
    /// float-declared scalar in `int(...)`. Only bare-identifier subscripts of known float locals
    /// are touched, so integer indices and expression subscripts are left unchanged.
    private static func rewriteFloatArraySubscripts(_ source: String) -> String {
        let floatDeclPattern = #"\bfloat\s+([A-Za-z_]\w*)\s*="#
        let nonFloatDeclPattern = #"\b(?:int|uint|bool|float[234]|int[234]|uint[234]|bool[234])\s+([A-Za-z_]\w*)\b"#
        guard let floatDeclRegex = try? NSRegularExpression(pattern: floatDeclPattern),
              let nonFloatDeclRegex = try? NSRegularExpression(pattern: nonFloatDeclPattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        var floatVars: Set<String> = []
        for match in floatDeclRegex.matches(in: source, range: range) {
            if let nameRange = Range(match.range(at: 1), in: source) {
                floatVars.insert(String(source[nameRange]))
            }
        }
        // Scope guard: this pass is name-based, not scope-aware. If a name is ALSO declared as an
        // int/vector/bool elsewhere in the shader (e.g. one function's `float i` vs another's
        // `for (int i)`), leave its subscripts alone rather than rewriting an unrelated int index.
        var nonFloatVars: Set<String> = []
        for match in nonFloatDeclRegex.matches(in: source, range: range) {
            if let nameRange = Range(match.range(at: 1), in: source) {
                nonFloatVars.insert(String(source[nameRange]))
            }
        }
        floatVars.subtract(nonFloatVars)
        guard !floatVars.isEmpty else { return source }

        var result = source
        for name in floatVars {
            let subscriptPattern = #"\[\s*"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\]"#
            guard let regex = try? NSRegularExpression(pattern: subscriptPattern) else { continue }
            let fullRange = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: fullRange,
                withTemplate: "[int(\(name))]"
            )
        }
        return result
    }

    /// WPE compiles scene shaders as GLSL translated to HLSL and built with fxc (shader model 3),
    /// which downgrades two things Metal rejects outright to warnings: a wider vector passed where
    /// a narrower one is expected is truncated, and a scalar is indexable as `float1` so a second
    /// subscript on a `float[N]` element is a no-op. Workshop authors ship shaders that rely on
    /// both — scene 3776778760's audio ring hits all three sites below — so emulate fxc rather
    /// than fail the pass.
    private static func rewriteHLSLImplicitConversions(
        _ source: String,
        uniforms: [WPEUniformDecl],
        functionDeclarations: String
    ) -> String {
        var widths: [String: Int] = [:]
        var ambiguous: Set<String> = []
        var scalarArrays: Set<String> = []
        for uniform in uniforms {
            let width = vectorWidth(ofType: uniform.metalType)
            widths[uniform.name] = width
            if uniform.arrayLength != nil, width == 1 { scalarArrays.insert(uniform.name) }
        }
        // Locals. Name-based, not scope-aware (same caveat as `rewriteFloatArraySubscripts`): a
        // name declared at two different widths is dropped rather than guessed.
        let declPattern = #"\b(float|float2|float3|float4)\s+([A-Za-z_]\w*)\s*(?=[=;,)])"#
        if let regex = try? NSRegularExpression(pattern: declPattern) {
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let typeRange = Range(match.range(at: 1), in: source),
                      let nameRange = Range(match.range(at: 2), in: source) else { continue }
                let name = String(source[nameRange])
                let width = vectorWidth(ofType: String(source[typeRange]))
                if let existing = widths[name], existing != width { ambiguous.insert(name) }
                widths[name] = width
            }
        }
        for name in ambiguous { widths.removeValue(forKey: name) }
        var result = dropScalarArrayInnerSubscripts(source, names: scalarArrays)
        result = lowerScalarDistanceCalls(result, widths: widths)
        result = narrowMixArguments(result, widths: widths)
        result = narrowUserFunctionArguments(result, widths: widths, declarations: functionDeclarations)
        result = narrowWideInitializers(result, widths: widths)
        return narrowWideReturns(result, widths: widths)
    }

    /// `float r = step(1.0, albedo);` with a vec4 `albedo` — fxc truncates the component-wise
    /// result to the declared width, Metal refuses. Only initializers whose width can be judged
    /// (see `expressionWidth`) are touched, so a `dot`/`length` right-hand side stays as written.
    private static func narrowWideInitializers(_ source: String, widths: [String: Int]) -> String {
        let pattern = #"(?<![A-Za-z0-9_.])(float|float2|float3)\s+([A-Za-z_]\w*)\s*=\s*([^;\n]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let typeRange = Range(match.range(at: 1), in: result),
                  let valueRange = Range(match.range(at: 3), in: result) else { continue }
            let target = vectorWidth(ofType: String(result[typeRange]))
            guard let actual = expressionWidth(result[valueRange], widths: widths),
                  actual > target else { continue }
            result.replaceSubrange(
                valueRange,
                with: "(\(result[valueRange].trimmingCharacters(in: .whitespaces)))\(vectorSwizzle(width: target))"
            )
        }
        return result
    }

    /// fxc truncates a too-wide argument at a call boundary as well, not only inside a builtin:
    /// scene 3226487183's wave effect hands `ApplyBlending`'s `in float opacity` a vec3. Only
    /// functions DEFINED in this translation unit take part, so builtins keep Metal's own overload
    /// resolution (`mix` has its own narrowing pass above).
    private static func narrowUserFunctionArguments(
        _ source: String,
        widths: [String: Int],
        declarations: String
    ) -> String {
        let parameters = functionParameterWidths(in: source + "\n" + declarations)
        guard !parameters.isEmpty else { return source }
        var result = source
        for (name, parameterWidths) in parameters {
            var cursor = result.startIndex
            while let hit = result.range(of: name, range: cursor..<result.endIndex) {
                cursor = hit.upperBound
                guard hit.lowerBound == result.startIndex
                        || !isIdentifierCharacter(result[result.index(before: hit.lowerBound)]),
                      let close = closingDelimiter(in: result, after: hit.upperBound, open: "(", close: ")"),
                      let open = result[hit.upperBound..<close].firstIndex(of: "(") else { continue }
                // The definition's own parameter list, not a call.
                if let next = firstNonSpace(in: result, from: result.index(after: close)), result[next] == "{" {
                    continue
                }
                let arguments = topLevelArgumentRanges(in: result, open: open, close: close)
                guard arguments.count == parameterWidths.count else { continue }
                for (index, range) in arguments.enumerated().reversed() {
                    let target = parameterWidths[index]
                    guard target > 0,
                          let actual = expressionWidth(result[range], widths: widths),
                          actual > target else { continue }
                    result.replaceSubrange(
                        range,
                        with: "(\(result[range].trimmingCharacters(in: .whitespaces)))\(vectorSwizzle(width: target))"
                    )
                }
                cursor = result.index(after: hit.lowerBound)
            }
        }
        return result
    }

    /// Parameter widths per function DEFINED in `source`. A name defined more than once (GLSL
    /// allows overloads) is dropped — positional matching would pick an arbitrary signature.
    /// A parameter whose type is not a float vector maps to 0, meaning "leave this argument alone".
    private static func functionParameterWidths(in source: String) -> [String: [Int]] {
        // `functionDeclarations` arrives before the vec→float type substitution, so accept both.
        let pattern = #"\b(?:float[234]?|vec[234]|int|bool|void)\s+([A-Za-z_]\w*)\s*\(([^)]*)\)\s*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        var table: [String: [Int]] = [:]
        var overloaded: Set<String> = []
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let paramsRange = Range(match.range(at: 2), in: source) else { continue }
            let name = String(source[nameRange])
            let params = source[paramsRange].trimmingCharacters(in: .whitespaces)
            let widths: [Int] = params.isEmpty ? [] : params.split(separator: ",").map { parameter in
                // `const int mode` / `in float3 A` — the type is the token before the name, and
                // this pass runs before `stripInParameterQualifier`, so qualifiers are still here.
                let tokens = parameter.split(separator: " ", omittingEmptySubsequences: true)
                guard tokens.count >= 2 else { return 0 }
                let type = String(tokens[tokens.count - 2])
                switch type {
                case "float", "float2", "float3", "float4", "vec2", "vec3", "vec4":
                    return vectorWidth(ofType: type)
                default: return 0
                }
            }
            if table[name] != nil { overloaded.insert(name) }
            table[name] = widths
        }
        for name in overloaded { table.removeValue(forKey: name) }
        return table
    }

    /// Builtins whose result width is their arguments' width, so they can be seen through when
    /// judging an expression. Anything absent — `dot`, `length`, `determinant`, and every unknown —
    /// makes the judgement bail out instead of guessing.
    private static let componentWiseBuiltins: Set<String> = [
        "abs", "ceil", "clamp", "cos", "exp", "exp2", "floor", "fract", "log", "log2", "max", "min",
        "mix", "mod", "fmod", "normalize", "pow", "reflect", "round", "saturate", "sign", "sin",
        "sqrt", "step", "tan", "trunc", "wpe_smoothstep"
    ]

    /// Widest vector an expression can evaluate to, or nil when it cannot be judged from
    /// identifiers alone — a call that changes the width (`dot`, `length`) bails out rather than
    /// guess, while a component-wise builtin is transparent to its arguments.
    private static func expressionWidth(_ expression: Substring, widths: [String: Int]) -> Int? {
        let pattern = #"([A-Za-z_]\w*)\s*(\()?(?:\.([xyzwrgba]{1,4}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = String(expression)
        // A trailing swizzle states the width outright, whatever produced it: `float4(…).rgb` is
        // 3, not 4. Without this, an earlier narrowing pass's own output gets narrowed again.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if let dot = trimmed.lastIndex(of: "."), dot < trimmed.index(before: trimmed.endIndex) {
            let tail = trimmed[trimmed.index(after: dot)...]
            if tail.count <= 4, tail.allSatisfy({ "xyzwrgba".contains($0) }) { return tail.count }
        }
        var widest: Int?
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if match.range(at: 2).location != NSNotFound {
                guard let nameRange = Range(match.range(at: 1), in: text) else { return nil }
                let name = String(text[nameRange])
                if componentWiseBuiltins.contains(name) { continue }
                // A vector constructor's width is the type it builds, not its arguments'.
                guard ["float", "float2", "float3", "float4", "vec2", "vec3", "vec4"].contains(name) else {
                    return nil
                }
                widest = max(widest ?? 0, vectorWidth(ofType: name))
                continue
            }
            let width: Int
            if let swizzleRange = Range(match.range(at: 3), in: text) {
                width = text[swizzleRange].count
            } else if let nameRange = Range(match.range(at: 1), in: text),
                      let known = widths[String(text[nameRange])] {
                width = known
            } else {
                continue
            }
            widest = max(widest ?? 0, width)
        }
        return widest
    }

    /// Ranges of the comma-separated arguments between `open` and `close`, ignoring commas nested
    /// in parentheses or brackets.
    private static func topLevelArgumentRanges(
        in source: String,
        open: String.Index,
        close: String.Index
    ) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var depth = 0
        var start = source.index(after: open)
        var index = start
        while index < close {
            switch source[index] {
            case "(", "[": depth += 1
            case ")", "]": depth -= 1
            case "," where depth == 0:
                ranges.append(start..<index)
                start = source.index(after: index)
            default: break
            }
            index = source.index(after: index)
        }
        if start < close || !ranges.isEmpty { ranges.append(start..<close) }
        return ranges
    }

    private static func firstNonSpace(in source: String, from start: String.Index) -> String.Index? {
        var index = start
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
        return index < source.endIndex ? index : nil
    }

    /// Index of the delimiter closing an `open` that starts at the first non-space character at or
    /// after `start`; nil when that character is not `open`.
    private static func closingDelimiter(
        in source: String,
        after start: String.Index,
        open: Character,
        close: Character
    ) -> String.Index? {
        guard let index = firstNonSpace(in: source, from: start), source[index] == open else { return nil }
        var depth = 0
        var cursor = index
        while cursor < source.endIndex {
            if source[cursor] == open { depth += 1 }
            if source[cursor] == close {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    /// HLSL's `distance` accepts scalars; MSL declares only the vector overloads, so a scalar call
    /// is ambiguous. Rewrite it to the identity `abs(a - b)`. Both operands must be a literal or a
    /// known-scalar identifier — anything else keeps the real `distance`.
    private static func lowerScalarDistanceCalls(_ source: String, widths: [String: Int]) -> String {
        let pattern = #"\bdistance\s*\(\s*([A-Za-z_]\w*|[0-9.]+)\s*,\s*([A-Za-z_]\w*|[0-9.]+)\s*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let lhsRange = Range(match.range(at: 1), in: result),
                  let rhsRange = Range(match.range(at: 2), in: result) else { continue }
            let lhs = String(result[lhsRange])
            let rhs = String(result[rhsRange])
            func isScalar(_ token: String) -> Bool {
                guard let first = token.first else { return false }
                return isIdentifierStart(first) ? widths[token] == 1 : true
            }
            guard isScalar(lhs), isScalar(rhs) else { continue }
            result.replaceSubrange(fullRange, with: "abs((\(lhs)) - (\(rhs)))")
        }
        return result
    }

    private static func vectorWidth(ofType type: String) -> Int {
        switch type {
        case "float2", "vec2": return 2
        case "float3", "vec3": return 3
        case "float4", "vec4": return 4
        default: return 1
        }
    }

    private static func vectorSwizzle(width: Int) -> String {
        String(".xyzw".prefix(width + 1))
    }

    /// `spectrum[i / 4][i % 4]` on a `float[N]` uniform means `spectrum[i / 4]` under fxc. WPE's
    /// own shaders index these arrays with a single bracket
    /// (`assets/zcompat/scene/shaders/2084198056/Simple_Audio_Bars.frag`), so the array really is
    /// `float[N]`, not a packed `float4[N/4]`. Genuine `float4[N]` arrays (the `audioValue`
    /// varying) are two-dimensional for real and are never in `names`.
    private static func dropScalarArrayInnerSubscripts(_ source: String, names: Set<String>) -> String {
        guard !names.isEmpty else { return source }
        var result = source
        for name in names {
            var cursor = result.startIndex
            while let hit = result.range(of: name, range: cursor..<result.endIndex) {
                cursor = hit.upperBound
                guard hit.lowerBound == result.startIndex
                        || !isIdentifierCharacter(result[result.index(before: hit.lowerBound)]),
                      let firstClose = closingBracket(in: result, after: hit.upperBound),
                      let secondClose = closingBracket(in: result, after: result.index(after: firstClose)),
                      let firstOpen = result[hit.upperBound..<firstClose].firstIndex(of: "[") else { continue }
                let index = result[result.index(after: firstOpen)..<firstClose]
                let replacement = "\(name)[int(\(index))]"
                result.replaceSubrange(hit.lowerBound...secondClose, with: replacement)
                cursor = result.index(hit.lowerBound, offsetBy: replacement.count)
            }
        }
        return result
    }

    /// Index of the `]` closing a `[` that starts at the first non-space character at or after
    /// `start`; nil when that character is not `[`.
    private static func closingBracket(in source: String, after start: String.Index) -> String.Index? {
        var index = start
        while index < source.endIndex, source[index] == " " || source[index] == "\t" {
            index = source.index(after: index)
        }
        guard index < source.endIndex, source[index] == "[" else { return nil }
        var depth = 0
        while index < source.endIndex {
            if source[index] == "[" { depth += 1 }
            if source[index] == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// `mix(float3, float4, t)` — fxc truncates the wider argument; Metal has no matching overload.
    private static func narrowMixArguments(_ source: String, widths: [String: Int]) -> String {
        let pattern = #"\bmix\s*\(\s*([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*)\s*(?=,)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let lhsRange = Range(match.range(at: 1), in: result),
                  let rhsRange = Range(match.range(at: 2), in: result) else { continue }
            guard let lhs = widths[String(result[lhsRange])],
                  let rhs = widths[String(result[rhsRange])],
                  lhs != rhs, min(lhs, rhs) > 1 else { continue }
            let widerRange = lhs > rhs ? lhsRange : rhsRange
            result.replaceSubrange(
                widerRange,
                with: result[widerRange] + vectorSwizzle(width: min(lhs, rhs))
            )
        }
        return result
    }

    /// `float3 f() { float4 col; … return col; }` — fxc truncates on return, Metal refuses to.
    private static func narrowWideReturns(_ source: String, widths: [String: Int]) -> String {
        let headerPattern = #"\b(float2|float3)\s+[A-Za-z_]\w*\s*\([^)]*\)\s*\{"#
        guard let headerRegex = try? NSRegularExpression(pattern: headerPattern) else { return source }
        var result = source
        for match in headerRegex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let headerRange = Range(match.range, in: result),
                  let typeRange = Range(match.range(at: 1), in: result) else { continue }
            let returnWidth = vectorWidth(ofType: String(result[typeRange]))
            guard let bodyEnd = closingBrace(in: result, openedAt: result.index(before: headerRange.upperBound)) else {
                continue
            }
            let body = String(result[headerRange.upperBound..<bodyEnd])
            guard let returnRegex = try? NSRegularExpression(pattern: #"\breturn\s+([A-Za-z_]\w*)\s*;"#) else { continue }
            var rewritten = body
            for hit in returnRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)).reversed() {
                guard let nameRange = Range(hit.range(at: 1), in: rewritten),
                      let width = widths[String(rewritten[nameRange])],
                      width > returnWidth else { continue }
                rewritten.replaceSubrange(
                    nameRange,
                    with: rewritten[nameRange] + vectorSwizzle(width: returnWidth)
                )
            }
            result.replaceSubrange(headerRange.upperBound..<bodyEnd, with: rewritten)
        }
        return result
    }

    private static func closingBrace(in source: String, openedAt open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Rewrite GLSL `inout T name` / `out T name` parameter qualifiers to Metal's `thread T& name`.
    private static func rewriteReferenceParameters(_ source: String) -> String {
        let pattern = #"\b(inout|out)\s+([A-Za-z_][A-Za-z0-9_]*(?:\d+x\d+)?)\s+([A-Za-z_][A-Za-z0-9_]*)(?=\s*[,)])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "thread $2& $3"
        )
    }

    /// Strip GLSL's `in T name` parameter qualifier (MSL has no equivalent — `in` is the implicit default).
    private static func stripInParameterQualifier(_ source: String) -> String {
        let pattern = #"\bin\s+([A-Za-z_][A-Za-z0-9_]*(?:\d+x\d+)?)\s+([A-Za-z_][A-Za-z0-9_]*)(?=\s*[,)])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "$1 $2"
        )
    }

    /// Scrub WPE fragment `out` declarations (`out vec4 out_FragColor;` and `out vec4 wpe_fragColor;`, plus their already-substituted `float4` twins) from anywhere in the source.
    static func scrubFragmentOutDeclarations(_ source: String) -> String {
        let pattern = #"out\s+(vec4|float4)\s+(wpe_fragColor|out_FragColor)\s*;\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: ""
        )
    }

    /// Substring replacement that respects identifier boundaries.
    private static func wordReplace(_ source: String, find: String, replace: String) -> String {
        guard !find.isEmpty else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix(find) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                let afterIndex = source.index(index, offsetBy: find.count)
                let nextOK: Bool
                if afterIndex >= source.endIndex {
                    nextOK = true
                } else {
                    let n = source[afterIndex]
                    nextOK = !n.isLetter && !n.isNumber && n != "_"
                }
                if priorOK && nextOK {
                    result += replace
                    index = afterIndex
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Identifier replacement variant for expressions where an existing
    /// swizzle/member access must be left alone.
    private static func wordReplaceUnlessMemberAccess(_ source: String, find: String, replace: String) -> String {
        guard !find.isEmpty else { return source }
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix(find) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                let afterIndex = source.index(index, offsetBy: find.count)
                let nextOK: Bool
                if afterIndex >= source.endIndex {
                    nextOK = true
                } else {
                    let n = source[afterIndex]
                    nextOK = !n.isLetter && !n.isNumber && n != "_" && n != "."
                }
                if priorOK && nextOK {
                    result += replace
                    index = afterIndex
                    continue
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Rewrite `textureLod(<sampler>, <uv>, <lod>)` (from WPE's `texSample2DLod`)
    /// into Metal `<sampler>.sample(linearSampler, <uv>, level(<lod>))`. `level()`
    /// is the MSL explicit-LOD specifier; without this the literal `textureLod`
    /// survives and `makeLibrary` fails. Runs before `rewriteTextureCalls` so the
    /// `texture(` pass never sees `textureLod`.
    private static func rewriteTextureLodCalls(
        _ source: String,
        premultipliedInputSlots: Set<Int> = [],
        repeatSamplers: Set<String> = []
    ) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        let needle = "textureLod("
        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                if priorOK {
                    var cursor = source.index(index, offsetBy: needle.count)
                    var depth = 1
                    var commaIndices: [String.Index] = []
                    while cursor < source.endIndex && depth > 0 {
                        let ch = source[cursor]
                        if ch == "(" { depth += 1 }
                        else if ch == ")" { depth -= 1 }
                        else if ch == "," && depth == 1 {
                            commaIndices.append(cursor)
                        }
                        if depth > 0 {
                            cursor = source.index(after: cursor)
                        }
                    }
                    if let firstComma = commaIndices.first,
                       let lodComma = commaIndices.last,
                       firstComma != lodComma,
                       cursor < source.endIndex {
                        let argStart = source.index(index, offsetBy: needle.count)
                        // Recurse on uv/lod so a textureLod nested inside another
                        // textureLod's arguments is also rewritten (the sampler arg is
                        // always a plain identifier and cannot nest a call).
                        let sampler = source[argStart..<firstComma]
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let uv = rewriteTextureLodCalls(
                            String(source[source.index(after: firstComma)..<lodComma]),
                            premultipliedInputSlots: premultipliedInputSlots,
                            repeatSamplers: repeatSamplers
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        let lod = rewriteTextureLodCalls(
                            String(source[source.index(after: lodComma)..<cursor]),
                            premultipliedInputSlots: premultipliedInputSlots,
                            repeatSamplers: repeatSamplers
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        let samplerState = repeatSamplers.contains(sampler) ? "repeatSampler" : "linearSampler"
                        var sample = "\(sampler).sample(\(samplerState), \(uv), level(\(lod)))"
                        if shouldUnpremultiplySample(sampler: sampler, premultipliedInputSlots: premultipliedInputSlots) {
                            sample = "wpe_unpremultiply_sample(\(sample))"
                        }
                        result += sample
                        index = source.index(after: cursor)
                        continue
                    }
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// Rewrite `texture(<sampler>, <uv>)` calls (already canonicalised by the preprocessor) into Metal `<sampler>.sample(linearSampler, uv)` form.
    private static func rewriteTextureCalls(
        _ source: String,
        premultipliedInputSlots: Set<Int> = [],
        repeatSamplers: Set<String> = []
    ) -> String {
        var result = ""
        result.reserveCapacity(source.count)
        var index = source.startIndex
        let needle = "texture("
        while index < source.endIndex {
            if source[index...].hasPrefix(needle) {
                let priorOK: Bool
                if index == source.startIndex {
                    priorOK = true
                } else {
                    let p = source[source.index(before: index)]
                    priorOK = !p.isLetter && !p.isNumber && p != "_"
                }
                if priorOK {
                    var cursor = source.index(index, offsetBy: needle.count)
                    var depth = 1
                    var commaIndex: String.Index?
                    while cursor < source.endIndex && depth > 0 {
                        let ch = source[cursor]
                        if ch == "(" { depth += 1 }
                        else if ch == ")" { depth -= 1 }
                        else if ch == "," && depth == 1 && commaIndex == nil {
                            commaIndex = cursor
                        }
                        if depth > 0 {
                            cursor = source.index(after: cursor)
                        }
                    }
                    if let comma = commaIndex, cursor < source.endIndex {
                        let argStart = source.index(index, offsetBy: needle.count)
                        let sampler = source[argStart..<comma].trimmingCharacters(in: .whitespacesAndNewlines)
                        // Recurse on the uv arg so a `texture(…)` nested inside it is
                        // also rewritten (Metal has no free-function `texture`). The
                        // sampler arg is always a bare identifier and cannot nest.
                        let uv = rewriteTextureCalls(
                            String(source[source.index(after: comma)..<cursor]),
                            premultipliedInputSlots: premultipliedInputSlots,
                            repeatSamplers: repeatSamplers
                        ).trimmingCharacters(in: .whitespacesAndNewlines)
                        let samplerState = repeatSamplers.contains(sampler) ? "repeatSampler" : "linearSampler"
                        var sample = "\(sampler).sample(\(samplerState), \(uv))"
                        if shouldUnpremultiplySample(sampler: sampler, premultipliedInputSlots: premultipliedInputSlots) {
                            sample = "wpe_unpremultiply_sample(\(sample))"
                        }
                        result += sample
                        index = source.index(after: cursor)
                        continue
                    }
                }
            }
            result.append(source[index])
            index = source.index(after: index)
        }
        return result
    }

    /// A sampler slot bound to a premultiplied render target must be
    /// un-premultiplied before the shader's straight-alpha math runs.
    private static func shouldUnpremultiplySample(
        sampler: String,
        premultipliedInputSlots: Set<Int>
    ) -> Bool {
        guard !premultipliedInputSlots.isEmpty,
              let slot = textureSlot(for: sampler) else { return false }
        return premultipliedInputSlots.contains(slot)
    }

}
#endif
