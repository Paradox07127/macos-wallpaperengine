#if !LITE_BUILD
import Metal

/// Format specialization belongs to the attachment, not to a scene's HDR flag.
/// A float scene can still have UNORM local FBOs, and vice versa.
enum WPEMetalColorOutput {
    static func fragment(library: MTLLibrary, name: String, format: MTLPixelFormat) throws -> MTLFunction? {
        guard let function = library.makeFunction(name: name) else { return nil }
        guard function.functionConstantsDictionary["wpe_unorm_target"] != nil else { return function }
        let values = MTLFunctionConstantValues()
        var clampsSource = switch format {
        case .r8Unorm, .rg8Unorm, .rgba8Unorm, .bgra8Unorm, .rgb10a2Unorm,
             .rgba8Unorm_srgb, .bgra8Unorm_srgb:
            true
        default:
            false
        }
        values.setConstantValue(&clampsSource, type: .bool, index: 1023)
        return try library.makeFunction(name: name, constantValues: values)
    }
}
#endif
