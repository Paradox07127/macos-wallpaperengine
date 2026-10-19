#if !LITE_BUILD
import Foundation
import Metal

/// Terminal presentation has no material blend, depth or native-alpha variants.
final class WPEMetalPipelineCache {
    private struct Key: Hashable {
        let vertex: String
        let fragment: String
        let format: MTLPixelFormat
    }

    private let device: MTLDevice
    private let library: MTLLibrary
    private var states: [Key: MTLRenderPipelineState] = [:]

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    func pipelineState(vertexName: String, fragmentName: String, colorPixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = Key(vertex: vertexName, fragment: fragmentName, format: colorPixelFormat)
        if let cached = states[key] {
            return cached
        }
        guard let vertex = library.makeFunction(name: vertexName),
              let fragment = try WPEMetalColorOutput.fragment(library: library, name: fragmentName, format: colorPixelFormat) else {
            throw WPEMetalRenderError.pipelineUnavailable(fragmentName)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = false
        descriptor.colorAttachments[0].writeMask = .all
        do {
            let state = try device.makeRenderPipelineState(descriptor: descriptor)
            states[key] = state
            return state
        } catch {
            throw WPEMetalRenderError.pipelineStateBuildFailed(name: fragmentName, detail: error.localizedDescription)
        }
    }
}
#endif
