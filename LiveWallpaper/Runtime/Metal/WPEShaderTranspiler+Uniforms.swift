#if !LITE_BUILD
import Foundation

extension WPEShaderTranspiler {
    /// Called after validatedUniformLayout has checked every type and total span.
    static func uniformDeclarationLines(_ uniforms: [WPEUniformDecl]) -> [String] {
        var lines: [String] = []
        var nextSlot = 0
        for uniform in uniforms {
            guard let type = WPEUniformType(glslType: uniform.type) else {
                preconditionFailure("unvalidated uniform type")
            }
            if let count = uniform.arrayLength {
                lines.append("    [[maybe_unused]] \(type.metalType) \(uniform.name)[\(count)];")
                for element in 0..<count {
                    let read = type.metalRead(firstSlot: nextSlot + element * type.elementSlotCount)
                    lines.append("    \(uniform.name)[\(element)] = \(read);")
                }
                nextSlot += count * type.elementSlotCount
            } else {
                lines.append("    [[maybe_unused]] \(type.metalType) \(uniform.name) = \(type.metalRead(firstSlot: nextSlot));")
                nextSlot += type.elementSlotCount
            }
        }
        return lines
    }
}
#endif
