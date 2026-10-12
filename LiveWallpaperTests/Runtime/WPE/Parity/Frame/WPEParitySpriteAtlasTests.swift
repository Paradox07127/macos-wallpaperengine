#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import XCTest

/// A TEXS sheet whose frames span two TEXB images binds, at each time, the image of the frame showing then.
final class WPEParitySpriteAtlasTests: XCTestCase {
    private static let side = 4
    /// Each frame shows for half a second; the clock advances at most 0.25 s per frame.
    private static let frameTime: Float = 0.5

    func testDrawBindsTheImageOfTheFrameShowing() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let image = try WPEParityFrameDrawPlanner.image(WPEMappedByteSpan(data: Self.twoImageSheet()), device: device)
        XCTAssertEqual(image.sprites.count, 2)
        let plan = try makePlan(image, device: device)

        // t = 0.25 is in frame 0 (image 0); t = 0.75 is in frame 1 (image 1).
        let first = try boundTexture(plan, advances: 1)
        let second = try boundTexture(plan, advances: 3)
        XCTAssertTrue(first === image.texture, "frame 0 binds image 0")
        XCTAssertFalse(second === image.texture, "frame 1 binds image 1, not image 0")
        XCTAssertEqual(second.pixelFormat, first.pixelFormat)
        XCTAssertEqual(second.storageMode, first.storageMode)
        XCTAssertNotEqual(try firstPixel(first, queue: queue), try firstPixel(second, queue: queue))
    }

    private func boundTexture(_ plan: WPEParityFrameDrawPlan, advances: Int) throws -> MTLTexture {
        var clock = WPEParityClock()
        for _ in 0 ..< advances {
            clock.advance(elapsed: 0.25, ratePercent: 100, paused: false)
        }
        let frame = WPEParityUniformFrame(clock: clock, daytime: 0,
                                          screen: WPEParityUniformScreen(clientWidth: 1, clientHeight: 1),
                                          pointer: WPEParityUniformPointer(), parallax: WPEParityUniformParallax(),
                                          eyePosition: .zero, view: matrix_identity_float4x4)
        var slots: [String: WPECBufferValue] = [:]
        let draw = try plan.makeDraw(frame: frame, variant: 0, textures: [:], textureSlots: &slots, puppets: [:])
        return try XCTUnwrap(draw.textures["g_Texture0"])
    }

    private func makePlan(_ image: WPEParityFrameDrawPlanner.Image,
                          device: MTLDevice) throws -> WPEParityFrameDrawPlan {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        vertex float4 spriteVertex() { return float4(0, 0, 0, 1); }
        fragment float4 spriteFragment() { return float4(1); }
        """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "spriteVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "spriteFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        func stage(_ stage: WPEStageReflection.Stage) throws -> WPEParityPipeline.Stage {
            try WPEParityPipeline.Stage(WPEStageReflection(stage: stage, cbuffers: [], resources: [],
                                                           topLevelArgumentBuffer: []))
        }
        let pipeline = try WPEParityPipeline(state: device.makeRenderPipelineState(descriptor: descriptor),
                                             vertex: stage(.vertex), fragment: stage(.fragment))
        let buffer = try XCTUnwrap(device.makeBuffer(length: 16, options: .storageModeShared))
        let side = UInt32(Self.side)
        var textures = [WPEParityUniformTexture?](repeating: nil, count: WPEParityUniformTextures.slotCount)
        textures[0] = WPEParityUniformTexture(textureWidth: side, textureHeight: side, imageWidth: side,
                                              imageHeight: side, mipMapInfo: 1)
        return WPEParityFrameDrawPlan(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: buffer,
            indexBuffer: buffer,
            indexCount: 6,
            puppetID: nil,
            textures: [["g_Texture0": .image(image.texture)]],
            samplers: [:],
            uniforms: WPEParityUniformDraw(matrices: .effectPass, textures: textures),
            placement: nil,
            sprites: [0: image.sprites],
            constants: [:],
            zeroConstants: [:]
        )
    }

    private func firstPixel(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let buffer = try XCTUnwrap(queue.device.makeBuffer(length: 4, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: 4, destinationBytesPerImage: 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: 4))
    }

    // MARK: Fixture

    /// RGBA8888 .tex with TEXI flag 0x4, two 4×4 TEXB images (red, blue) and a TEXS frame on each.
    private static func twoImageSheet() -> Data {
        var data = Data()
        func magic(_ text: String) {
            data.append(contentsOf: text.utf8)
            data.append(0)
        }
        func int(_ value: Int32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func float(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        let side = Int32(Self.side)
        magic("TEXV0005")
        magic("TEXI0001")
        int(Int32(WPETexFormat.rgba8888.rawValue))
        int(0x4)
        for _ in 0 ..< 2 {
            int(side)
            int(side)
        }
        int(0)

        magic("TEXB0003")
        int(2)
        int(-1)
        for color: [UInt8] in [[255, 0, 0, 255], [0, 0, 255, 255]] {
            let pixels = Data((0 ..< Self.side * Self.side).flatMap { _ in color })
            int(1)
            int(side)
            int(side)
            int(0)
            int(Int32(pixels.count))
            int(Int32(pixels.count))
            data.append(pixels)
        }

        // TEXS3: frame count, gif size, then per frame image, time, x, y, width, widthY, heightX, height.
        magic("TEXS0003")
        int(2)
        int(side)
        int(side)
        for imageID: Int32 in [0, 1] {
            int(imageID)
            for value in [Self.frameTime, 0, 0, Float(side), 0, 0, Float(side)] {
                float(value)
            }
        }
        return data
    }
}
#endif
