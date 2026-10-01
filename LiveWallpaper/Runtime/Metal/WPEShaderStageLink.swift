#if !LITE_BUILD
import Foundation

/// Declaration-based ABI shared by both real stages. This is not Metal reflection.
/// Unsupported shapes fail the link; they never disappear into a reconstructed UV.
struct WPEShaderStageLink {
    /// Conservative admission proof for the native fullscreen clip matrix. It is
    /// not a proof of WPE's Z projection: depth testing/writes remain separate.
    static func usesMVPOnlyForFullscreenPosition(_ source: String) -> Bool {
        var active = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: source)
        active = WPEShaderTranspiler.maskComments(active)
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
#endif
