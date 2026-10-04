import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import os
import simd
import Testing

@MainActor
@Suite("WPE preparation cancellation")
struct WPEPreparationCancellationTests {
    private func puppetPipeline() -> WPEPreparedRenderPipeline {
        let pass = WPERenderPass(
            id: "puppet.material", phase: .material, shader: "genericimage2",
            source: .image("white"), target: .scene, textures: [0: .image("white")],
            binds: [:], constants: [:], combos: [:], blending: "disabled", cullMode: "nocull",
            depthTest: "disabled", depthWrite: "disabled"
        )
        let model = WPEPuppetModel(version: 23, meshes: [WPEPuppetMesh(
            materialPath: "white",
            vertices: [
                WPEPuppetVertex(position: SIMD3<Float>(-4, -4, 0), uv: SIMD2<Float>(0, 1)),
                WPEPuppetVertex(position: SIMD3<Float>(4, -4, 0), uv: SIMD2<Float>(1, 1)),
                WPEPuppetVertex(position: SIMD3<Float>(-4, 4, 0), uv: SIMD2<Float>(0, 0)),
                WPEPuppetVertex(position: SIMD3<Float>(4, 4, 0), uv: SIMD2<Float>(1, 0)),
            ], indices: [0, 1, 2, 2, 1, 3], parts: []
        )])
        let layer = WPERenderLayer(
            objectID: "puppet", objectName: "Cancellation puppet", imagePath: "puppet.mdl", materialPath: nil,
            puppetPath: "puppet.mdl",
            geometry: WPERenderLayerGeometry(
                origin: SIMD3<Double>(8, 8, 0), scale: SIMD3<Double>(1, 1, 1), angles: .zero,
                alignment: .center, size: CGSize(width: 8, height: 8), alpha: 1,
                color: SIMD3<Double>(1, 1, 1), brightness: 1
            ),
            compositeA: "a", compositeB: "b", localFBOs: [], passes: [pass]
        )
        return WPEPreparedRenderPipeline(layers: [WPEPreparedRenderLayer(
            graphLayer: layer, puppetModel: model, passes: [WPEPreparedRenderPass(
                pass: pass,
                shader: WPEShaderProgram(name: pass.shader, vertexSource: "", fragmentSource: "", isBuiltin: true),
                textureBindings: pass.textures, comboValues: [:], uniformValues: [:]
            )]
        )])
    }

