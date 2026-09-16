#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

struct WPEUniformPackingError: Error, Equatable, LocalizedError {
    let uniformName: String
    let reason: String
    var errorDescription: String? { "Uniform '\(uniformName)': \(reason)" }
}

enum WPEUniformPacking {
    static func pack(
        _ value: WPESceneShaderConstantValue?,
        uniform: WPEUniformSlot,
        into slots: UnsafeMutableBufferPointer<SIMD4<Float>>
    ) throws {
        guard let type = uniform.typeLayout else {
            throw WPEUniformPackingError(uniformName: uniform.name, reason: "unsupported type \(uniform.glslType)")
        }
        let count = uniform.arrayLength ?? 1
        guard count > 0, count <= WPEShaderTranspiler.uniformSlotMaximum / type.elementSlotCount,
              uniform.slotCount == count * type.elementSlotCount,
              uniform.slot >= 0, uniform.slot <= slots.count,
              uniform.slotCount <= slots.count - uniform.slot else {
            throw WPEUniformPackingError(uniformName: uniform.name, reason: "invalid slot span")
        }
        let scalar = uniform.arrayLength == nil && type.componentCount == 1
        let values = components(value, scalar: scalar, boolean: type.scalar == .bool)
        for element in 0..<count {
            for column in 0..<type.columns {
                var packed = SIMD4<Float>(repeating: 0)
                for row in 0..<type.rows {
                    let index = element * type.componentCount + column * type.rows + row
                    let number = index < values.count ? values[index] : 0
                    switch type.scalar {
                    case .float: packed[row] = Float(number)
                    case .bool: packed[row] = number != 0 ? 1 : 0
                    case .int:
                        let integer = number.rounded(.towardZero)
                        guard integer.isFinite, integer >= Double(Int32.min), integer <= Double(Int32.max) else {
                            throw WPEUniformPackingError(uniformName: uniform.name, reason: "component \(index) is outside the finite Int32 range")
                        }
                        packed[row] = Float(bitPattern: UInt32(bitPattern: Int32(integer)))
                    case .uint:
                        let integer = number.rounded(.towardZero)
                        guard integer.isFinite, integer >= 0, integer <= Double(UInt32.max) else {
                            throw WPEUniformPackingError(uniformName: uniform.name, reason: "component \(index) is outside the finite UInt32 range")
                        }
                        packed[row] = Float(bitPattern: UInt32(integer))
                    }
                }
                slots[uniform.slot + element * type.elementSlotCount + column] = packed
            }
        }
    }

    /// Retains the existing scalar-string and vector zero-padding conventions.
    /// Conversion to Float happens only after typed integer transport is selected.
    private static func components(
        _ value: WPESceneShaderConstantValue?, scalar: Bool, boolean: Bool
    ) -> [Double] {
        switch value {
        case .vector(let values): return values
        case .number(let number): return [number]
        case .bool(let value): return scalar || boolean ? [value ? 1 : 0] : []
        case .string(let value): return scalar ? [Double(value) ?? 0] : []
        case .animated(let value):
            return scalar ? [value.scalar(at: 0) ?? 0] : (value.vector(at: 0) ?? [])
        case nil: return []
        }
    }
}
#endif
