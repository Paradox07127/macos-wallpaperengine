import CoreVideo
import Foundation
import IOSurface
import Metal

/// Out-of-process scene renderer.
///
/// Currently only the feasibility probe: everything else in the isolation plan
/// depends on an `IOSurface` written here being readable by the sandboxed app,
/// so that is proven before any renderer moves across the boundary.
final class SceneRunner: NSObject, SceneRunnerProtocol {

    /// One device for the service's lifetime; creating one per call would make
    /// the probe measure device creation rather than surface sharing.
    private static let device = MTLCreateSystemDefaultDevice()

    func renderProbeSurface(
        width: Int,
        height: Int,
        red: Int,
        green: Int,
        blue: Int,
        with reply: @escaping (IOSurface?, String?) -> Void
    ) {
        // Caller-supplied dimensions land in an allocation; a hostile or buggy
        // caller must not be able to ask for an arbitrary amount of memory.
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            reply(nil, "probe dimensions out of range")
            return
        }
        guard let device = Self.device else {
            reply(nil, "no Metal device in the service process")
            return
        }

        let bytesPerElement = 4
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width,
            .height: height,
            .bytesPerElement: bytesPerElement,
            // Matches `.bgra8Unorm` below. A mismatch here does not fail loudly —
            // it produces a texture whose bytes are reinterpreted.
            .pixelFormat: kCVPixelFormatType_32BGRA
        ]
        guard let surface = IOSurface(properties: properties) else {
            reply(nil, "IOSurface allocation failed")
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
            reply(nil, "makeTexture(iosurface:) returned nil")
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(red) / 255, green: Double(green) / 255,
            blue: Double(blue) / 255, alpha: 1
        )
        guard let queue = device.makeCommandQueue(),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            reply(nil, "could not encode the probe clear")
            return
        }
        encoder.endEncoding()
        buffer.commit()
        // Synchronous on purpose: replying before the GPU has written would hand
        // back a surface whose contents are undefined, and the probe would then
        // be measuring luck.
        buffer.waitUntilCompleted()

        if let error = buffer.error {
            reply(nil, "probe command buffer failed: \(error.localizedDescription)")
            return
        }
        reply(surface, nil)
    }
}
