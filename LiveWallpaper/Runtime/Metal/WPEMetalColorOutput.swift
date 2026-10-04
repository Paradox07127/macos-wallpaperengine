#if !LITE_BUILD
import Metal

/// Format specialization belongs to the attachment, not to a scene's HDR flag.
/// A float scene can still have UNORM local FBOs, and vice versa.
enum WPEMetalColorOutput {
    static func fragment(library: MTLLibrary, name: String, format: MTLPixelFormat, nativeAlpha: WPENativeAlphaPolicy = .compatibility) throws -> MTLFunction? {
        guard let function = library.makeFunction(name: name) else { return nil }
        let constants = function.functionConstantsDictionary
        guard constants["wpe_unorm_target"] != nil || constants["wpe_input_alpha_operation"] != nil
            || constants["wpe_native_straight_output"] != nil else { return function }
        let values = MTLFunctionConstantValues()
        var clampsSource = switch format {
        case .r8Unorm, .rg8Unorm, .rgba8Unorm, .bgra8Unorm, .rgb10a2Unorm,
             .rgba8Unorm_srgb, .bgra8Unorm_srgb:
            true
        default:
            false
        }
        if constants["wpe_unorm_target"] != nil {
            values.setConstantValue(&clampsSource, type: .bool, index: 1023)
        }
        if constants["wpe_input_alpha_operation"] != nil {
            var operation = UInt32(nativeAlpha.input.rawValue)
            values.setConstantValue(&operation, type: .uint, index: 1022)
        }
        if constants["wpe_native_straight_output"] != nil {
            var straight = nativeAlpha.straightOutput
            values.setConstantValue(&straight, type: .bool, index: 1021)
        }
        return try library.makeFunction(name: name, constantValues: values)
    }
}
#endif
