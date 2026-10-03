#if !LITE_BUILD
import Foundation

/// Declaration-based ABI shared by both real stages. This is not Metal reflection.
/// Unsupported shapes fail the link; they never disappear into a reconstructed UV.
struct WPEShaderStageLink {
    static func usesMVPOnlyForLocalEffectPosition(_ source: String, fragment: String) -> Bool {
        let active = WPEShaderTranspiler.maskComments(WPEShaderTranspiler.stripInactivePreprocessorBranches(in: source))
        return WPELocalEffectPositionProof(source: active, fragment: fragment)?.isProven() == true
    }

    /// Conservative admission proof for the native fullscreen clip matrix. It is
    /// not a proof of WPE's Z projection: depth testing/writes remain separate.
    static func usesMVPOnlyForFullscreenPosition(_ source: String, fragment: String? = nil) -> Bool {
        var active = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: source)
        active = WPEShaderTranspiler.maskComments(active)
        if let fragment {
            active = excludingUnconsumedPureWrites(active, fragment: fragment)
        }
        if let mainRange = WPEShaderTranspiler.locateMain(in: active),
           let aliases = try? NSRegularExpression(pattern: #"\b(?:const\s+)?vec3\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*a_Position\s*;"#) {
            var main = String(active[mainRange])
            let ns = main as NSString
            let declarations = aliases.matches(in: main, range: NSRange(main.startIndex..., in: main))
            for declaration in declarations where declarations.count == 1 {
                let name = ns.substring(with: declaration.range(at: 1))
                guard let identifier = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"),
                      identifier.numberOfMatches(in: main, range: NSRange(main.startIndex..., in: main)) == 2 else { continue }
                // One declaration and one read: no component writes, helper
                // arguments, shadowing or additional position-space consumers.
                main = (main as NSString).replacingCharacters(in: declaration.range, with: "")
                main = identifier.stringByReplacingMatches(in: main, range: NSRange(main.startIndex..., in: main), withTemplate: "a_Position")
            }
            active.replaceSubrange(mainRange, with: main)
        }
        // The local effect quad is normalized even when WPE draws the final
        // effect with raw pixel vertices. Only the coupled XY/W projection is
        // invariant under that change of basis; raw arithmetic and Z are not.
        let effectRead = #"mul\s*\(\s*vec4\s*\(\s*a_Position\s*,\s*1(?:\.0*)?\s*\)\s*,\s*g_EffectModelViewProjectionMatrix\s*\)\s*\.(xyw|xy)\b"#
        active = active.replacingOccurrences(of: effectRead, with: "vec3(0.0)", options: .regularExpression)
        active = active.replacingOccurrences(of: #"\buniform\s+mat4\s+g_EffectModelViewProjectionMatrix\s*;"#, with: "", options: .regularExpression)
        // A declaration-only inverse does not consume a different position
        // basis. Any actual inverse read remains below and rejects admission.
        active = active.replacingOccurrences(of: #"\buniform\s+mat4\s+g_ModelViewProjectionMatrixInverse\s*;"#, with: "", options: .regularExpression)
        active = active.replacingOccurrences(of: #"\buniform\s+mat4\s+g_ModelViewProjectionMatrix\s*;"#, with: "", options: .regularExpression)
        let position = #"(?:vec4\s*\(\s*a_Position\s*,\s*1(?:\.0*)?\s*\)|vec4\s*\(\s*a_Position\.xy\s*,\s*0(?:\.0*)?\s*,\s*1(?:\.0*)?\s*\)|a_Position)"#
        let matrix = "g_ModelViewProjectionMatrix"
        let assignment = #"\bgl_Position\s*=\s*(?:"#
            + matrix + #"\s*\*\s*"# + position
            + #"|mul\s*\(\s*"# + position + #"\s*,\s*"# + matrix + #"\s*\)"#
            + #"|mul\s*\(\s*"# + matrix + #"\s*,\s*"# + position + #"\s*\)"#
            + "|" + position + #")\s*;"#
        guard let match = active.range(of: assignment, options: .regularExpression) else { return false }
        active.removeSubrange(match)
        active = active.replacingOccurrences(of: #"\b(?:attribute|in)\s+(?:vec3|vec4)\s+a_Position\s*;"#, with: "", options: .regularExpression)
        // The supplied attribute is clip XY. Raw authored position arithmetic
        // needs its own coordinate producer, even without another matrix read.
        return !active.contains("g_ModelViewProjectionMatrix") && !active.contains("gl_Position") && !active.contains("a_Position") && !active.contains("g_EffectModelViewProjectionMatrix")
    }

    /// Only the admission analysis is sliced. Actual authored VS code remains
    /// intact. An unused FS binding alone is insufficient: other VS reads or
    /// impure expressions keep the entire computation required.
    private static func excludingUnconsumedPureWrites(_ source: String, fragment: String) -> String {
        let interface = WPEShaderInterfaceParser.parse(vertex: source, fragment: fragment)
        let outputs = interface.variables(stage: .vertex, kind: .varyingOutput)
        let unused = Set(interface.unreferencedFragmentInputs ?? [])
        let consumed = Set(interface.variables(stage: .fragment, kind: .varyingInput).filter {
            !unused.contains($0.key.name)
        }.compactMap { matchingOutput(for: $0, in: outputs)?.key.name })
        var result = source
        for output in outputs where output.arrayDimensions.isEmpty && !consumed.contains(output.key.name) {
            let name = NSRegularExpression.escapedPattern(for: output.key.name)
            let writes = #"(?<=[;{}])\s*"# + name + #"(?:\.[xyzwrgba]{1,4})?\s*(?:=|\+=|-=|\*=|/=)\s*([^;{}]+);"#
            guard let regex = try? NSRegularExpression(pattern: writes) else { continue }
            let text = result as NSString
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            guard !matches.isEmpty, matches.allSatisfy({ pureWriteExpression(text.substring(with: $0.range(at: 1)), source: source) }) else { continue }
            var candidate = result
            for match in matches.reversed() {
                candidate = (candidate as NSString).replacingCharacters(in: match.range, with: "")
            }
            let declaration = #"\b(?:varying|out)\s+(?:(?:highp|mediump|lowp)\s+)?[A-Za-z_]\w*\s+"# + name + #"\s*;"#
            candidate = candidate.replacingOccurrences(of: declaration, with: "", options: .regularExpression)
            // A relay into another varying, a helper read, loop condition or
            // shadowed local retains the original source, including inverse use.
            guard candidate.range(of: "\\b" + name + "\\b", options: .regularExpression) == nil else { continue }
            result = candidate
        }
        return result
    }

    private static func pureWriteExpression(_ expression: String, source: String) -> Bool {
        guard expression.range(of: #"[^A-Za-z0-9_\s.()+*/\[\],-]|\+\+|--"#, options: .regularExpression) == nil,
              let calls = try? NSRegularExpression(pattern: #"\b([A-Za-z_]\w*)\s*\("#) else { return false }
        // Object-like macros can hide increments or function calls as well.
        // Only the canonical multiply macro is proved below; other referenced
        // macro bodies are deliberately not guessed to be pure.
        let definitions = source.components(separatedBy: "\n")
        for line in definitions {
            guard let names = try? NSRegularExpression(pattern: #"^\s*#\s*define\s+([A-Za-z_]\w*)"#),
                  let declaration = names.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
            let macroName = (line as NSString).substring(with: declaration.range(at: 1))
            if macroName != "mul", expression.range(of: "\\b" + NSRegularExpression.escapedPattern(for: macroName) + "\\b", options: .regularExpression) != nil {
                return false
            }
        }
        let text = expression as NSString
        for match in calls.matches(in: expression, range: NSRange(expression.startIndex..., in: expression)) {
            let name = text.substring(with: match.range(at: 1))
            if ["vec2", "vec3", "vec4", "mat2", "mat3", "mat4"].contains(name) {
                continue
            }
            guard name == "mul", source.range(of: #"(?m)^\s*(?:(?:highp|mediump|lowp)\s+)?[A-Za-z_]\w*\s+mul\s*\([^()]*\)\s*\{"#, options: .regularExpression) == nil else { return false }
            let definitions = source.components(separatedBy: "\n").filter { $0.range(of: #"^\s*#\s*define\s+mul\b"#, options: .regularExpression) != nil }
            for definition in definitions {
                guard let macro = try? NSRegularExpression(pattern: #"^\s*#\s*define\s+mul\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)\s*(.*)$"#),
                      let declaration = macro.firstMatch(in: definition, range: NSRange(definition.startIndex..., in: definition)) else { return false }
                let line = definition as NSString
                var body = line.substring(with: declaration.range(at: 3))
                for index in [1, 2] {
                    body = body.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: line.substring(with: declaration.range(at: index))) + "\\b",
                                                     with: "", options: .regularExpression)
                }
                guard body.range(of: #"[^\s()*]"#, options: .regularExpression) == nil else { return false }
            }
        }
        return true
    }

    struct Varying {
        let variable: WPEShaderInterfaceVariable
        let metalType: String
        let elementCount: Int
        let isArray: Bool
        let fieldIndex: Int

        var name: String {
            variable.key.name
        }

        func field(_ element: Int) -> String {
            "wpe_v\(fieldIndex)_\(element)"
        }

        var interpolation: String {
            switch variable.interpolation {
            case .flat: "flat"
            case .smooth: variable.centroid ? "centroid_perspective" : "center_perspective"
            case .noperspective: variable.centroid ? "centroid_no_perspective" : "center_no_perspective"
            }
        }

        var declaration: String {
            "\(metalType) \(name)" + (isArray ? "[\(elementCount)]" : "")
        }
    }

    let interface: WPEShaderInterface
    let varyings: [Varying]
    private let promotedFragmentInputs: Set<String>

    init(vertex: String, fragment: String) throws {
        let inventory = WPEShaderInterfaceParser.parse(vertex: vertex, fragment: fragment)
        interface = inventory
        let activeFragment = WPEShaderTranspiler.maskComments(WPEShaderTranspiler.stripInactivePreprocessorBranches(in: fragment))
        promotedFragmentInputs = Set(inventory.variables(stage: .fragment, kind: .varyingInput).filter { input in
            guard input.arrayDimensions.isEmpty,
                  let output = Self.matchingOutput(for: input, in: inventory.variables(stage: .vertex, kind: .varyingOutput)),
                  output.arrayDimensions.isEmpty, let declaredWidth = Self.floatWidth(input.glslType),
                  let producedWidth = Self.floatWidth(output.glslType), declaredWidth < producedWidth,
                  let swizzles = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: input.key.name) + #"\s*\.\s*([xyzwrgba]{1,4})\b"#) else { return false }
            let text = activeFragment as NSString
            return swizzles.matches(in: activeFragment, range: NSRange(activeFragment.startIndex..., in: activeFragment)).contains { match in
                let axes = Array("xyzw"), colors = Array("rgba")
                let channels = text.substring(with: match.range(at: 1)).compactMap { axes.firstIndex(of: $0) ?? colors.firstIndex(of: $0) }
                return channels.contains { $0 >= declaredWidth } && channels.allSatisfy { $0 < producedWidth }
            }
        }.map(\.key.name))
        let unreferenced = Set(inventory.unreferencedFragmentInputs ?? [])
        let requiredIssues = inventory.issues.filter { issue in
            if issue.stage == .fragment, issue.name.map(unreferenced.contains) == true,
               [.missingVertexOutput, .varyingTypeMismatch].contains(issue.code) {
                return false
            }
            if issue.code == .varyingTypeMismatch, issue.stage == .fragment,
               let input = inventory.variables(stage: .fragment, kind: .varyingInput).first(where: { $0.key.name == issue.name }),
               let output = Self.matchingOutput(for: input, in: inventory.variables(stage: .vertex, kind: .varyingOutput)),
               Self.canConsumeFloatPrefix(input: input, output: output, fragment: fragment) {
                return false
            }
            return true
        }
        guard interface.hasVertexSource, requiredIssues.isEmpty else {
            throw WPEShaderCompilerError.translationFailed("authored stage interface cannot link: \(requiredIssues.map(\.code.rawValue).joined(separator: ","))")
        }
        let attributes = interface.variables(stage: .vertex, kind: .attribute)
        guard attributes.allSatisfy({
            $0.arrayDimensions.isEmpty && (($0.key.name == "a_Position" && ["vec3", "vec4"].contains($0.glslType))
                || ($0.key.name == "a_TexCoord" && ["vec2", "vec4"].contains($0.glslType)))
        }) else { throw WPEShaderCompilerError.translationFailed("authored fullscreen stage has unsupported attributes") }
        var total = 0
        varyings = try interface.variables(stage: .vertex, kind: .varyingOutput).enumerated().map { index, v in
            guard let type = WPEUniformType(glslType: v.glslType), type.elementSlotCount == 1,
                  !v.glslType.hasPrefix("bool"), !v.glslType.hasPrefix("bvec"), !v.sample,
                  v.arrayDimensions.count <= 1 else {
                throw WPEShaderCompilerError.translationFailed("unsupported authored varying '\(v.key.name)'")
            }
            let count: Int
            if let dimension = v.arrayDimensions.first, let value = Int(dimension), value > 0 {
                count = value
            } else if v.arrayDimensions.isEmpty {
                count = 1
            } else {
                throw WPEShaderCompilerError.translationFailed("unresolved authored varying extent '\(v.key.name)'")
            }
            guard count <= WPEShaderTranspiler.varyingElementMaximum - total else {
                throw WPEShaderCompilerError.translationFailed("authored varying interface exceeds the element budget")
            }
            total += count
            if v.glslType.hasPrefix("i") || v.glslType.hasPrefix("u") {
                guard v.interpolation == .flat else {
                    throw WPEShaderCompilerError.translationFailed("integer varying '\(v.key.name)' requires flat interpolation")
                }
            }
            return Varying(variable: v, metalType: type.metalType, elementCount: count,
                           isArray: !v.arrayDimensions.isEmpty, fieldIndex: index)
        }
    }

    var stageInDeclaration: String {
        var fields = ["struct WPEStageIn {", "    float4 position [[position]];", "    float2 uv;"]
        for varying in varyings {
            for element in 0 ..< varying.elementCount {
                fields.append("    \(varying.metalType) \(varying.field(element)) [[user(\(varying.field(element))), \(varying.interpolation)]];")
            }
        }
        fields.append("};")
        return fields.joined(separator: "\n")
    }

    struct FragmentBinding {
        let input: WPEShaderInterfaceVariable
        let output: Varying
        /// Windows binds the VS's physical channels even if an FS declaration
        /// is narrower. Promote only when those extra channels are referenced.
        let usesProducedWidth: Bool

        var glslType: String {
            usesProducedWidth ? output.variable.glslType : input.glslType
        }

        var metalType: String {
            WPEUniformDecl.mapType(glslType)
        }

        var declaration: String {
            metalType + " " + input.key.name + (output.isArray ? "[\(output.elementCount)]" : "")
        }

        func value(_ element: Int) -> String {
            let source = "in." + output.field(element)
            if usesProducedWidth {
                return source
            }
            guard let inputWidth = WPEShaderStageLink.floatWidth(input.glslType),
                  let outputWidth = WPEShaderStageLink.floatWidth(output.variable.glslType), inputWidth != outputWidth else { return source }
            if inputWidth < outputWidth {
                return source + "." + String("xyzw".prefix(inputWidth))
            }
            // The admission proof excludes every read of these absent channels.
            // Padding only carries the authored local type through Metal's ABI.
            let tail = inputWidth - outputWidth
            return metalType + "(" + source + ", " + (tail == 1 ? "0.0" : "float\(tail)(0.0)") + ")"
        }
    }

    var fragmentBindings: [FragmentBinding] {
        let unreferenced = Set(interface.unreferencedFragmentInputs ?? [])
        return interface.variables(stage: .fragment, kind: .varyingInput).filter { !unreferenced.contains($0.key.name) }.compactMap { input in
            varyings.first { output in
                if let location = input.location {
                    return output.variable.location == location
                }
                return output.variable.location == nil && output.name == input.key.name
            }.map { FragmentBinding(input: input, output: $0, usesProducedWidth: promotedFragmentInputs.contains(input.key.name)) }
        }
    }

    var fragmentDeclarations: [String] {
        fragmentBindings.map { binding in
            if binding.output.isArray {
                return "    [[maybe_unused]] \(binding.declaration) = { \((0 ..< binding.output.elementCount).map { binding.value($0) }.joined(separator: ", ")) };"
            }
            return "    [[maybe_unused]] \(binding.declaration) = \(binding.value(0));"
        }
    }

    private static func matchingOutput(for input: WPEShaderInterfaceVariable, in outputs: [WPEShaderInterfaceVariable]) -> WPEShaderInterfaceVariable? {
        outputs.first {
            if let location = input.location {
                return $0.location == location
            }
            return $0.location == nil && $0.key.name == input.key.name
        }
    }

    private static func floatWidth(_ type: String) -> Int? {
        ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4][type]
    }

    private static func canConsumeFloatPrefix(input: WPEShaderInterfaceVariable, output: WPEShaderInterfaceVariable, fragment: String) -> Bool {
        guard input.arrayDimensions.isEmpty, output.arrayDimensions.isEmpty,
              let inputWidth = floatWidth(input.glslType), let outputWidth = floatWidth(output.glslType) else { return false }
        if inputWidth < outputWidth {
            return true
        }
        guard inputWidth > outputWidth else { return false }
        let active = WPEShaderTranspiler.maskComments(WPEShaderTranspiler.stripInactivePreprocessorBranches(
            in: WPEShaderPreprocessor.normalizeNewlines(fragment)
        ))
        let name = NSRegularExpression.escapedPattern(for: input.key.name)
        guard let declaration = try? NSRegularExpression(pattern: "\\b(?:varying|in)\\s+" + input.glslType + "\\s+(" + name + ")\\s*;"),
              let declared = declaration.firstMatch(in: active, range: NSRange(active.startIndex..., in: active)),
              let identifier = try? NSRegularExpression(pattern: "\\b" + name + "\\b") else { return false }
        let ns = active as NSString
        for match in identifier.matches(in: active, range: NSRange(active.startIndex..., in: active)) {
            if match.range == declared.range(at: 1) {
                continue
            }
            let suffix = ns.substring(from: NSMaxRange(match.range))
            guard let swizzle = suffix.range(of: #"^\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) else { return false }
            let components = suffix[swizzle].filter { !$0.isWhitespace && $0 != "." }
            let axes = Array("xyzw"), colors = Array("rgba"), texture = Array("stpq")
            guard !components.isEmpty, components.allSatisfy({ c in
                (axes.firstIndex(of: c) ?? colors.firstIndex(of: c) ?? texture.firstIndex(of: c) ?? 4) < outputWidth
            }) else { return false }
        }
        return true
    }

    /// Normalize only global stage declarations; uniform metadata stays verbatim.
    func removingStageDeclarations(from source: String, stage: WPEShaderStage) -> String {
        let declarations = Set(interface.variables.filter {
            $0.key.stage == stage && [.attribute, .varyingInput, .varyingOutput].contains($0.kind)
        }.map(\.key.name))
        let pattern = #"^\s*(?:layout\s*\([^)]*\)\s*)?(?:(?:flat|smooth|noperspective|centroid|sample|highp|mediump|lowp)\s+)*(?:attribute|varying|in|out)\b[^;]*;"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var depth = 0
        return source.components(separatedBy: "\n").map { line in
            let originalMasked = WPEShaderTranspiler.maskComments(line)
            var result = line
            if depth == 0, let regex {
                while true {
                    let masked = WPEShaderTranspiler.maskComments(result)
                    guard let hit = regex.firstMatch(in: masked, range: NSRange(masked.startIndex..., in: masked)),
                          let range = Range(hit.range, in: masked),
                          declarations.contains(where: { name in
                              masked[range].range(of: "\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b",
                                                  options: .regularExpression) != nil
                          }) else { break }
                    let lower = result.index(result.startIndex, offsetBy: masked.distance(from: masked.startIndex, to: range.lowerBound))
                    let upper = result.index(lower, offsetBy: masked.distance(from: range.lowerBound, to: range.upperBound))
                    result.removeSubrange(lower ..< upper)
                }
            }
            for char in originalMasked {
                if char == "{" {
                    depth += 1
                }
                if char == "}" {
                    depth -= 1
                }
            }
            return result
        }.joined(separator: "\n")
    }
}

/// A closed statement/def-use proof, not a substitute for the GLSL compiler.
/// Only XY edits to one clip-input alias may reach the sole draw-MVP assignment.
private struct WPELocalEffectPositionProof {
    private struct Function {
        let parameters: Set<String>?
        let body: [[String]]
    }

    private let functions: [String: Function]
    private let uniforms: Set<String>
    private let outputs: Set<String>
    private let macros: [String: (parameters: Set<String>, expression: [String])]
    private static let pureBuiltins: Set<String> = [
        "float", "vec2", "vec3", "vec4", "mat2", "mat3", "mat4", "CAST2", "CAST3", "CAST4",
        "sin", "cos", "tan", "abs", "min", "max", "clamp", "mix", "dot", "length", "normalize", "sqrt", "pow", "frac", "fract",
    ]

    init?(source: String, fragment: String) {
        let activeFragment = WPEShaderTranspiler.maskComments(WPEShaderTranspiler.stripInactivePreprocessorBranches(in: fragment))
        guard let fragmentTokens = Self.tokens(activeFragment),
              !fragmentTokens.contains("gl_FragCoord"), !fragmentTokens.contains("gl_FragDepth") else { return nil }
        let interface = WPEShaderInterfaceParser.parse(vertex: source, fragment: fragment)
        uniforms = Set(interface.variables(stage: .vertex, kind: .uniform).map(\.key.name))
            .subtracting(["g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse"])
        outputs = Set(interface.variables(stage: .vertex, kind: .varyingOutput).map(\.key.name))
        var macroDefinitions: [String: (parameters: Set<String>, expression: [String])] = [:]
        var code: [String] = []
        for line in source.components(separatedBy: .newlines) {
            guard let tokens = Self.tokens(line) else { return nil }
            if tokens.first == "#" {
                guard tokens.count >= 2 else { return nil }
                if tokens[1] == "define", tokens.count >= 3 {
                    let name = tokens[2]
                    var parameters = Set<String>()
                    var start = 3
                    // Function-like macro parentheses must immediately follow its name.
                    if line.range(of: name + "(") != nil, tokens[start] == "(" {
                        guard let close = tokens[start...].firstIndex(of: ")") else { return nil }
                        for token in tokens[(start + 1) ..< close] where token != "," {
                            guard Self.identifier(token), parameters.insert(token).inserted else { return nil }
                        }
                        start = close + 1
                    }
                    guard start <= tokens.count else { return nil }
                    let expression = Array(tokens[start...])
                    if let previous = macroDefinitions[name] {
                        guard previous.parameters == parameters, previous.expression == expression else { return nil }
                    }
                    macroDefinitions[name] = (parameters, expression)
                }
                continue
            }
            code += tokens
        }
        var definitions: [String: Function] = [:]
        var start = 0
        while start < code.count {
            guard let end = code[start...].firstIndex(where: { $0 == ";" || $0 == "{" }) else { return nil }
            if code[end] == ";" {
                let declaration = Array(code[start ..< end])
                guard !declaration.contains("="), !declaration.contains("gl_Position") else { return nil }
                start = end + 1
                continue
            }
            let signature = Array(code[start ..< end])
            guard signature.count >= 4, signature[2] == "(", signature.last == ")",
                  Self.identifier(signature[1]) else { return nil }
            let parameters = Array(signature.dropFirst(3).dropLast())
            var names: Set<String>? = []
            if !parameters.isEmpty {
                for parameter in parameters.split(separator: ",") {
                    let words = parameter.filter { $0 != "const" && $0 != "in" }
                    guard words.count == 2, ["float", "vec2", "vec3", "vec4"].contains(words[0]),
                          Self.identifier(words[1]), names?.insert(words[1]).inserted == true else {
                        names = nil
                        break
                    }
                }
            }
            var close = end + 1
            var depth = 1
            while close < code.count {
                if code[close] == "{" {
                    depth += 1
                }
                if code[close] == "}" {
                    depth -= 1
                }
                if depth == 0 {
                    break
                }
                close += 1
            }
            guard close < code.count else { return nil }
            let body = Array(code[(end + 1) ..< close])
            guard body.isEmpty || body.last == ";" || body.last == "}" else { return nil }
            // Unused header overloads are opaque; a reachable ambiguous helper fails closed.
            definitions[signature[1]] = .init(parameters: definitions[signature[1]] == nil ? names : nil,
                                              body: body.split(separator: ";").map(Array.init))
            start = close + 1
        }
        functions = definitions
        macros = macroDefinitions
    }

    func isProven() -> Bool {
        let reserved: Set = ["a_Position", "a_TexCoord", "gl_Position", "g_ModelViewProjectionMatrix", "g_ModelViewProjectionMatrixInverse", "inverse", "vec3", "vec4"]
        guard Set(macros.keys).isDisjoint(with: reserved.union(uniforms).union(outputs)),
              Set(functions.keys).isDisjoint(with: reserved),
              let main = functions["main"], main.parameters?.isEmpty == true,
              main.body.flatMap(\.self).filter({ $0 == "g_ModelViewProjectionMatrix" }).count == 1,
              main.body.flatMap(\.self).filter({ $0 == "gl_Position" }).count == 1 else { return false }
        var position: String?
        var projected = false
        for statement in main.body {
            if statement.count == 4, statement[0] == "vec3", Self.identifier(statement[1]),
               statement[2] == "=", statement[3] == "a_Position" {
                guard position == nil, !uniforms.contains(statement[1]), !outputs.contains(statement[1]), macros[statement[1]] == nil else { return false }
                position = statement[1]
                continue
            }
            if statement.first == "gl_Position" {
                guard !projected, let position, Self.positionAssignment(statement, alias: position) else { return false }
                if statement.contains("mul") {
                    guard functions["mul"] == nil else { return false }
                    if let macro = macros["mul"] {
                        guard macro.parameters.count == 2,
                              macro.expression.filter({ $0 == "*" }).count == 1,
                              macro.parameters.allSatisfy({ parameter in macro.expression.filter { $0 == parameter }.count == 1 }),
                              macro.expression.allSatisfy({ macro.parameters.contains($0) || ["(", ")", "*"].contains($0) }) else { return false }
                    }
                }
                projected = true
                continue
            }
            if let position, statement.count > 4, statement[0] == position, statement[1] == ".", statement[2] == "xy",
               ["=", "+=", "-=", "*=", "/="].contains(statement[3]) {
                guard !projected, pureExpression(Array(statement.dropFirst(4)), locals: [], position: position, visiting: []) else { return false }
                continue
            }
            guard statement.count > 2, outputs.contains(statement[0]), statement[1] == "=",
                  pureExpression(Array(statement.dropFirst(2)), locals: ["a_TexCoord"], position: nil, visiting: []) else { return false }
        }
        return position != nil && projected
    }

    private func pureExpression(_ expression: [String], locals: Set<String>, position: String?, visiting: Set<String>) -> Bool {
        guard !expression.isEmpty else { return false }
        var index = 0
        var depth = 0
        while index < expression.count {
            let token = expression[index]
            if token == "(" {
                depth += 1
            }
            if token == ")" {
                depth -= 1
            }
            guard depth >= 0 else { return false }
            if token == position {
                guard index + 2 < expression.count, expression[index + 1] == ".", expression[index + 2] == "xy" else { return false }
                index += 3
                continue
            }
            if Self.identifier(token) {
                if index > 0, expression[index - 1] == "." {
                    guard token.allSatisfy({ "xyzwrgba".contains($0) }) else { return false }
                } else if let macro = macros[token] {
                    guard !visiting.contains(token), pureExpression(macro.expression, locals: macro.parameters, position: nil, visiting: visiting.union([token])) else { return false }
                } else if index + 1 < expression.count, expression[index + 1] == "(" {
                    guard functions[token] != nil ? pureFunction(token, visiting: visiting) : Self.pureBuiltins.contains(token) else { return false }
                } else {
                    guard locals.contains(token) || uniforms.contains(token) else { return false }
                }
            } else if Double(token) == nil {
                guard ["(", ")", ",", ".", "+", "-", "*", "/"].contains(token) else { return false }
            }
            index += 1
        }
        return depth == 0
    }

    private func pureFunction(_ name: String, visiting: Set<String>) -> Bool {
        guard !visiting.contains(name), let function = functions[name], let parameters = function.parameters else { return false }
        var locals = parameters
        var returned = false
        for statement in function.body {
            guard !returned else { return false }
            if statement.first == "return" {
                guard pureExpression(Array(statement.dropFirst()), locals: locals, position: nil, visiting: visiting.union([name])) else { return false }
                returned = true
            } else if statement.count > 3, ["float", "vec2", "vec3", "vec4"].contains(statement[0]),
                      Self.identifier(statement[1]), statement[2] == "=" {
                guard !locals.contains(statement[1]), !uniforms.contains(statement[1]),
                      pureExpression(Array(statement.dropFirst(3)), locals: locals, position: nil, visiting: visiting.union([name])) else { return false }
                locals.insert(statement[1])
            } else {
                guard statement.count > 2, locals.contains(statement[0]), statement[1] == "=",
                      pureExpression(Array(statement.dropFirst(2)), locals: locals, position: nil, visiting: visiting.union([name])) else { return false }
            }
        }
        return returned
    }

    private static func positionAssignment(_ statement: [String], alias: String) -> Bool {
        guard Array(statement.prefix(2)) == ["gl_Position", "="] else { return false }
        let expression = statement.dropFirst(2).map { Double($0) == 1 ? "1" : $0 }
        let position = ["vec4", "(", alias, ",", "1", ")"]
        let matrix = "g_ModelViewProjectionMatrix"
        return expression == [matrix, "*"] + position
            || expression == ["mul", "("] + position + [",", matrix, ")"]
            || expression == ["mul", "(", matrix, ","] + position + [")"]
    }

    private static func identifier(_ value: String) -> Bool {
        guard let first = value.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    private static func tokens(_ source: String) -> [String]? {
        let characters = Array(source)
        var result: [String] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1; continue
            }
            guard character.isASCII else { return nil }
            var end = index + 1
            if character.isLetter || character == "_" {
                while end < characters.count, characters[end].isLetter || characters[end].isNumber || characters[end] == "_" {
                    end += 1
                }
            } else if character.isNumber || (character == "." && end < characters.count && characters[end].isNumber) {
                while end < characters.count, characters[end].isNumber || characters[end] == "." {
                    end += 1
                }
                if end < characters.count, characters[end] == "e" || characters[end] == "E" {
                    end += 1
                    if end < characters.count, characters[end] == "+" || characters[end] == "-" {
                        end += 1
                    }
                    while end < characters.count, characters[end].isNumber {
                        end += 1
                    }
                }
            } else if end < characters.count, ["+=", "-=", "*=", "/=", "++", "--", "==", "!=", "<=", ">=", "&&", "||"].contains(String(characters[index ... end])) {
                end += 1
            }
            result.append(String(characters[index ..< end]))
            index = end
        }
        return result
    }
}
#endif
