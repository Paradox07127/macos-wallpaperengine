#if !LITE_BUILD
import Foundation

/// Authored stage identity is independent of the current flat fragment-buffer ABI.
struct WPEShaderBindingKey: Codable, Hashable, Sendable {
    let stage: WPEShaderStage
    let name: String
}

struct WPEShaderInterfaceVariable: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case attribute, varyingInput, varyingOutput, uniform, texture, fragmentOutput
    }

    enum Interpolation: String, Codable, Sendable {
        case smooth, flat, noperspective
    }

    let key: WPEShaderBindingKey
    let kind: Kind
    let glslType: String
    /// Retain symbolic, malformed and multidimensional extents; never silently turn them into scalars.
    let arrayDimensions: [String]
    let interpolation: Interpolation
    let centroid: Bool
    let sample: Bool
    let location: Int?
}

struct WPEShaderInterfaceIssue: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case unsupportedDeclaration, duplicateDeclaration, missingVertexOutput
        case varyingTypeMismatch, varyingInterpolationMismatch, unresolvedArrayExtent
    }

    let code: Code
    let stage: WPEShaderStage
    let name: String?
}

/// Declaration inventory, not compiler reflection or proof of shader resource consumption.
struct WPEShaderInterface: Codable, Equatable, Sendable {
    static let version = 1
    let hasVertexSource: Bool
    let hasFragmentSource: Bool
    let variables: [WPEShaderInterfaceVariable]
    let issues: [WPEShaderInterfaceIssue]

    func variables(stage: WPEShaderStage, kind: WPEShaderInterfaceVariable.Kind) -> [WPEShaderInterfaceVariable] {
        variables.filter { $0.key.stage == stage && $0.kind == kind }
    }

    func variable(_ key: WPEShaderBindingKey) -> WPEShaderInterfaceVariable? {
        variables.first { $0.key == key }
    }
}
#endif
