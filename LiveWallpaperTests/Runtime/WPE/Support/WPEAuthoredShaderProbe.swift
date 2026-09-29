#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal

/// Restricted experiment behind the semantic contract, never selected by the product dispatcher.
/// Separate stage buffers deliberately exercise same-name/different-type authored bindings.
enum WPEAuthoredShaderProbe {
    struct Result {
        let library: MTLLibrary
        let interface: WPEShaderInterface
        let vertexUniforms: [WPEUniformSlot]
        let fragmentUniforms: [WPEUniformSlot]
    }

    enum Failure: Error { case unsupportedInterface, unsupportedSource }

    static func compile(vertex: String, fragment: String, device: MTLDevice) throws -> Result {
        let interface = WPEShaderInterfaceParser.parse(vertex: vertex, fragment: fragment)
        guard interface.issues.isEmpty,
              interface.variables.allSatisfy({
                  $0.arrayDimensions.isEmpty && $0.interpolation == .smooth && !$0.centroid && !$0.sample
                      && $0.location == nil && $0.kind != .texture && $0.kind != .fragmentOutput
                      && WPEUniformType(glslType: $0.glslType) != nil
              }) else { throw Failure.unsupportedInterface }
        let attributes = interface.variables(stage: .vertex, kind: .attribute)
        guard !attributes.isEmpty, attributes.allSatisfy({
            ($0.key.name == "a_Position" && $0.glslType == "vec3") || ($0.key.name == "a_TexCoord" && $0.glslType == "vec2")
        }) else { throw Failure.unsupportedInterface }
        let vertexUniforms = try uniformLayout(interface, stage: .vertex)
        let fragmentUniforms = try uniformLayout(interface, stage: .fragment)
        let varyingOutputs = interface.variables(stage: .vertex, kind: .varyingOutput)
        let varyingInputs = interface.variables(stage: .fragment, kind: .varyingInput)
        guard varyingOutputs.allSatisfy({ $0.glslType.hasPrefix("vec") || $0.glslType == "float" }) else {
            throw Failure.unsupportedInterface
        }
        var vsBody = try body(vertex)
        var fsBody = try body(fragment)
        for varying in varyingOutputs {
            vsBody = replaceIdentifier(vsBody, find: varying.key.name, replace: "out.\(varying.key.name)")
        }
        for varying in varyingInputs {
            fsBody = replaceIdentifier(fsBody, find: varying.key.name, replace: "in.\(varying.key.name)")
        }
        vsBody = replaceIdentifier(vsBody, find: "gl_Position", replace: "out.position")
        fsBody = replaceIdentifier(fsBody, find: "gl_FragColor", replace: "color")
        // Only type spellings are shared; no fragment UV/varying/PMA rewrites run on vertex expressions.
        for (glsl, metal) in [("vec2", "float2"), ("vec3", "float3"), ("vec4", "float4"),
                              ("mat2", "float2x2"), ("mat3", "float3x3"), ("mat4", "float4x4")] {
            vsBody = replaceIdentifier(vsBody, find: glsl, replace: metal)
            fsBody = replaceIdentifier(fsBody, find: glsl, replace: metal)
        }
        let varyings = varyingOutputs.map {
            "    \(WPEUniformType(glslType: $0.glslType)!.metalType) \($0.key.name);"
        }.joined(separator: "\n")
        let attributeLocals = attributes.map {
            $0.key.name == "a_Position" ? "float3 a_Position = float3(positions[vid], 0.0);" : "float2 a_TexCoord = uvs[vid];"
        }.joined(separator: "\n")
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        // WPE's vector-first spelling represents a column-vector matrix product.
        inline float4 mul(float4 v, float4x4 m) { return m * v; }
        inline float3 mul(float3 v, float3x3 m) { return m * v; }
        inline float3x3 CAST3X3(float4x4 m) { return float3x3(m[0].xyz, m[1].xyz, m[2].xyz); }
        struct ProbeVSUniforms { float4 vals[\(max(1, vertexUniforms.reduce(0) { $0 + $1.slotCount }))]; };
        struct ProbeFSUniforms { float4 vals[\(max(1, fragmentUniforms.reduce(0) { $0 + $1.slotCount }))]; };
        struct ProbeVaryings {
            float4 position [[position]];
        \(varyings)
        };
        vertex ProbeVaryings wpe_probe_vertex(uint vid [[vertex_id]], constant ProbeVSUniforms& u [[buffer(0)]]) {
            const float2 positions[4] = {float2(-1, 1), float2(-1, -1), float2(1, 1), float2(1, -1)};
            const float2 uvs[4] = {float2(0, 0), float2(0, 1), float2(1, 0), float2(1, 1)};
            ProbeVaryings out;
        \(attributeLocals)
        \(reads(vertexUniforms))
        \(vsBody)
            return out;
        }
        fragment float4 wpe_probe_fragment(ProbeVaryings in [[stage_in]], constant ProbeFSUniforms& u [[buffer(0)]]) {
            float4 color;
        \(reads(fragmentUniforms))
        \(fsBody)
            return color;
        }
        """
        let library = try WPEMetalLibraryRegistry.shared.library(device: device, source: source,
                                                                 configuration: .init(fastMathEnabled: false))
        return Result(library: library, interface: interface, vertexUniforms: vertexUniforms, fragmentUniforms: fragmentUniforms)
    }

    private static func uniformLayout(_ interface: WPEShaderInterface, stage: WPEShaderStage) throws -> [WPEUniformSlot] {
        var next = 0
        return try interface.variables(stage: stage, kind: .uniform).map { variable in
            guard let type = WPEUniformType(glslType: variable.glslType) else { throw Failure.unsupportedInterface }
            defer { next += type.elementSlotCount }
            return WPEUniformSlot(name: variable.key.name, glslType: variable.glslType, slot: next,
                                  slotCount: type.elementSlotCount, arrayLength: nil, materialName: nil,
                                  defaultValue: nil, requiredCombos: [:])
        }
    }

    private static func replaceIdentifier(_ source: String, find: String, replace: String) -> String {
        source.replacingOccurrences(of: "\\b" + NSRegularExpression.escapedPattern(for: find) + "\\b",
                                    with: replace, options: .regularExpression)
    }

    private static func reads(_ layout: [WPEUniformSlot]) -> String {
        layout.map { "\($0.typeLayout!.metalType) \($0.name) = \($0.typeLayout!.metalRead(firstSlot: $0.slot));" }
            .joined(separator: "\n")
    }

    private static func body(_ source: String) throws -> String {
        let active = WPEShaderTranspiler.stripInactivePreprocessorBranches(in: WPEShaderPreprocessor.normalizeNewlines(source))
        let masked = WPEShaderTranspiler.maskComments(active)
        guard let main = WPEShaderTranspiler.locateMain(in: masked) else { throw Failure.unsupportedSource }
        let outside = String(masked[..<main.lowerBound]) + String(masked[main.upperBound...])
        // Only numeric combo defines are allowed; no function macros or executable globals.
        let declarations = outside.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#version")
                && trimmed.range(of: #"^#\s*define\s+[A-Za-z_][A-Za-z0-9_]*\s+[0-9]+\s*$"#, options: .regularExpression) == nil
        }.joined(separator: "\n")
        let pattern = #"\b(?:uniform|attribute|varying|in|out)\s+[A-Za-z_][A-Za-z0-9_]*\s+[A-Za-z_][A-Za-z0-9_]*\s*;"#
        let stripped = declarations.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        guard stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.unsupportedSource }
        let function = String(masked[main])
        guard let open = function.firstIndex(of: "{"), let close = function.lastIndex(of: "}") else {
            throw Failure.unsupportedSource
        }
        let body = String(function[function.index(after: open) ..< close])
        guard !body.contains("discard"), !body.contains("gl_VertexID"), !body.contains("gl_FragCoord") else {
            throw Failure.unsupportedSource
        }
        return body
    }
}
#endif
