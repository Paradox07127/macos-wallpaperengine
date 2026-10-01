#if !LITE_BUILD
import Foundation

/// Reads already include-expanded WPE source. Unknown declarations stay diagnosable;
/// the scanner does not decide whether a declaration survives GPU optimization.
enum WPEShaderInterfaceParser {
    static func parse(vertex: String, fragment: String) -> WPEShaderInterface {
        let vs = scan(vertex, stage: .vertex)
        let fs = scan(fragment, stage: .fragment)
        let variables = vs.variables + fs.variables
        var issues = vs.issues + fs.issues
        let outputs = vs.variables.filter { $0.kind == .varyingOutput }
        for input in fs.variables where input.kind == .varyingInput {
            // Explicit locations take precedence; name linking is only for unlocated interfaces.
            let output = outputs.first {
                if let location = input.location {
                    return $0.location == location
                }
                return $0.location == nil && $0.key.name == input.key.name
            }
            guard let output else {
                issues.append(.init(code: .missingVertexOutput, stage: .fragment, name: input.key.name))
                continue
            }
            if input.glslType != output.glslType || input.arrayDimensions != output.arrayDimensions {
                issues.append(.init(code: .varyingTypeMismatch, stage: .fragment, name: input.key.name))
            }
            if input.interpolation != output.interpolation || input.centroid != output.centroid || input.sample != output.sample {
                issues.append(.init(code: .varyingInterpolationMismatch, stage: .fragment, name: input.key.name))
            }
        }
        var interface = WPEShaderInterface(hasVertexSource: vs.hasVertexSource, hasFragmentSource: fs.hasFragmentSource,
                                           variables: variables, issues: issues)
        let activeFragment = WPEShaderTranspiler.maskComments(WPEShaderTranspiler.stripInactivePreprocessorBranches(
            in: WPEShaderPreprocessor.normalizeNewlines(fragment)
        ))
        interface.unreferencedFragmentInputs = fs.variables.filter { variable in
            guard variable.kind == .varyingInput,
                  let identifier = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: variable.key.name) + "\\b") else { return false }
            // Include macro bodies and helpers: any additional occurrence keeps the
            // input required, even when a compiler might optimize that read away.
            return identifier.numberOfMatches(in: activeFragment, range: NSRange(activeFragment.startIndex..., in: activeFragment)) == 1
        }.map(\.key.name)
        return interface
    }

    private static let qualifiers: Set<String> = [
        "uniform", "attribute", "varying", "in", "out", "flat", "smooth", "noperspective",
        "centroid", "sample", "highp", "mediump", "lowp", "invariant", "precise",
    ]
    private static let storage: Set<String> = ["uniform", "attribute", "varying", "in", "out"]

    private static func scan(_ source: String, stage: WPEShaderStage) -> WPEShaderInterface {
        let normalized = WPEShaderPreprocessor.normalizeNewlines(source)
        let active = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: normalized)
        let masked = WPEShaderTranspiler.maskComments(active)
        // Directives cannot be declarations. Macro extents remain symbolic until a compiler resolves them.
        let code = masked.components(separatedBy: "\n").map {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") ? "" : $0
        }.joined(separator: "\n")
        var variables: [WPEShaderInterfaceVariable] = []
        var issues: [WPEShaderInterfaceIssue] = []
        var statement = ""
        var depth = 0
        for character in code {
            if character == "{" {
                if depth == 0, isInterfaceStatement(statement) {
                    issues.append(.init(code: .unsupportedDeclaration, stage: stage, name: nil))
                }
                depth += 1
                statement = ""
            } else if character == "}" {
                depth = max(0, depth - 1)
                statement = ""
            } else if depth == 0 {
                if character == ";" {
                    parseDeclaration(statement, stage: stage, variables: &variables, issues: &issues)
                    statement = ""
                } else {
                    statement.append(character)
                }
            }
        }
        if isInterfaceStatement(statement) {
            issues.append(.init(code: .unsupportedDeclaration, stage: stage, name: nil))
        }
        let present = !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return WPEShaderInterface(hasVertexSource: stage == .vertex && present,
                                  hasFragmentSource: stage == .fragment && present, variables: variables, issues: issues)
    }

    private static func isInterfaceStatement(_ statement: String) -> Bool {
        let cleaned = removingLayout(statement).source
        return cleaned.split(whereSeparator: { $0.isWhitespace }).prefix(while: { qualifiers.contains(String($0)) })
            .contains { storage.contains(String($0)) }
    }

    private static func removingLayout(_ statement: String) -> (source: String, location: Int?, unsupported: Bool) {
        let pattern = #"\blayout\s*\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (statement, nil, true) }
        let ns = statement as NSString
        var location: Int?
        var unsupported = false
        for match in regex.matches(in: statement, range: NSRange(location: 0, length: ns.length)) {
            let args = ns.substring(with: match.range(at: 1))
            for argument in args.split(separator: ",") {
                let pair = argument.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if pair.count == 2, pair[0] == "location", let value = Int(pair[1]), value >= 0, location == nil {
                    location = value
                } else {
                    unsupported = true
                }
            }
        }
        return (regex.stringByReplacingMatches(in: statement, range: NSRange(location: 0, length: ns.length), withTemplate: " "), location, unsupported)
    }

    private static func parseDeclaration(
        _ statement: String, stage: WPEShaderStage,
        variables: inout [WPEShaderInterfaceVariable], issues: inout [WPEShaderInterfaceIssue]
    ) {
        guard isInterfaceStatement(statement) else { return }
        let layout = removingLayout(statement)
        var tokens = layout.source.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var prefix: [String] = []
        while let token = tokens.first, qualifiers.contains(token) {
            prefix.append(tokens.removeFirst())
        }
        guard let modifier = prefix.first(where: { storage.contains($0) }), tokens.count >= 2,
              prefix.filter({ storage.contains($0) }).count == 1 else {
            issues.append(.init(code: .unsupportedDeclaration, stage: stage, name: nil))
            return
        }
        let type = tokens.removeFirst()
        if layout.unsupported || (!type.contains("sampler") && WPEUniformType(glslType: type) == nil) {
            issues.append(.init(code: .unsupportedDeclaration, stage: stage, name: nil))
        }
        let kind: WPEShaderInterfaceVariable.Kind
        switch (modifier, stage) {
        case ("uniform", _): kind = type.contains("sampler") ? .texture : .uniform
        case ("attribute", .vertex), ("in", .vertex): kind = .attribute
        case ("varying", .vertex), ("out", .vertex): kind = .varyingOutput
        case ("varying", .fragment), ("in", .fragment): kind = .varyingInput
        case ("out", .fragment): kind = .fragmentOutput
        default:
            issues.append(.init(code: .unsupportedDeclaration, stage: stage, name: nil))
            return
        }
        let pattern = #"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*((?:\[[^\]]*\]\s*)*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let dimensions = try? NSRegularExpression(pattern: #"\[([^\]]*)\]"#) else { return }
        for declaration in tokens.joined(separator: " ").split(separator: ",", omittingEmptySubsequences: false) {
            let raw = String(declaration)
            let ns = raw as NSString
            guard let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else {
                issues.append(.init(code: .unsupportedDeclaration, stage: stage, name: nil))
                continue
            }
            let name = ns.substring(with: match.range(at: 1))
            let extents = dimensions.matches(in: raw, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let key = WPEShaderBindingKey(stage: stage, name: name)
            if variables.contains(where: { $0.key == key }) {
                issues.append(.init(code: .duplicateDeclaration, stage: stage, name: name))
                continue
            }
            if extents.contains(where: { (Int($0) ?? 0) <= 0 }) {
                issues.append(.init(code: .unresolvedArrayExtent, stage: stage, name: name))
            }
            let interpolation = prefix.contains("flat") ? WPEShaderInterfaceVariable.Interpolation.flat
                : prefix.contains("noperspective") ? .noperspective : .smooth
            variables.append(.init(key: key, kind: kind, glslType: type, arrayDimensions: extents,
                                   interpolation: interpolation, centroid: prefix.contains("centroid"),
                                   sample: prefix.contains("sample"), location: layout.location))
        }
    }
}
#endif