    private func whiteTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        [UInt8](repeating: 255, count: 16).withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: 8)
        }
        return texture
    }

    #if DEBUG
    @Test("A controlled mid-render cancellation releases palette buffers, arena and the frame slot")
    func cancellationBeforeSubmissionReleasesEncodedResources() async throws {
        let worker = Task {
            let device = try #require(MTLCreateSystemDefaultDevice())
            let executor = try WPEMetalRenderExecutor(device: device)
            executor.synchronizeFrameCompletion = false
            let texture = try whiteTexture(device: device)
            let submission = try executor.beginFrameSubmission()
            let occupied = try executor.beginFrameSubmission()
            defer { submission.seal(); occupied.seal() }
            let slot = submission.slot
            executor.beforeFrameSubmissionForTesting = {
                #expect(!executor.bonePaletteBuffersInFlight.isEmpty, "A real mesh draw must borrow a palette buffer")
                let region = try #require(executor.uniformArena.reserve(slotCount: 4, frameSlot: slot))
                region.storage.update(repeating: SIMD4<Float>(1, 2, 3, 4))
                withUnsafeCurrentTask { $0?.cancel() }
            }
            defer { executor.beforeFrameSubmissionForTesting = nil }
            var presentCalled = false
            #expect(throws: CancellationError.self) {
                try executor.render(
                    pipeline: puppetPipeline(), size: CGSize(width: 16, height: 16), textures: ["white": texture],
                    frameSubmission: submission,
                    deferredPresent: { _, _ in presentCalled = true; return true }
                )
            }
            #expect(!presentCalled)
            #expect(executor.bonePaletteBuffersInFlight.isEmpty)
            #expect(executor.uniformArena.inFlightCount(ofSlot: slot) == 0)
            #expect(executor.currentUniformArenaSlot == nil)
            submission.seal()
            let reused = try executor.beginFrameSubmission()
            #expect(reused.slot == slot)
            reused.seal()
            executor.uniformArena.beginFrame(slot: slot)
            let rewound = try #require(executor.uniformArena.reserve(slotCount: 4, frameSlot: slot))
            #expect(rewound.offset == 0)
        }
        try await worker.value
    }

    @Test("Cancellation after present acceptance still submits and drains registered ownership")
    func cancellationAfterPresentAcceptanceCommits() async throws {
        let worker = Task { try assertAcceptedCancellationDrains() }
        try await worker.value
    }

    private func assertAcceptedCancellationDrains() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let executor = try WPEMetalRenderExecutor(device: device)
        executor.synchronizeFrameCompletion = false
        let texture = try whiteTexture(device: device)
        let submission = try executor.beginFrameSubmission()
        let occupied = try executor.beginFrameSubmission()
        defer { submission.seal(); occupied.seal() }
        let slot = submission.slot
        let production = WPEMetalFrameProductionCompletion()
        let productionResult = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        production.observe { result in productionResult.withLock { $0 = result } }
        let tracker = executor.presentTracker
        var submittedBuffer: MTLCommandBuffer?
        let output = try executor.render(
            pipeline: puppetPipeline(), size: CGSize(width: 16, height: 16), textures: ["white": texture],
            frameSubmission: submission, frameProduction: production,
            deferredPresent: { output, commandBuffer in
                submittedBuffer = commandBuffer
                #expect(!executor.bonePaletteBuffersInFlight.isEmpty)
                let region = try #require(executor.uniformArena.reserve(slotCount: 4, frameSlot: slot))
                region.storage.update(repeating: SIMD4<Float>(5, 6, 7, 8))
                let sourceID = ObjectIdentifier(output)
                tracker.increment(sourceID)
                commandBuffer.addCompletedHandler { _ in tracker.decrement(sourceID) }
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        )
        submission.seal()
        production.seal()
        let commandBuffer = try #require(submittedBuffer)
        commandBuffer.waitUntilCompleted()
        #expect(commandBuffer.status == .completed)
        #expect(!tracker.isInFlight(ObjectIdentifier(output)))
        #expect(executor.uniformArena.inFlightCount(ofSlot: slot) == 0)
        #expect(executor.bonePaletteBuffersInFlight.isEmpty)
        #expect(productionResult.withLock { $0 } == true)
        let reused = try executor.beginFrameSubmission()
        #expect(reused.slot == slot)
        reused.seal()
        executor.uniformArena.beginFrame(slot: slot)
        #expect(try #require(executor.uniformArena.reserve(slotCount: 4, frameSlot: slot)).offset == 0)
    }
    #endif

    @Test("Cancelled scene preparation retires its state without reporting a load fault")
    func cancelledLoadDoesNotPublishFailureDiagnostics() async throws {
        let fixture = try MetalSceneFixture.solidColorScene()
        defer { fixture.cleanup() }
        let renderer = try WPEMetalSceneRenderer(
            descriptor: fixture.descriptor, cacheRootURL: fixture.root, dependencyMounts: [],
            frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: #require(MTLCreateSystemDefaultDevice())
        )
        defer { renderer.cleanup() }
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await renderer.load() }
        }
        await worker.value
        #expect(!renderer.didLoad)
        #expect(renderer.outputTexture == nil)
        #expect(renderer.loadDiagnostics == nil)
        try await renderer.load()
        #expect(renderer.didLoad)
        #expect(renderer.outputTexture != nil)
        #expect(renderer.loadDiagnostics == nil)
    }
}
