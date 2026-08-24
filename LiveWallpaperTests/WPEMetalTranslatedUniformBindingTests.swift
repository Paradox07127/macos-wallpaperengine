#if !LITE_BUILD
import Foundation
import Metal
import Testing
@testable import LiveWallpaper

/// The `>4 KB` uniform path used to swallow an allocation failure: the branch was
/// an `else if let` with no `else`, so the slot stayed unbound and nothing was
/// logged, leaving the fragment stage to read undefined uniforms in silence.
@Suite("WPE translated uniform binding")
struct WPEMetalTranslatedUniformBindingTests {

    private struct Harness {
        let executor: WPEMetalRenderExecutor
        /// Retained so the encoder outlives its command buffer's local scope.
        let commandBuffer: MTLCommandBuffer
        let encoder: MTLRenderCommandEncoder
    }

    private static func makeHarness() throws -> Harness {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 16, height: 16, mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget]
        textureDescriptor.storageMode = .private
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        let renderPass = MTLRenderPassDescriptor()
        renderPass.colorAttachments[0].texture = texture
        renderPass.colorAttachments[0].loadAction = .clear
        renderPass.colorAttachments[0].storeAction = .store
        let commandBuffer = try #require(queue.makeCommandBuffer())
        return Harness(
            executor: try WPEMetalRenderExecutor(device: device),
            commandBuffer: commandBuffer,
            encoder: try #require(commandBuffer.makeRenderCommandEncoder(descriptor: renderPass))
        )
    }

    private static func slots(_ count: Int) -> [SIMD4<Float>] {
        (0..<count).map { SIMD4<Float>(Float($0), 0, 0, 0) }
    }

    @Test("At or under 4 KB the slots still ride the inline fast path")
    func inlinePathIsUnchanged() throws {
        let harness = try Self.makeHarness()
        // 256 × 16 bytes is exactly the `setFragmentBytes` cap.
        let outcome = harness.executor.bindTranslatedUniformSlots(
            Self.slots(256), to: harness.encoder
        )
        harness.encoder.endEncoding()

        #expect(outcome == .inline(byteCount: 4096))
        #expect(harness.executor.gpuErrorSink.summary.count == 0)
    }

    @Test("Above 4 KB the slots bind a transient buffer")
    func largePathBindsABuffer() throws {
        let harness = try Self.makeHarness()
        let outcome = harness.executor.bindTranslatedUniformSlots(
            Self.slots(257), to: harness.encoder
        )
        harness.encoder.endEncoding()

        #expect(outcome == .buffer(byteCount: 4112))
        #expect(harness.executor.gpuErrorSink.summary.count == 0)
    }

    @Test("An empty slot array binds nothing and reports nothing")
    func emptySlotsAreANoOp() throws {
        let harness = try Self.makeHarness()
        let outcome = harness.executor.bindTranslatedUniformSlots([], to: harness.encoder)
        harness.encoder.endEncoding()

        #expect(outcome == .empty)
        #expect(harness.executor.gpuErrorSink.summary.count == 0)
    }

    @Test("A failed large-buffer allocation is reported, not silently skipped")
    func allocationFailureIsReported() throws {
        let harness = try Self.makeHarness()
        var attempts: [Int] = []

        var outcome: WPEMetalRenderExecutor.TranslatedUniformBinding = .empty
        for _ in 0..<3 {
            outcome = harness.executor.bindTranslatedUniformSlots(
                Self.slots(257),
                to: harness.encoder,
                allocate: { _, byteCount in
                    attempts.append(byteCount)
                    return nil
                }
            )
        }
        harness.encoder.endEncoding()

        #expect(outcome == .allocationFailed(byteCount: 4112))
        // The seam really was the >4 KB branch, three times over.
        #expect(attempts == [4112, 4112, 4112])
        // Every failure reaches the sink the scene diagnostics read.
        let summary = harness.executor.gpuErrorSink.summary
        #expect(summary.count == 3)
        #expect(summary.last?.contains("uniform-buffer") == true)
        #expect(summary.last?.contains("4112") == true)
    }
}
#endif
