#if !LITE_BUILD
import CoreGraphics
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import simd
import Testing

@Suite("Composelayer sampled by another layer", .serialized)
struct WPEDependencyComposeCaptureTests {
    private static let width = 64, height = 36
    private static let size = CGSize(width: width, height: height)
    private static let composite = WPERenderTargetNames.ImageLayerComposite.make(objectID: "producer")
    private static let tolerance = 2

    /// R = 3·column, G = 6·row, B = 40: linear in both axes, so bilinear taps reproduce the analytic value.
    private static func seedBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let index = (row * width + column) * 4
                bytes[index] = UInt8(column * 3)
                bytes[index + 1] = UInt8(row * 6)
                bytes[index + 2] = 40
                bytes[index + 3] = 255
            }
        }
        return bytes
    }

    private static func seedTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: seedBytes(), bytesPerRow: width * 4)
        return texture
    }

    private static let copyPhase = WPERenderPassPhase.command(file: "effects/copy/effect.json")

    private static func pass(
        _ id: String, phase: WPERenderPassPhase, shader: String, source: WPETextureReference, target: WPERenderTarget
    ) -> WPEPreparedRenderPass {
        let raw = WPERenderPass(
            id: id, phase: phase, shader: shader, source: source, target: target, textures: [0: source],
            binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull",
            depthTest: "disabled", depthWrite: "disabled"
        )
        return WPEPreparedRenderPass(
            pass: raw, shader: WPEShaderProgram(name: shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
            textureBindings: [0: source], comboValues: [:], uniformValues: [:]
        )
    }

    private static func plainLayer(_ id: String, source: WPETextureReference) -> WPEPreparedRenderLayer {
        let copy = pass("\(id).0", phase: copyPhase, shader: "commands/copy", source: source, target: .scene)
        let names = WPERenderTargetNames.ImageLayerComposite.make(objectID: id)
        let layer = WPERenderLayer(
            objectID: id, objectName: id, imagePath: id, materialPath: nil, geometry: .identity,
            compositeA: names.a, compositeB: names.b, localFBOs: [], passes: [copy.pass]
        )
        return WPEPreparedRenderLayer(graphLayer: layer, passes: [copy])
    }

    /// A centred, scene-sized composelayer; `drawsBack` adds the scene copy a visible layer would carry.
    private static func producer(scale: Double, drawsBack: Bool) -> WPEPreparedRenderLayer {
        let capture = pass("producer.0", phase: .material, shader: "compose",
                           source: .fbo("_rt_FullFrameBuffer"), target: .layerComposite(name: composite.a))
        let drawBack = pass("producer.1", phase: .command(file: WPERenderPassPhase.sceneCopyCommandFile),
                            shader: WPERenderPassPhase.sceneCopyCommandFile, source: .fbo(composite.a), target: .scene)
        let passes = drawsBack ? [capture, drawBack] : [capture]
        let geometry = WPERenderLayerGeometry(
            origin: SIMD3(32, 18, 0), scale: SIMD3(repeating: scale), angles: .zero, alignment: .center,
            size: size, alpha: 1, color: SIMD3(1, 1, 1), brightness: 1
        )
        let layer = WPERenderLayer(
            objectID: "producer", objectName: "Producer", imagePath: "models/util/composelayer.json",
            materialPath: "materials/util/composelayer.json", geometry: geometry,
            compositeA: composite.a, compositeB: composite.b, localFBOs: [], passes: passes.map(\.pass)
        )
        return WPEPreparedRenderLayer(graphLayer: layer, passes: passes)
    }

    private static func render(
        _ executor: WPEMetalRenderExecutor, _ pipeline: WPEPreparedRenderPipeline, seed: MTLTexture
    ) throws -> [UInt8] {
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: WPESceneOrthogonalProjection(width: Double(width), height: Double(height), auto: true),
            sceneCamera: .defaultCamera
        )
        let output = try executor.render(pipeline: pipeline, size: size, textures: ["seed": seed], cameraUniforms: camera)
        let staging = try #require(WPEMetalTextureSnapshotter.stagedForCPURead(output))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            staging.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    /// FullFrame(s·u + (1 − s)/2, s·v + (1 − s)/2) with clamp-to-edge linear filtering, as WPE's capture MVP samples it.
    private static func expectedCapture(scale: Double) -> [UInt8] {
        let seed = seedBytes()
        func texel(_ column: Int, _ row: Int, _ channel: Int) -> Double {
            let x = min(max(column, 0), width - 1), y = min(max(row, 0), height - 1)
            return Double(seed[(y * width + x) * 4 + channel])
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0 ..< height {
            for column in 0 ..< width {
                let u = scale * (Double(column) + 0.5) / Double(width) + (1 - scale) / 2
                let v = scale * (Double(row) + 0.5) / Double(height) + (1 - scale) / 2
                let x = u * Double(width) - 0.5, y = v * Double(height) - 0.5
                let x0 = Int(floor(x)), y0 = Int(floor(y))
                let fx = x - Double(x0), fy = y - Double(y0)
                for channel in 0 ..< 4 {
                    let top = texel(x0, y0, channel) * (1 - fx) + texel(x0 + 1, y0, channel) * fx
                    let bottom = texel(x0, y0 + 1, channel) * (1 - fx) + texel(x0 + 1, y0 + 1, channel) * fx
                    bytes[(row * width + column) * 4 + channel] = UInt8((top * (1 - fy) + bottom * fy).rounded())
                }
            }
        }
        return bytes
    }

    private static func worstError(_ actual: [UInt8], _ expected: [UInt8]) -> Int {
        zip(actual, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    @Test("A hidden scaled composelayer read by another layer captures through its own transform")
    func sampledHiddenComposeCapturesThroughTransform() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let seed = try Self.seedTexture(device: device)
        let producer = Self.producer(scale: 1.5, drawsBack: false)
        let pipeline = WPEPreparedRenderPipeline(layers: [
            Self.plainLayer("seed", source: .image("seed")), producer,
            Self.plainLayer("consumer", source: .fbo(Self.composite.a)),
        ])
        let bytes = try Self.render(executor, pipeline, seed: seed)
        #expect(executor.sceneCaptureUtilityOutputGeometry(for: producer.graphLayer) == .subregion)
        let worst = Self.worstError(bytes, Self.expectedCapture(scale: 1.5))
        #expect(worst <= Self.tolerance, "worst channel error \(worst)")
        print("WPEDependencyComposeCaptureTests scaled capture worst error \(worst)")
    }

    @Test("An unscaled sampled composelayer still captures the frame 1:1")
    func sampledIdentityComposeStaysFullscreen() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let seed = try Self.seedTexture(device: device)
        let producer = Self.producer(scale: 1, drawsBack: false)
        let pipeline = WPEPreparedRenderPipeline(layers: [
            Self.plainLayer("seed", source: .image("seed")), producer,
            Self.plainLayer("consumer", source: .fbo(Self.composite.a)),
        ])
        #expect(try Self.render(executor, pipeline, seed: seed) == Self.seedBytes())
        #expect(executor.sceneCaptureUtilityOutputGeometry(for: producer.graphLayer) == .fullscreen)
    }

    @Test("A scaled composelayer nobody reads keeps the 1:1 fullscreen passthrough")
    func unsampledComposeKeepsFullscreen() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        let seed = try Self.seedTexture(device: device)
        let producer = Self.producer(scale: 1.5, drawsBack: true)
        let pipeline = WPEPreparedRenderPipeline(layers: [Self.plainLayer("seed", source: .image("seed")), producer])
        #expect(try Self.render(executor, pipeline, seed: seed) == Self.seedBytes())
        #expect(executor.sceneCaptureUtilityOutputGeometry(for: producer.graphLayer) == .fullscreen)
        #expect(executor.targetPool.sampledCompositeObjectIDs.isEmpty)
    }
}
#endif
