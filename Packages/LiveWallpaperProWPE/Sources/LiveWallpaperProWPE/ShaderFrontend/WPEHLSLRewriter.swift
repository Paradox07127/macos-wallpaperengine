public enum WPEShaderStage: Sendable, Hashable, CaseIterable {
    case vertex, geometry, fragment
}

/// Read access to the wallpaper VFS, addressed with names such as `shaders/common.h`.
public protocol WPEShaderSourceProviding: Sendable {
    /// Raw bytes of the file, or nil when no package or global asset root has it.
    func shaderSource(named name: String) -> [UInt8]?
}

/// One `#define NAME VALUE` line of the block the engine prepends to every stage.
public struct WPEShaderDefine: Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// VFS names of the stages of one material pass, e.g. `shaders/genericimage4.vert`.
public struct WPEHLSLProgramSources: Sendable, Hashable {
    public var vertex: String?
    public var geometry: String?
    public var fragment: String?

    public init(vertex: String? = nil, geometry: String? = nil, fragment: String? = nil) {
        self.vertex = vertex
        self.geometry = geometry
        self.fragment = fragment
    }
}

/// HLSL text per stage, byte for byte what the engine hands to D3DCompile.
public struct WPEHLSLProgram: Sendable, Hashable {
    public var vertex: [UInt8]?
    public var geometry: [UInt8]?
    public var fragment: [UInt8]?

    public init(vertex: [UInt8]? = nil, geometry: [UInt8]? = nil, fragment: [UInt8]? = nil) {
        self.vertex = vertex
        self.geometry = geometry
        self.fragment = fragment
    }
}

public enum WPEHLSLRewriteError: Error, Equatable, Sendable {
    case missingShader(String)
    /// A define the engine reads unconditionally (`LIGHTS_*` for `#require LightingV1`, `BONECOUNT` for g_Bones).
    case missingDefine(String)
    /// An array-size define whose value is not an integer.
    case nonIntegerDefine(name: String, value: String)
}

/// Wallpaper Engine 2.8.42 GLSL-dialect to HLSL rewrite (FUN_140162ac0 -> FUN_1400d5070).
public struct WPEHLSLRewriter: Sendable {
    public let sources: any WPEShaderSourceProviding

    public init(sources: any WPEShaderSourceProviding) {
        self.sources = sources
    }

    /// `defines`: combos then texture combos in the engine's write order, zero values included; they follow
    /// `#define HLSL 1`, `#define HLSL_SM40 1` and, if `geometryShadersEnabled`, `#define GS_ENABLED 1`.
    public func rewrite(
        _ program: WPEHLSLProgramSources,
        defines: [WPEShaderDefine],
        geometryShadersEnabled: Bool
    ) throws -> WPEHLSLProgram {
        var block = "#define HLSL 1\n#define HLSL_SM40 1\n"
        if geometryShadersEnabled {
            block += "#define GS_ENABLED 1\n"
        }
        var combos: WPEShaderMacros = [:]
        for define in defines {
            block += "#define \(define.name) \(define.value)\n"
            combos[Latin1.bytes(define.name)] = Latin1.bytes(define.value)
        }
        let prefix = Latin1.bytes(block)
        let loader = WPEShaderLoader(sources: sources)
        var link: [WPEHLSLDecl] = []
        var result = WPEHLSLProgram()
        let stages: [(WPEShaderStage, String?)] = [
            (.vertex, program.vertex), (.geometry, program.geometry), (.fragment, program.fragment),
        ]
        for (stage, name) in stages {
            guard let name else { continue }
            guard let source = sources.shaderSource(named: name) else {
                throw WPEHLSLRewriteError.missingShader(name)
            }
            var included = Set<[UInt8]>()
            var text = try WPEShaderPreprocessor.run(prefix + loader.load(source, included: &included))
            if stage != .geometry {
                // FUN_1400f3d00
                let from = Latin1.bytes("float mod(")
                if let k = text.firstIndex(ofBytes: from) {
                    text.replaceSubrange(k ..< k + from.count, with: Latin1.bytes("float _deprFn_0("))
                }
            }
            let hlsl = try WPEHLSLStageRewriter.rewrite(text, stage: stage, combos: combos, link: &link)
            switch stage {
            case .vertex: result.vertex = hlsl
            case .geometry: result.geometry = hlsl
            case .fragment: result.fragment = hlsl
            }
        }
        return result
    }

    /// FUN_1400d4730. `unusedSemantics`: semantic + index (e.g. `COLOR0`) of VS inputs reflection reports unread.
    /// Returns nil when nothing is removed, i.e. the engine does not compile the VS a second time.
    public static func pruningVertexInputs(_ hlsl: [UInt8], unusedSemantics: [String]) -> [UInt8]? {
        let patterns = unusedSemantics.filter { !$0.hasPrefix("BLENDINDICES") }.map(Latin1.bytes)
        guard !patterns.isEmpty,
              let start = Latin1.firstWholeWord(Latin1.bytes("VS_INPUT"), in: hlsl),
              let close = hlsl.firstIndex(ofBytes: Latin1.bytes("};"), from: start) else { return nil }
        let end = close + 2
        var kept: [UInt8] = []
        for line in hlsl[start ..< end].split(separator: Latin1.lf, omittingEmptySubsequences: false) {
            let line = Array(line)
            if !patterns.contains(where: { Latin1.firstWholeWord($0, in: line) != nil }) {
                kept += line
                kept.append(Latin1.lf)
            }
        }
        if kept.last == Latin1.lf {
            kept.removeLast()
        }
        return Array(hlsl[..<start]) + kept + Array(hlsl[end...])
    }
}
