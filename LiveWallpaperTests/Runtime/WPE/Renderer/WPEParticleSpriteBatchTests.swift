import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import Testing

@Suite("Particle sprite draw batches")
struct WPEParticleSpriteBatchTests {
    private let size = CGSize(width: 41, height: 29)

    private func texture(_ device: MTLDevice, color: SIMD4<UInt8>) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        var color = color
        withUnsafeBytes(of: &color) {
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 4)
        }
        return texture
    }

    private func bytes(_ texture: MTLTexture) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false
        )
        descriptor.storageMode = .shared
        let staging = try #require(texture.device.makeTexture(descriptor: descriptor))
        let queue = try #require(texture.device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let blit = try #require(command.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: staging, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        try #require(command.status == .completed)
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        bytes.withUnsafeMutableBytes {
            staging.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    @MainActor
    @Test("Production draw batches preserve pixels and split incompatible state",
          arguments: ["same", "tint", "offset", "brightness", "texture", "mask", "refract", "gap"])
    func drawBatchPixels(boundary: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 3,
            "emitter": [["name": "boxrandom", "instantaneous": 3, "rate": 0]],
            "initializer": [["name": "sizerandom", "min": 11, "max": 11],
                            ["name": "lifetimerandom", "min": 10, "max": 10]],
        ])
        let prototype = try #require(WPEParticleSystem(
            definition: definition, device: device,
            sceneTransform: .init(sceneSize: SIMD2(41, 29), objectOrigin: SIMD3(20.5, 14.5, 0),
                                  objectScale: SIMD3(repeating: 1), objectAngleZ: 0),
            seed: 1, usesFrameArena: true
        ))
        let sprite = try texture(device, color: SIMD4(190, 60, 230, 90))
        let alternate = try texture(device, color: SIMD4(30, 210, 40, 130))
        let normal = try texture(device, color: SIMD4(128, 128, 255, 255))
        var systems: [WPEParticleSystem] = []
        var textures: [ObjectIdentifier: MTLTexture] = [:]
        var normals: [ObjectIdentifier: MTLTexture] = [:]
        for index in 0 ..< 6 {
            let system = try #require(prototype.makeEventInstance(device: device, seed: UInt64(index + 1)))
            system.instanceOriginOffset = SIMD3(Float(index) - 2.5, 0, 0)
            if index == 2 {
                switch boundary {
                case "tint": system.groupTint = SIMD3(0.2, 1, 0.5)
                case "offset": system.hostOriginOffset = SIMD2(2, 1)
                case "brightness": system.overbright = 2
                case "mask": system.groupOpacityMask = alternate
                default: break
                }
            }
            system.advanceSimulation(now: 0)
            system.advanceSimulation(now: 0.05)
            try #require(system.liveInstanceCount == 3)
            systems.append(system)
            textures[ObjectIdentifier(system)] = boundary == "texture" && index == 2 ? alternate : sprite
            if boundary == "refract", index == 2 {
                normals[ObjectIdentifier(system)] = normal
            }
        }
        let arena = WPEParticleFrameArena(device: device)
        var arenaSystems = systems
        if boundary == "gap" {
            let spacer = try #require(prototype.makeEventInstance(device: device, seed: 99))
            spacer.advanceSimulation(now: 0)
            spacer.advanceSimulation(now: 0.05)
            arenaSystems.insert(spacer, at: 2)
        }
        try #require(arena.prepare(arenaSystems, frameSlot: 0))
        let camera = WPEMetalCameraUniforms(
            orthogonalProjection: .init(width: 41, height: 29, auto: true), sceneCamera: .defaultCamera
        )
        var expected: [UInt8]?
        for disable in [true, false] {
            let executor = try WPEMetalRenderExecutor(device: device, diagnosticControls: .init(environment:
                disable ? ["WPE_DIAGNOSTIC_DISABLE_PARTICLE_DRAW_BATCHING": "1"] : [:]))
            let output = try executor.render(
                pipeline: .init(layers: []), size: size, textures: [:], cameraUniforms: camera,
                particleSystems: systems, particleTextures: textures, particleNormalTextures: normals
            )
            let actual = try bytes(output)
            #expect(actual.contains { $0 != 0 })
            if let expected {
                #expect(actual == expected)
            } else {
                expected = actual
            }
            let stats = executor.lastDiagnosticFrameStats
            #expect(!stats.perPassReadbackActive)
            #expect(stats.particleDrawBatchingEnabled == !disable)
            #expect(stats.particleSystemsEncoded == 6)
            let enabledDraws = boundary == "same" ? 1 : boundary == "gap" ? 2 : 3
            #expect(stats.particleDrawCount == (disable ? 6 : enabledDraws))
            #expect(stats.particleEncoderCount == (boundary == "refract" ? 3 : 1))
        }
    }

    @Test("Batch planning respects layer threshold and all projection fields")
    func batchThresholdAndProjection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let definition = WPEParticleDefinitionParser.parse(dictionary: [
            "maxcount": 1, "emitter": [["name": "boxrandom", "instantaneous": 1, "rate": 0]],
            "initializer": [["name": "lifetimerandom", "min": 10, "max": 10]],
        ])
        let first = try #require(WPEParticleSystem(definition: definition, device: device, usesFrameArena: true))
        let second = try #require(first.makeEventInstance(device: device, seed: 2))
        for system in [first, second] {
            system.advanceSimulation(now: 0)
            system.advanceSimulation(now: 0.05)
        }
        first.sortIndex = 1
        second.sortIndex = 2
        let arena = WPEParticleFrameArena(device: device)
        try #require(arena.prepare([first, second], frameSlot: 0))
        let sprite = try texture(device, color: SIMD4(255, 255, 255, 255))
        let executor = try WPEMetalRenderExecutor(device: device)
        let camera = WPEMetalCameraUniforms(orthogonalProjection: .init(width: 41, height: 29, auto: true),
                                            sceneCamera: .defaultCamera)
        var cursor = 1
        let batch = executor.particleSpriteBatch(
            startingWith: first, following: [first, second], cursor: &cursor, threshold: 2, enabled: true,
            textures: [ObjectIdentifier(first): sprite, ObjectIdentifier(second): sprite], normals: [:],
            sceneSize: size, cameraParallax: .neutral, cameraUniforms: camera
        )
        #expect(cursor == 1 && batch.systemCount == 1)
        let uniforms = try #require(batch.uniforms)
        #expect(uniforms.matches(uniforms))
        var projection = uniforms.projection
        projection.worldToModel.columns.2.w = 2
        #expect(!uniforms.matches(.init(projection: projection, sprite: uniforms.sprite)))
        projection = uniforms.projection
        projection.cameraOrientation.columns.1.z = 0.25
        #expect(!uniforms.matches(.init(projection: projection, sprite: uniforms.sprite)))
    }
}
