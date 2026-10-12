import CryptoKit
import Foundation

/// The HLSL WPE compiles for one draw, with the define block split the way the `.dxs` key consumes it.
public struct WPEParityProgram: Sendable, Equatable {
    public let shader: String
    /// The combo map in output order (segments J, B, D, E).
    public let combos: [WPEShaderDefine]
    /// Bound-texture combos written after the map (FUN_14016c800).
    public let textureCombos: [WPEShaderDefine]
    public let hlsl: WPEHLSLProgram

    /// `.dxs` file name stem: lowercase hex SHA-1 over the feature-level key `k` (3 for 11_x, 1 for 10_1), the shader
    /// name, the non-zero combos sorted by name (name bytes + LE32 value), then `#define <combo> 1\n` per texture combo.
    public func dxsKey(featureLevelKey: UInt32 = 3) -> String {
        var hash = Insecure.SHA1()
        func update(_ value: Int32) {
            withUnsafeBytes(of: UInt32(bitPattern: value).littleEndian) { hash.update(bufferPointer: $0) }
        }
        update(Int32(bitPattern: featureLevelKey))
        hash.update(data: Data(shader.utf8))
        let sorted = combos.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
        for define in sorted {
            guard let value = Int32(define.value), value != 0 else { continue }
            hash.update(data: Data(define.name.utf8))
            update(value)
        }
        for define in textureCombos {
            hash.update(data: Data("#define \(define.name) 1\n".utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func cacheKey(compilerIdentity: String, options: WPEParityShaderCompileOptions,
                         bindingABIVersion: Int) -> WPEParityShaderKey {
        WPEParityShaderKey(program: hlsl, compilerIdentity: compilerIdentity, options: options,
                           bindingABIVersion: bindingABIVersion)
    }
}

public enum WPEParityProgramResolver {
    /// Annotations come from `.vert` then `.frag` with includes expanded; a `.geom` joins the program when it exists.
    public static func resolve(_ description: WPEParityProgramDescription,
                               sources: any WPEShaderSourceProviding) throws -> WPEParityProgram {
        let shader = description.material.shader
        let (names, vertex, fragment) = expandedSources(shader: shader, sources: sources)
        func defines(_ textures: [Int32: WPEBoundComboTexture]) -> [WPEShaderDefine] {
            WPEComboResolver.resolve(passJSONCombos: description.passJSONCombos,
                                     blendingMode: Int32(description.material.blending.rawValue),
                                     vertexSource: vertex, fragmentSource: fragment,
                                     engineFlags: description.engineFlags, boundTextures: textures)
        }
        let combos = defines([:])
        let all = defines(description.boundTextures)
        // GS_ENABLED: Main+0x118 bit3 is set when Main is created and never cleared.
        let hlsl = try WPEHLSLRewriter(sources: sources).rewrite(names, defines: all, geometryShadersEnabled: true)
        return WPEParityProgram(shader: shader, combos: combos, textureCombos: Array(all.dropFirst(combos.count)),
                                hlsl: hlsl)
    }

    static func expandedSources(shader: String, sources: any WPEShaderSourceProviding)
        -> (names: WPEHLSLProgramSources, vertex: String, fragment: String) {
        let names = WPEHLSLProgramSources(
            vertex: "shaders/\(shader).vert",
            geometry: sources.shaderSource(named: "shaders/\(shader).geom") == nil ? nil : "shaders/\(shader).geom",
            fragment: "shaders/\(shader).frag"
        )
        let loader = WPEShaderLoader(sources: sources)
        func expanded(_ name: String?) -> String {
            var included = Set<[UInt8]>()
            return Latin1.string(loader.load(name.flatMap(sources.shaderSource(named:)), included: &included))
        }
        return (names, expanded(names.vertex), expanded(names.fragment))
    }
}
