#if !LITE_BUILD
import Foundation

/// Declaration-based ABI shared by both real stages. This is not Metal reflection.
/// Unsupported shapes fail the link; they never disappear into a reconstructed UV.
struct WPEShaderStageLink {
    /// Conservative admission proof for the native fullscreen clip matrix. It is
    /// not a proof of WPE's Z projection: depth testing/writes remain separate.
    static func usesMVPOnlyForFullscreenPosition(_ source: String) -> Bool {
        var active = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: source)
        active = active.replacingOccurrences(of: #"(?s)/\*.*?\*/|//[^\n]*"#, with: "", options: .regularExpression)
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
        return !active.contains("g_ModelViewProjectionMatrix") && !active.contains("gl_Position")
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

    init(vertex: String, fragment: String) throws {
        interface = WPEShaderInterfaceParser.parse(vertex: vertex, fragment: fragment)
        let unreferenced = Set(interface.unreferencedFragmentInputs ?? [])
        let requiredIssues = interface.issues.filter { issue in
            !(issue.code == .missingVertexOutput && issue.stage == .fragment
                && issue.name.map(unreferenced.contains) == true)
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

    var fragmentDeclarations: [String] {
        let inputNames = Set(interface.variables(stage: .fragment, kind: .varyingInput).map(\.key.name))
        return varyings.filter { inputNames.contains($0.name) }.flatMap { v -> [String] in
            if v.isArray {
                return ["    [[maybe_unused]] \(v.declaration) = { \((0 ..< v.elementCount).map { "in.\(v.field($0))" }.joined(separator: ", ")) };"]
            }
            return ["    [[maybe_unused]] \(v.declaration) = in.\(v.field(0));"]
        }
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
