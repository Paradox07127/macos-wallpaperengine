#if !LITE_BUILD
import CryptoKit
import Foundation

/// Pure-Swift frontend for the WPE shader dialect. Runs before the Swift
/// transpiler: parses `// [COMBO]` / `// [BIND]` annotations, applies
/// WPE→canonical-GLSL macro fixups, and bakes combo `#define`s into the
/// preamble so translation only has to deal with vanilla GLSL. `#include`
/// expansion and the `gl_FragColor` rewrite already happened at graph-build
/// time (`WPERenderPipelineBuilder.preprocess`), which is the only producer of
/// the sources this sees.
struct WPEShaderPreprocessor {

    func process(
        shaderName: String,
        vertexSource: String,
        fragmentSource: String,
        comboValues: [String: Int],
        materialTextureBindings: [Int: String]
    ) throws -> WPEShaderCompileRequest {
        let vertResult = try processStage(
            stage: .vertex,
            source: vertexSource,
            comboValues: comboValues
        )
        let fragResult = try processStage(
            stage: .fragment,
            source: fragmentSource,
            comboValues: comboValues
        )

        var combinedBindings = vertResult.bindings.merging(fragResult.bindings) { _, fragmentValue in fragmentValue }
        combinedBindings.merge(materialTextureBindings) { _, materialValue in materialValue }

        let merged = mergeComboDefaults(
            from: vertResult.combos.merging(fragResult.combos) { lhs, _ in lhs },
            overriddenBy: comboValues
        )

        let hash = Self.stableHash(
            shaderName: shaderName,
            vertexSource: vertexSource,
            fragmentSource: fragmentSource,
            comboValues: merged
        )

        return WPEShaderCompileRequest(
            shaderName: shaderName,
            processedVertexSource: vertResult.source,
            processedFragmentSource: fragResult.source,
            sourceHash: hash,
            comboValues: merged,
            textureBindings: combinedBindings
        )
    }

    // MARK: - Per-stage processing

    enum Stage {
        case vertex, fragment
    }

    struct StageResult {
        let source: String
        let combos: [String: WPEComboDeclaration]
        let bindings: [Int: String]
    }

    func processStage(
        stage: Stage,
        source: String,
        comboValues: [String: Int]
    ) throws -> StageResult {
        var combos: [String: WPEComboDeclaration] = [:]
        var bindings: [Int: String] = [:]
        // Normalize CRLF/CR → LF first. Swift treats "\r\n" as one grapheme, so the
        // line-based passes below (`split(separator: "\n")`) would see a CRLF file as a
        // SINGLE line, collapsing the whole shader onto its first line. WPE shaders (and
        // most Windows-authored workshop shaders) ship CRLF.
        let scanned = scanAnnotations(
            source: Self.normalizeNewlines(source),
            combos: &combos,
            bindings: &bindings
        )
        let canonical = applyMacroFixups(source: scanned)

        let merged = mergeComboDefaults(from: combos, overriddenBy: comboValues)
        let preamble = makePreamble(
            stage: stage,
            comboValues: merged
        )
        return StageResult(
            source: preamble + "\n" + canonical,
            combos: combos,
            bindings: bindings
        )
    }

    /// Collapse CRLF and lone-CR to LF so the line-based passes split
    /// consistently regardless of the shader's authoring platform.
    static func normalizeNewlines(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Annotations

    private func scanAnnotations(
        source: String,
        combos: inout [String: WPEComboDeclaration],
        bindings: inout [Int: String]
    ) -> String {
        var output: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let combo = WPEComboDeclaration.parse(line: trimmed) {
                combos[combo.combo] = combo
                output.append("// combo \(combo.combo)=default(\(combo.defaultValue))")
                continue
            }
            if let bind = WPEBindDeclaration.parse(line: trimmed) {
                bindings[bind.slot] = bind.name
                output.append("// bind \(bind.slot)=\(bind.name)")
                continue
            }
            output.append(String(line))
        }
        return output.joined(separator: "\n")
    }

    // MARK: - Macro fixups

    private func applyMacroFixups(source: String) -> String {
        var s = source

        s = s.replacingOccurrences(of: "texSample2DLod(", with: "textureLod(")
        s = s.replacingOccurrences(of: "texSample2D(", with: "texture(")
        s = s.replacingOccurrences(of: "texSampleNorm2D(", with: "texture(")

        return s
    }

    // MARK: - Combos

    private func mergeComboDefaults(
        from declarations: [String: WPEComboDeclaration],
        overriddenBy values: [String: Int]
    ) -> [String: Int] {
        var merged: [String: Int] = [:]
        for (name, declaration) in declarations {
            merged[name] = declaration.defaultValue
        }
        for (name, value) in values {
            merged[name] = value
        }
        return merged
    }

    private func makePreamble(stage: Stage, comboValues: [String: Int]) -> String {
        var lines: [String] = ["#version 410 core"]
        for name in comboValues.keys.sorted() {
            lines.append("#define \(name) \(comboValues[name]!)")
        }
        switch stage {
        case .vertex:
            lines.append("// stage: vertex")
        case .fragment:
            lines.append("// stage: fragment")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Hashing

    static func stableHash(
        shaderName: String,
        vertexSource: String,
        fragmentSource: String,
        comboValues: [String: Int]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(shaderName.utf8))
        hasher.update(data: Data(vertexSource.utf8))
        hasher.update(data: Data(fragmentSource.utf8))
        for key in comboValues.keys.sorted() {
            hasher.update(data: Data(key.utf8))
            hasher.update(data: Data(String(comboValues[key]!).utf8))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Annotation parsers

struct WPEComboDeclaration: Equatable {
    let combo: String
    let material: String?
    let comboType: String?
    let defaultValue: Int

    static func parse(line: String) -> Self? {
        guard let body = stripPrefix(line, prefix: "// [COMBO]")
            ?? stripPrefix(line, prefix: "//[COMBO]") else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(
            with: Data(body.utf8),
            options: [.allowFragments]
        ) as? [String: Any] else {
            return nil
        }
        guard let combo = json["combo"] as? String, !combo.isEmpty else { return nil }
        let defaultValue: Int = {
            if let i = json["default"] as? Int { return i }
            if let d = json["default"] as? Double { return Int(d) }
            if let s = json["default"] as? String, let i = Int(s) { return i }
            return 0
        }()
        return Self(
            combo: combo,
            material: json["material"] as? String,
            comboType: json["type"] as? String,
            defaultValue: defaultValue
        )
    }
}

struct WPEBindDeclaration: Equatable {
    let slot: Int
    let name: String

    static func parse(line: String) -> Self? {
        guard let body = stripPrefix(line, prefix: "// [BIND]")
            ?? stripPrefix(line, prefix: "//[BIND]") else {
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(
            with: Data(body.utf8),
            options: [.allowFragments]
        ) as? [String: Any] else {
            return nil
        }
        guard let name = json["name"] as? String, !name.isEmpty else { return nil }
        let slot: Int = {
            if let i = json["index"] as? Int { return i }
            if let i = json["slot"] as? Int { return i }
            return 0
        }()
        return Self(slot: slot, name: name)
    }
}

private func stripPrefix(_ string: String, prefix: String) -> String? {
    guard string.hasPrefix(prefix) else { return nil }
    return String(string.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
}
#endif
