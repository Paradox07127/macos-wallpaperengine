#if !LITE_BUILD
import Foundation

extension WPEShaderTranspiler {
    /// GLSL interpolation permits extrapolation; MSL's mix does not. These
    /// overloads use arithmetic for numeric factors and selection for booleans.
    /// In particular, an unselected NaN must not enter a boolean mix via 0*NaN.
    static var glslMathPrelude: String {
        var lines = [
            "inline float wpe_smoothstep(float edge0, float edge1, float x) {",
            "    if (edge0 == edge1) { return x < edge0 ? 0.0 : 1.0; }",
            "    float t = metal::clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);",
            "    return t * t * (3.0 - 2.0 * t);",
            "}",
        ]
        // Equal edges retain the historical hard threshold; reverse edges are
        // an explicit WPE extension. Neither policy replaces a nonzero width.
        for width in 2 ... 4 {
            let type = "float\(width)"
            let components = Array("xyzw".prefix(width)).map(String.init)
            let calls = components.map { "wpe_smoothstep(edge0.\($0), edge1.\($0), x.\($0))" }
            lines.append("inline \(type) wpe_smoothstep(\(type) edge0, \(type) edge1, \(type) x) { return \(type)(\(calls.joined(separator: ", "))); }")
            lines.append("inline \(type) wpe_smoothstep(float edge0, float edge1, \(type) x) { return wpe_smoothstep(\(type)(edge0), \(type)(edge1), x); }")
        }
        for width in 1 ... 4 {
            let type = width == 1 ? "float" : "float\(width)"
            let factorTypes = width == 1 ? ["float", "int", "uint"] : ["float", type, "int", "uint"]
            let endpoints = width == 1 ? [(type, type)] : [(type, type), ("float", type), (type, "float")]
            for (lhs, rhs) in endpoints {
                for factor in factorTypes {
                    let factorCast = factor == "int" || factor == "uint" ? "float(a)" : "a"
                    // Weighted sum also avoids overflowing (y-x) for opposite
                    // large finite endpoints in a valid interpolation interval.
                    lines.append("inline \(type) wpe_glsl_mix(\(lhs) x, \(rhs) y, \(factor) a) { return (1.0 - \(factorCast)) * x + \(factorCast) * y; }")
                }
            }
        }
        // Permissive HLSL literals: numeric mix(0, 1, t) must not choose the
        // integer boolean-selector overload by converting t to bool.
        for type in ["int", "uint"] {
            for factor in ["float", "int", "uint"] {
                lines.append("inline float wpe_glsl_mix(\(type) x, \(type) y, \(factor) a) { return (1.0 - float(a)) * float(x) + float(a) * float(y); }")
            }
        }
        // Mixed scalar endpoints (`mix(x, 1, t)`) are otherwise ambiguous between the float and int overloads above.
        for (lhs, rhs) in [("float", "int"), ("int", "float"), ("float", "uint"), ("uint", "float"), ("int", "uint"), ("uint", "int")] {
            for factor in ["float", "int", "uint"] {
                lines.append("inline float wpe_glsl_mix(\(lhs) x, \(rhs) y, \(factor) a) { return (1.0 - float(a)) * float(x) + float(a) * float(y); }")
            }
            lines.append("inline float wpe_glsl_mix(\(lhs) x, \(rhs) y, bool a) { return a ? float(y) : float(x); }")
        }
        for scalar in ["float", "int", "uint", "bool"] {
            lines.append("inline \(scalar) wpe_glsl_mix(\(scalar) x, \(scalar) y, bool a) { return a ? y : x; }")
            for width in 2 ... 4 {
                let type = "\(scalar)\(width)"
                let components = Array("xyzw".prefix(width)).map(String.init)
                let selected = components.map { "a.\($0) ? y.\($0) : x.\($0)" }.joined(separator: ", ")
                lines.append("inline \(type) wpe_glsl_mix(\(type) x, \(type) y, bool\(width) a) { return \(type)(\(selected)); }")
                lines.append("inline \(type) wpe_glsl_mix(\(type) x, \(type) y, bool a) { return a ? y : x; }")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// GLSL declarations introduce name ownership from their position onward. A
    /// helper *before* the first authored mix declaration can still call the builtin.
    /// Protect those calls before resource threading appends the author's uniforms
    /// to every remaining call with that name. Later calls/macros stay conservative.
    static func routingMixBeforeAuthoredDeclaration(in source: String) -> String {
        let masked = maskComments(source)
        guard !masked.contains("\\\n"),
              masked.range(of: #"(?m)^\s*#\s*define\s+mix(?:\s|\()"#, options: .regularExpression) == nil,
              let first = parseHelperFunctions(in: masked).first(where: { $0.name == "mix" }),
              let declarations = try? NSRegularExpression(pattern: #"\b([A-Za-z_]\w*)\s+(mix)\s*\("#),
              let calls = try? NSRegularExpression(pattern: #"(?<![:A-Za-z0-9_])mix\s*\("#) else {
            return source
        }
        var boundary = first.parameterRange.lowerBound
        // Include forward prototypes in the ownership boundary. A return statement
        // is a call, not a declaration; other uncertain tokens only narrow this scope.
        for match in declarations.matches(in: masked, range: NSRange(masked.startIndex ..< boundary, in: masked)) {
            guard let type = Range(match.range(at: 1), in: masked), masked[type] != "return",
                  let name = Range(match.range(at: 2), in: masked) else { continue }
            boundary = min(boundary, name.lowerBound)
        }
        var replacements: [Range<String.Index>] = []
        for match in calls.matches(in: masked, range: NSRange(masked.startIndex ..< boundary, in: masked)) {
            guard let range = Range(match.range, in: masked) else { continue }
            let lineStart = masked[..<range.lowerBound].lastIndex(of: "\n").map { masked.index(after: $0) } ?? masked.startIndex
            // Do not mutate macro definitions; expansion and name ownership are a
            // separate concern, especially when an alias is invoked after the boundary.
            guard !masked[lineStart ..< range.lowerBound].trimmingCharacters(in: .whitespaces).hasPrefix("#") else { continue }
            let open = masked.index(before: range.upperBound)
            guard let close = matchingDelimiter(in: masked, open: open, openChar: "(", closeChar: ")"),
                  close < boundary, topLevelArgumentRanges(in: masked, open: open, close: close).count == 3 else { continue }
            let lower = source.index(source.startIndex, offsetBy: masked.distance(from: masked.startIndex, to: range.lowerBound))
            replacements.append(lower ..< source.index(lower, offsetBy: 3))
        }
        var result = source
        for range in replacements.reversed() {
            result.replaceSubrange(range, with: "wpe_glsl_mix")
        }
        return result
    }

    /// Prepended to the MSL when routing is skipped; remaining unqualified calls in that shader keep `metal::mix` semantics (no extrapolation guarantee).
    static let authoredMixDiagnostic = "// WPE-DIAGNOSTIC: mix routing skipped (authored mix): the shader defines its own mix, so remaining unqualified mix calls keep authored/metal::mix semantics."

    /// Run after HLSL narrowing/resource threading. Do not retarget an authored
    /// mix function or macro: that name belongs to the shader, not the intrinsic.
    /// Qualified metal::mix and comments likewise retain their original meaning.
    static func routingGLSLMixCalls(in source: String, authoredHelpers: String, authoredMain: String) -> String {
        let authored = authoredHelpers + "\n" + authoredMain
        if parseHelperFunctions(in: maskComments(authoredHelpers)).contains(where: { $0.name == "mix" })
            || maskComments(authored).range(of: #"(?m)^\s*#\s*define\s+mix(?:\s|\()"#, options: .regularExpression) != nil {
            return authoredMixDiagnostic + "\n" + source
        }
        let masked = maskComments(source)
        // Also route an object-like alias (#define INTERPOLATE mix), which does
        // not have '(' until the preprocessor expands a later invocation.
        let patterns = [#"(?<![:A-Za-z0-9_])mix(?=\s*\()"#, #"(?m)(?<=\s)mix(?=\s*$)"#]
        var ranges: [Range<String.Index>] = []
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: masked, range: NSRange(masked.startIndex..., in: masked)) {
                guard let range = Range(match.range, in: masked) else { continue }
                if index == 1 {
                    let lineStart = masked[..<range.lowerBound].lastIndex(of: "\n").map { masked.index(after: $0) } ?? masked.startIndex
                    let prefix = masked[lineStart ..< range.lowerBound]
                    guard prefix.range(of: #"^\s*#\s*define\s+[A-Za-z_]\w*\s+$"#, options: .regularExpression) != nil else { continue }
                }
                let lower = source.index(source.startIndex, offsetBy: masked.distance(from: masked.startIndex, to: range.lowerBound))
                let upper = source.index(source.startIndex, offsetBy: masked.distance(from: masked.startIndex, to: range.upperBound))
                ranges.append(lower ..< upper)
            }
        }
        var result = source
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            result.replaceSubrange(range, with: "wpe_glsl_mix")
        }
        return result
    }
}
#endif
