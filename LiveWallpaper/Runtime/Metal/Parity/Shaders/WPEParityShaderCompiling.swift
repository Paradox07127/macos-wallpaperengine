#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

enum WPEParityShaderPolicy: Equatable, Sendable {
    case compileAllowed
    case precompiledOnly
}

protocol WPEParityShaderCompiling: Sendable {
    func compile(_ request: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages
}

struct WPEParityShaderCompileRequest: Sendable {
    static let currentBindingABIVersion = 1
    let key: WPEParityShaderKey
    let program: WPEHLSLProgram
    let options: WPEParityShaderCompileOptions

    init(program: WPEHLSLProgram, compilerIdentity: String,
         options: WPEParityShaderCompileOptions = .init(), bindingABIVersion: Int) {
        self.program = program
        self.options = options
        key = WPEParityShaderKey(program: program, compilerIdentity: compilerIdentity,
                                 options: options, bindingABIVersion: bindingABIVersion)
    }

    var stages: Set<WPEParityShaderKey.Stage> {
        var result = Set<WPEParityShaderKey.Stage>()
        if program.vertex != nil {
            result.insert(.vertex)
        }
        if program.fragment != nil {
            result.insert(.fragment)
        }
        if program.geometry != nil {
            result.insert(.geometry)
        }
        return result
    }
}

struct WPEParityCompiledStages: Sendable {
    struct Stage: Sendable {
        let metallib: Data
        let reflectionJSON: Data
        /// Vertex stage of a geometry program only: MSC's synthesized stage-in function.
        var stageIn: Data?
    }

    let stages: [WPEParityShaderKey.Stage: Stage]
}
#endif
