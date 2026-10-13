#if !LITE_BUILD && DEBUG
import Foundation
@testable import LiveWallpaper
import LiveWallpaperProWPE
import Metal
import XCTest

final class WPEParityGraphExecutionTests: XCTestCase {
    private static let side = 4
    private static let formats: [String: MTLPixelFormat] = ["rgba8unorm": .rgba8Unorm]

    private struct Harness {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let factory: WPEParityPipelineFactory
        let encoder: WPEParityDrawEncoder
        let arena: WPEParityFrameArena
    }

    // MARK: Tests

    func testLiveClearUsesTheLastOperationOfTheExactSubresource() throws {
        let harness = try makeHarness()
        let (r, s, t) = try (makeTexture(harness, mips: 2), makeTexture(harness), makeTexture(harness))
        let red = WPEClearColor(red: 1, green: 0, blue: 0, alpha: 1)
        let green = WPEClearColor(red: 0, green: 1, blue: 0, alpha: 1)
        let blue = WPEClearColor(red: 0, green: 0, blue: 1, alpha: 1)
        let yellow = WPEClearColor(red: 1, green: 1, blue: 0, alpha: 1)
        let owner = WPEPassIdentity("text/background")
        let graph = try WPERenderGraphCompiler.compile(resources: [resource("R", .persistent, mips: 2), resource("S", .persistent), resource("T", .pooled)],
                                                       operations: [
                                                           op(.setTargets(color: [WPETextureView("R", mips: 0 ..< 1), WPETextureView("S")], depth: nil)),
                                                           .init(pass: owner, .clearColor(WPETextureView("R", mips: 0 ..< 1), red)),
                                                           .init(pass: "effect/other", .clearColor(WPETextureView("S"), green)),
                                                           draw(),
                                                           .init(pass: "effect/mip1", .clearColor(WPETextureView("R", mips: 1 ..< 2), green)),
                                                           .init(pass: owner, .clearColor(WPETextureView("T"), red)),
                                                           .init(pass: "effect/later", .clearColor(WPETextureView("T"), yellow)),
                                                       ])
        XCTAssertTrue(graph.steps.contains { $0.encoder?.colorAttachments.count == 2 },
                      "the resource-filter counterexample needs both clears in one encoder")
        let executor = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                  arena: harness.arena, pixelFormats: Self.formats)
        guard case let .committed(buffer) = try executor.encodeFrame(on: harness.queue, textures: ["R": r, "S": s, "T": t],
                                                                     clearColor: { $0 == owner ? blue : nil },
                                                                     visit: { _, _, _, _ in }) else { return XCTFail("frame skipped") }
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        try assertEvery(readBack(harness, r), equals: [0, 0, 255, 255])
        try assertEvery(readBack(harness, r, level: 1), equals: [0, 255, 0, 255])
        try assertEvery(readBack(harness, s), equals: [0, 255, 0, 255])
        try assertEvery(readBack(harness, t), equals: [255, 255, 0, 255])
    }

    func testConditionalStandaloneResolvePreservesHistoryUntilNativeSnapshotBoundary() throws {
        let harness = try makeHarness()
        let history = try makeTexture(harness)
        let output = try makeTexture(harness)
        try execute(harness, WPERenderGraphCompiler.compile(resources: [resource("R", .pooled)],
                                                            operations: [clear("R", .init(red: 0, green: 0, blue: 1, alpha: 1))]),
                    external: ["R": history], draws: [:])
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("M", .frameTransient, samples: 4), resource("R", .pooled), resource("O", .persistent)],
            operations: [bind("M"), clear("M", .init(red: 1, green: 0, blue: 0, alpha: 1)),
                         op(.resolve(source: "M", destination: "R")), op(.copy(source: "R", destination: "O"))],
            preservingTransfers: [2]
        )
        XCTAssertTrue(graph.steps.contains {
            if case .resolve = $0.kind {
                true
            } else {
                false
            }
        })
        XCTAssertNotEqual(graph.storage["M"], .memoryless)
        let executor = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                  arena: harness.arena, pixelFormats: Self.formats)
        for (enabled, expected) in [(false, [UInt8](arrayLiteral: 0, 0, 255, 255)),
                                    (true, [255, 0, 0, 255]), (false, [255, 0, 0, 255])] {
            guard case let .committed(buffer) = try executor.encodeFrame(on: harness.queue,
                                                                         textures: ["R": history, "O": output], shouldTransfer: { $0 != 2 || enabled },
                                                                         visit: { _, _, _, _ in }) else { return XCTFail("frame was skipped") }
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            try assertEvery(readBack(harness, output), equals: expected)
        }
    }

    func testRendererKeepsAuthoredClearAndSwapHistoryAcrossVisibilityAndEffectCaches() async throws {
        let harness = try makeHarness()
        let directory = FileManager.default.temporaryDirectory.appending(path: "parity-graph-renderer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let renderer = try await commandRenderer(harness, directory: directory, authoredClear: true)
        let output = try XCTUnwrap(renderer.targets["O_7"])
        try await submit(renderer)
        try assertEvery(readBack(harness, output), equals: [255, 0, 0, 255])
        XCTAssertTrue(renderer.state.set(.visible, of: "900", to: .zero))
        try await submit(renderer)
        try assertEvery(readBack(harness, output), equals: [0, 255, 0, 255])
        XCTAssertTrue(renderer.state.set(.visible, of: "900", to: .one))
        try await submit(renderer)
        try assertEvery(readBack(harness, output), equals: [255, 0, 0, 255])
        XCTAssertTrue(renderer.state.setEffect("7", of: "1", visible: false))
        for _ in 0 ..< 2 {
            try await submit(renderer)
            try assertEvery(readBack(harness, output), equals: [255, 0, 0, 255])
        }
        XCTAssertTrue(renderer.state.setEffect("7", of: "1", visible: true))
        try await submit(renderer)
        try assertEvery(readBack(harness, output), equals: [0, 255, 0, 255])
    }

    func testRendererResizePreservesCompatibleUnclearedHistoryAndBindingIdentity() async throws {
        let harness = try makeHarness()
        let directory = FileManager.default.temporaryDirectory.appending(path: "parity-graph-resize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await commandRenderer(harness, directory: directory, authoredClear: false)
        let (a, b) = try (XCTUnwrap(original.targets["A_7"]), XCTUnwrap(original.targets["B_7"]))
        try seedHistory(harness, a: a, b: b, first: .init(red: 1, green: 0, blue: 0, alpha: 1),
                        second: .init(red: 0, green: 1, blue: 0, alpha: 1))
        try await submit(original) // Its effect now binds logical A to physical B.
        let resized = try await commandRenderer(harness, directory: directory, authoredClear: false, width: 8, height: 8)
        try resized.continueScene(from: original)
        XCTAssertTrue(resized.targets["A_7"] === a)
        XCTAssertTrue(resized.targets["B_7"] === b)
        try await submit(resized)
        try assertEvery(readBack(harness, XCTUnwrap(resized.targets["O_7"])), equals: [0, 255, 0, 255])
    }

    func testRendererResizeReappliesAuthoredClearEvenWhenTheFBODescriptorIsUnchanged() async throws {
        let harness = try makeHarness()
        let directory = FileManager.default.temporaryDirectory.appending(path: "parity-graph-resize-clear-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try await commandRenderer(harness, directory: directory, authoredClear: true)
        try await submit(original)
        let (a, b) = try (XCTUnwrap(original.targets["A_7"]), XCTUnwrap(original.targets["B_7"]))
        try seedHistory(harness, a: a, b: b, first: .init(red: 0, green: 0, blue: 1, alpha: 1),
                        second: .init(red: 1, green: 0, blue: 1, alpha: 1))
        let resized = try await commandRenderer(harness, directory: directory, authoredClear: true, width: 8, height: 8)
        try resized.continueScene(from: original)
        try await submit(resized)
        // Native resize clears flagged FBOs even if their explicit size stays 4x4. The effect's saved swap still
        // selects B's restored green, rather than the magenta pixels written before resize.
        try assertEvery(readBack(harness, XCTUnwrap(resized.targets["O_7"])), equals: [0, 255, 0, 255])
    }

    func testOverlappingSwapsExecuteInOrderAndCarryBindingsAcrossSubmissions() throws {
        let harness = try makeHarness()
        let histories = [resource("A", .pooled), resource("B", .pooled), resource("C", .pooled)]
        let (a, b, c) = try (makeTexture(harness), makeTexture(harness), makeTexture(harness))
        try execute(harness, WPERenderGraphCompiler.compile(resources: histories, operations: [
            clear("A", .init(red: 1, green: 0, blue: 0, alpha: 1)),
            clear("B", .init(red: 0, green: 1, blue: 0, alpha: 1)),
            clear("C", .init(red: 0, green: 0, blue: 1, alpha: 1)),
        ]), external: ["A": a, "B": b, "C": c], draws: [:])
        let graph = try WPERenderGraphCompiler.compile(
            resources: histories + [resource("O0", .persistent), resource("O1", .persistent), resource("O2", .persistent)],
            operations: [op(.copy(source: "A", destination: "O0")),
                         op(.swapResources(first: "A", second: "B")),
                         op(.copy(source: "A", destination: "O1")),
                         op(.swapResources(first: "B", second: "C")),
                         op(.copy(source: "B", destination: "O2")),
                         op(.swapResources(first: "A", second: "B")),
                         op(.swapResources(first: "A", second: "B"))]
        )
        let (o0, o1, o2) = try (makeTexture(harness), makeTexture(harness), makeTexture(harness))
        let textures: [WPEResourceID: MTLTexture] = ["A": a, "B": b, "C": c, "O0": o0, "O1": o1, "O2": o2]
        let executor = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                  arena: harness.arena, pixelFormats: Self.formats)
        for expected in [
            [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]],
            [[0, 255, 0, 255], [0, 0, 255, 255], [255, 0, 0, 255]],
        ] as [[[UInt8]]] {
            guard case let .committed(buffer) = try executor.encodeFrame(on: harness.queue, textures: textures,
                                                                         draw: { _, _, _ in [] }) else {
                return XCTFail("frame was skipped")
            }
            buffer.waitUntilCompleted()
            XCTAssertNil(buffer.error)
            for (target, pixel) in zip([o0, o1, o2], expected) {
                try assertEvery(readBack(harness, target), equals: pixel)
            }
        }
        // A cached/rebuilt graph resumes the current permutation using the same physical textures.
        let resumed = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                 arena: harness.arena, pixelFormats: Self.formats)
        resumed.restoreResourceBindings(executor.resourceBindings)
        guard case let .committed(buffer) = try resumed.encodeFrame(on: harness.queue, textures: textures,
                                                                    draw: { _, _, _ in [] }) else {
            return XCTFail("resumed frame was skipped")
        }
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)
        try assertEvery(readBack(harness, o0), equals: [0, 0, 255, 255])
        try assertEvery(readBack(harness, o1), equals: [255, 0, 0, 255])
        try assertEvery(readBack(harness, o2), equals: [0, 255, 0, 255])
        XCTAssertTrue(resumed.resourceBindings.isEmpty, "three cumulative cycles restore physical identity")
    }

    func testExcludedOverwriteLeavesHistoryAvailableToTheNextReader() throws {
        let harness = try makeHarness()
        let histories = [resource("P", .pooled), resource("O", .persistent)]
        let (history, output) = try (makeTexture(harness), makeTexture(harness))
        try execute(harness, WPERenderGraphCompiler.compile(resources: histories, operations: [
            clear("P", .init(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)),
        ]), external: ["P": history], draws: [:])
        let graph = try WPERenderGraphCompiler.compile(
            resources: histories, operations: [bind("P"), draw(overwrites: true), op(.copy(source: "P", destination: "O"))],
            excludingDraws: [1]
        )
        let executor = try execute(harness, graph, external: ["P": history, "O": output], draws: [:])
        XCTAssertNil(executor.transientTextures["P"])
        try assertEvery(readBack(harness, output), equals: [51, 102, 153, 255])
    }

    func testEffectSwapLeavesOtherEffectBindingsIntactWhileSharingWrittenContents() throws {
        let harness = try makeHarness()
        let resources = [resource("A", .pooled), resource("B", .pooled), resource("Inside", .persistent),
                         resource("OutsideA", .persistent), resource("OutsideB", .persistent)]
        let (a, b, inside, outsideA, outsideB) = try (makeTexture(harness), makeTexture(harness), makeTexture(harness),
                                                      makeTexture(harness), makeTexture(harness))
        let external: [WPEResourceID: MTLTexture] = ["A": a, "B": b, "Inside": inside,
                                                     "OutsideA": outsideA, "OutsideB": outsideB]
        try execute(harness, WPERenderGraphCompiler.compile(resources: resources, operations: [
            clear("A", .init(red: 1, green: 0, blue: 0, alpha: 1)),
            clear("B", .init(red: 0, green: 1, blue: 0, alpha: 1)),
        ]), external: external, draws: [:])
        let first = WPEResourceBindingScope.effect(objectID: "L", effectID: "first")
        let second = WPEResourceBindingScope.effect(objectID: "L", effectID: "second")
        let graph = try WPERenderGraphCompiler.compile(resources: resources, operations: [
            op(.resourceScope(scope: first, resources: ["A", "B"])),
            op(.swapResources(first: "A", second: "B")),
            clear("A", .init(red: 0, green: 0, blue: 1, alpha: 1)),
            op(.copy(source: "A", destination: "Inside")),
            op(.resourceScope(scope: .frame, resources: ["A", "B"])),
            op(.resourceScope(scope: second, resources: ["A", "B"])),
            op(.copy(source: "A", destination: "OutsideA")),
            op(.copy(source: "B", destination: "OutsideB")),
            op(.resourceScope(scope: .frame, resources: ["A", "B"])),
        ])
        let executor = try execute(harness, graph, external: external, draws: [:])
        XCTAssertEqual(executor.resourceBindings, [first: ["A": "B", "B": "A"]])
        try assertEvery(readBack(harness, inside), equals: [0, 0, 255, 255])
        try assertEvery(readBack(harness, outsideA), equals: [255, 0, 0, 255])
        try assertEvery(readBack(harness, outsideB), equals: [0, 0, 255, 255])
    }

    func testPartialOpaqueDrawPreservesTheUncoveredHistoryPixels() throws {
        let harness = try makeHarness()
        let histories = [resource("P", .pooled)]
        let history = try makeTexture(harness)
        try execute(harness, WPERenderGraphCompiler.compile(resources: histories, operations: [
            clear("P", .init(red: 0, green: 0, blue: 1, alpha: 1)),
        ]), external: ["P": history], draws: [:])
        let graph = try WPERenderGraphCompiler.compile(resources: histories,
                                                       operations: [bind("P"), draw(overwrites: false)])
        let pipeline = try harness.factory.makePipeline(
            artifact: loadProgram("shaders/flat"), blend: .wpe(.normal, modifiers: .writeAlpha),
            colorPixelFormat: .rgba8Unorm
        )
        var partial = try flatDraw(harness, pipeline: pipeline, color: SIMD3(1, 0, 0), alpha: 1)
        // Same shader/blend as a fullscreen draw, but the VS positions cover only the left half.
        let corners: [(Float, Float)] = [(-1, 1), (-1, -1), (0, 1), (0, -1)]
        let vertices: [Float] = corners.flatMap { [$0.0, $0.1, 0, 1, 1, 1, 1] }
        partial.vertexBuffer = try XCTUnwrap(harness.device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: .storageModeShared
        ))
        try execute(harness, graph, external: ["P": history], draws: [1: partial])
        let expected: [UInt8] = (0 ..< Self.side * Self.side).flatMap { index in
            index % Self.side < Self.side / 2 ? [255, 0, 0, 255] : [0, 0, 255, 255]
        }
        try assertPixels(readBack(harness, history), equal: expected)
    }

    func testClearDrawThenCopyReachesTheCopyDestination() throws {
        let harness = try makeHarness()
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("I", .imported), resource("A", .frameTransient), resource("B", .persistent)],
            operations: [bind("A"), clear("A", .init(red: 1, green: 0, blue: 1, alpha: 1)),
                         draw(sampling: "I", overwrites: true), op(.copy(source: "A", destination: "B"))]
        )
        XCTAssertEqual(graph.storage["A"], .aliased(group: 0))
        let input = try makeInput(harness)
        let target = try makeTexture(harness)
        try execute(harness, graph, external: ["I": input, "B": target],
                    draws: [2: passthroughDraw(harness, sampleCount: 1, input: input)])
        try assertPixels(readBack(harness, target), equal: Self.texels)
    }

    func testPersistentTargetCarriesContentsIntoTheNextFrame() throws {
        let harness = try makeHarness()
        let first = [bind("P"), clear("P", .init(red: 0.4, green: 0.2, blue: 0.6, alpha: 1))]
        let second = [bind("P"), draw(readsDestination: true)]
        let persistentP = resource("P", .persistent)
        let frame1 = try WPERenderGraphCompiler.compile(resources: [persistentP], operations: first)
        let frame2 = try WPERenderGraphCompiler.compile(resources: [persistentP], operations: second)
        let attachment = try XCTUnwrap(frame2.encoders.first?.attachment("P"))
        XCTAssertEqual(attachment.load, .load)
        XCTAssertEqual(attachment.store, .store)
        // Control: the same frame on a frame-transient target discards the entry contents.
        let transient = try WPERenderGraphCompiler.compile(resources: [resource("P", .frameTransient)], operations: second)
        XCTAssertEqual(transient.encoders.first?.attachment("P")?.load, .dontCare)

        let target = try makeTexture(harness)
        try execute(harness, frame1, external: ["P": target], draws: [:])
        // Additive blend reads the destination: result = X + 0.2 per colour channel, alpha untouched.
        let pipeline = try harness.factory.makePipeline(
            artifact: loadProgram("shaders/flat"), blend: .wpe(.additive), colorPixelFormat: .rgba8Unorm
        )
        try execute(harness, frame2, external: ["P": target],
                    draws: [1: flatDraw(harness, pipeline: pipeline, color: SIMD3(0.2, 0.2, 0.2), alpha: 1)])
        try assertEvery(readBack(harness, target), equals: [153, 102, 204, 255])
    }

    func testGenerateMipsAveragesIntoTheSmallestLevel() throws {
        let harness = try makeHarness()
        let mips = 3
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("I", .imported), resource("M", .persistent, mips: mips)],
            operations: [bind("M"), draw(sampling: "I", overwrites: true), op(.generateMips("M"))]
        )
        XCTAssertEqual(graph.steps.last?.kind, .generateMips("M"))
        let input = try makeInput(harness)
        let target = try makeTexture(harness, mips: mips)
        try execute(harness, graph, external: ["I": input, "M": target],
                    draws: [1: passthroughDraw(harness, sampleCount: 1, input: input)])

        let smallest = try readBack(harness, target, level: mips - 1)
        XCTAssertEqual(smallest.count, 4)
        let texelCount = Self.side * Self.side
        for channel in 0 ..< 4 {
            let sum = stride(from: channel, to: Self.texels.count, by: 4).reduce(0) { $0 + Int(Self.texels[$1]) }
            let average = Double(sum) / Double(texelCount)
            // Two box-filter levels, each rounded to 8 bits.
            XCTAssertLessThanOrEqual(abs(Double(smallest[channel]) - average), 2, "channel \(channel)")
        }
    }

    func testSingleMipCopyFillsMipZeroBeforeGenerateMips() throws {
        let harness = try makeHarness()
        let mips = 3
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("I", .imported), resource("A", .frameTransient),
                        resource("M", .persistent, mips: mips)],
            operations: [bind("A"), draw(sampling: "I", overwrites: true), op(.copy(source: "A", destination: "M")),
                         op(.generateMips("M"))]
        )
        let input = try makeInput(harness)
        let target = try makeTexture(harness, mips: mips)
        try execute(harness, graph, external: ["I": input, "M": target],
                    draws: [1: passthroughDraw(harness, sampleCount: 1, input: input)])
        try assertPixels(readBack(harness, target), equal: Self.texels)
        XCTAssertEqual(try readBack(harness, target, level: mips - 1).count, 4)
    }

    func testMultisampledTargetResolvesAtEncoderExit() throws {
        let harness = try makeHarness()
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("I", .imported), resource("M", .frameTransient, samples: 4), resource("R", .persistent)],
            operations: [bind("M"), clear("M", .init(red: 0, green: 0, blue: 0, alpha: 1)),
                         draw(sampling: "I", overwrites: true), op(.resolve(source: "M", destination: "R"))]
        )
        XCTAssertEqual(graph.steps.count, 1)
        XCTAssertEqual(graph.encoders.first?.attachment("M")?.store, .multisampleResolve(into: "R"))
        XCTAssertEqual(graph.storage["M"], .memoryless)
        let input = try makeInput(harness)
        let target = try makeTexture(harness)
        let executor = try execute(harness, graph, external: ["I": input, "R": target],
                                   draws: [2: passthroughDraw(harness, sampleCount: 4, input: input)])
        XCTAssertEqual(executor.transientTextures["M"]?.storageMode, .memoryless)
        XCTAssertEqual(executor.transientTextures["M"]?.sampleCount, 4)
        try assertPixels(readBack(harness, target), equal: Self.texels)
    }

    func testAliasedTransientsDoNotLeakIntoEachOther() throws {
        let harness = try makeHarness()
        let blue = WPEClearColor(red: 0, green: 0, blue: 1, alpha: 1)
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("I", .imported), resource("T1", .frameTransient), resource("T2", .frameTransient),
                        resource("O1", .persistent), resource("O2", .persistent)],
            operations: [bind("T1"), draw(overwrites: true), op(.copy(source: "T1", destination: "O1")),
                         bind("T2"), clear("T2", blue), draw(sampling: "I"), op(.copy(source: "T2", destination: "O2"))]
        )
        XCTAssertEqual(graph.allocationGroups, [["T1", "T2"]])
        let input = try makeInput(harness)
        let (out1, out2) = try (makeTexture(harness), makeTexture(harness))
        let flat = try harness.factory.makePipeline(
            artifact: loadProgram("shaders/flat"), blend: .wpe(.normal, modifiers: .writeAlpha),
            colorPixelFormat: .rgba8Unorm
        )
        // Left half only, so T2's right half shows whether its clear survived T1's memory.
        let leftHalf: [Float] = [-1, 1, 0, 0, 0, -1, -1, 0, 0, 1, 0, 1, 0, 0.5, 0, 0, -1, 0, 0.5, 1]
        let executor = try execute(harness, graph, external: ["I": input, "O1": out1, "O2": out2], draws: [
            1: flatDraw(harness, pipeline: flat, color: SIMD3(1, 0, 0), alpha: 1),
            5: passthroughDraw(harness, sampleCount: 1, input: input, vertices: leftHalf),
        ])
        let t1 = try XCTUnwrap(executor.transientTextures["T1"])
        let t2 = try XCTUnwrap(executor.transientTextures["T2"])
        XCTAssertNotNil(executor.heap)
        XCTAssertTrue(t1.heap === executor.heap && t2.heap === executor.heap)
        XCTAssertEqual(t1.heapOffset, t2.heapOffset)

        try assertEvery(readBack(harness, out1), equals: [255, 0, 0, 255])
        var expected: [UInt8] = []
        for y in 0 ..< Self.side {
            for x in 0 ..< Self.side {
                let start = (y * Self.side + x) * 4
                expected += x < Self.side / 2 ? Array(Self.texels[start ..< start + 4]) : [0, 0, 255, 255]
            }
        }
        try assertPixels(readBack(harness, out2), equal: expected)
    }

    func testSkippedDrawEncodesNothingButItsPassStillClears() throws {
        let harness = try makeHarness()
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("I", .imported), resource("P", .persistent)],
            operations: [bind("P"), clear("P", .init(red: 0, green: 1, blue: 0, alpha: 1)), draw(sampling: "I")],
            excludingDraws: [2]
        )
        let target = try makeTexture(harness)
        let executor = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                  arena: harness.arena, pixelFormats: Self.formats)
        var asked: [Int] = []
        guard case let .committed(commandBuffer) = try executor.encodeFrame(
            on: harness.queue, textures: ["I": makeInput(harness), "P": target], draw: { operation, _, _ in
                asked.append(operation)
                return []
            }
        ) else { return XCTFail("frame was skipped") }
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        XCTAssertTrue(asked.isEmpty)
        try assertEvery(readBack(harness, target), equals: [0, 255, 0, 255])
    }

    func testFrameIsSkippedWhileEveryArenaSlotIsInFlight() throws {
        let harness = try makeHarness()
        let graph = try WPERenderGraphCompiler.compile(
            resources: [resource("P", .persistent), resource("Q", .persistent)],
            operations: [bind("P"), clear("P", .init(red: 1, green: 1, blue: 1, alpha: 1)),
                         op(.swapResources(first: "P", second: "Q"))]
        )
        let target = try makeTexture(harness)
        let partner = try makeTexture(harness)
        let executor = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                  arena: harness.arena, pixelFormats: Self.formats)
        // Never committed, so these slots stay taken for the life of this arena.
        let held = try (0 ..< WPEParityFrameArena.slotCount).map { _ in try XCTUnwrap(harness.queue.makeCommandBuffer()) }
        for commandBuffer in held {
            XCTAssertNotNil(harness.arena.beginFrame(for: commandBuffer))
        }
        let skipped = try executor.encodeFrame(on: harness.queue, textures: ["P": target, "Q": partner]) { _, _, _ in
            throw WPEParityExecutionError.arenaExhausted
        }
        guard case .skipped = skipped else { return XCTFail("frame was committed without an arena slot") }
        XCTAssertTrue(executor.resourceBindings.isEmpty, "a skipped frame must not execute its swap")

        let freeArena = try XCTUnwrap(WPEParityFrameArena(device: harness.device, capacity: 64 * 1024))
        let control = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                 arena: freeArena, pixelFormats: Self.formats)
        guard case let .committed(commandBuffer) = try control.encodeFrame(on: harness.queue, textures: ["P": target, "Q": partner],
                                                                           draw: { _, _, _ in
                                                                               throw WPEParityExecutionError.arenaExhausted
                                                                           })
        else { return XCTFail("frame with a free slot was skipped") }
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        XCTAssertEqual(control.resourceBindings, [.frame: ["P": "Q", "Q": "P"]])
        try assertEvery(readBack(harness, target), equals: [255, 255, 255, 255])
    }

    // MARK: Graph builders

    private struct UnavailableCompiler: WPEParityShaderCompiling {
        struct Unavailable: Error {}
        func compile(_: WPEParityShaderCompileRequest) async throws -> WPEParityCompiledStages {
            throw Unavailable()
        }
    }

    /// A real product plan/renderer with shader preparation unavailable at the input boundary. Copy, swap and
    /// allocation clears still have to operate correctly; no fabricated shader output or external corpus is used.
    private func commandRenderer(_ harness: Harness, directory: URL, authoredClear: Bool,
                                 width: Int = 4, height: Int = 4) async throws -> WPEParityFrameRenderer {
        func write(_ path: String, _ value: [String: Any]) throws {
            let url = directory.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: value).write(to: url)
        }
        let scene: [String: Any] = [
            "camera": ["eye": "0 0 1", "center": "0 0 0", "up": "0 1 0"],
            "general": ["orthogonalprojection": ["width": 4, "height": 4], "bloom": false],
            "objects": [
                ["id": 1, "name": "history", "image": "models/history.json", "size": "4 4", "origin": "2 2 0",
                 "effects": [["id": 7, "file": "effects/history.json", "visible": true]]],
                ["id": 900, "name": "group", "origin": "0 0 0", "scale": "1 1 1", "angles": "0 0 0"],
            ],
        ]
        try write("scene.json", scene)
        try write("models/history.json", ["material": "materials/unavailable.json"])
        var fbos: [[String: Any]] = ["A", "B", "O"].map {
            ["name": $0, "format": "rgba8888", "unique": true, "width": 4, "height": 4]
        }
        if authoredClear {
            fbos[0]["clear"] = "1 0 0 1"
            fbos[1]["clear"] = "0 1 0 1"
        }
        try write("effects/history.json", ["fbos": fbos, "passes": [
            ["command": "copy", "source": "A", "target": "O"],
            ["command": "swap", "source": "A", "target": "B"],
        ]])
        let document = try WPESceneDocumentParser.parse(data: JSONSerialization.data(withJSONObject: scene), userValues: [:])
        let assets = WPEParityProgramAssets(sceneDirectory: directory, assetRoots: [])
        let plan = try WPEParityFramePlan(document: document, assets: assets,
                                          settings: .init(bloom: false), width: width, height: height)
        XCTAssertFalse(plan.skipped.isEmpty, "unavailable draw preparation must be observed")
        let store = WPEParityShaderStore(compiler: UnavailableCompiler(),
                                         diskCache: WPEParityShaderDiskCache(cachesURL: directory.appending(path: "cache")))
        return try await WPEParityFrameRenderer(plan: plan, device: harness.device, queue: harness.queue,
                                                shaders: .init(store: store, compilerIdentity: "unavailable-test-input",
                                                               bindingABIVersion: 1), particleSeed: 1)
    }

    private func submit(_ renderer: WPEParityFrameRenderer) async throws {
        guard case let .committed(buffer) = try renderer.encodeFrame(elapsed: 1.0 / 60) else {
            return XCTFail("frame was skipped")
        }
        await buffer.completed()
        XCTAssertNil(buffer.error)
    }

    private func seedHistory(_ harness: Harness, a: MTLTexture, b: MTLTexture,
                             first: WPEClearColor, second: WPEClearColor) throws {
        let graph = try WPERenderGraphCompiler.compile(resources: [resource("A", .persistent), resource("B", .persistent)],
                                                       operations: [clear("A", first), clear("B", second)])
        try execute(harness, graph, external: ["A": a, "B": b], draws: [:])
    }

    private func resource(_ id: WPEResourceID, _ lifetime: WPEResourceLifetime,
                          mips: Int = 1, samples: Int = 1) -> WPELogicalResource {
        WPELogicalResource(id: id, width: Self.side, height: Self.side, mipCount: mips, sampleCount: samples,
                           lifetime: lifetime)
    }

    private func op(_ kind: WPERenderOperation.Kind) -> WPERenderOperation {
        WPERenderOperation(pass: "test", kind)
    }

    private func bind(_ id: WPEResourceID) -> WPERenderOperation {
        op(.setTargets(color: [WPETextureView(id, mips: 0 ..< 1)], depth: nil))
    }

    private func clear(_ id: WPEResourceID, _ color: WPEClearColor) -> WPERenderOperation {
        op(.clearColor(WPETextureView(id, mips: 0 ..< 1), color))
    }

    private func draw(sampling: WPEResourceID? = nil, readsDestination: Bool = false,
                      overwrites: Bool = false) -> WPERenderOperation {
        op(.draw(WPEDrawOperation(reads: [sampling].compactMap { $0.map { WPETextureView($0) } },
                                  readsDestination: readsDestination, overwritesTargets: overwrites)))
    }

    @discardableResult
    private func execute(_ harness: Harness, _ graph: WPECompiledRenderGraph, external: [WPEResourceID: MTLTexture],
                         draws: [Int: WPEParityDraw]) throws -> WPEParityGraphExecutor {
        let executor = try WPEParityGraphExecutor(graph: graph, device: harness.device, drawEncoder: harness.encoder,
                                                  arena: harness.arena, pixelFormats: Self.formats)
        let submission = try executor.encodeFrame(on: harness.queue, textures: external) { operation, _, _ in
            try [XCTUnwrap(draws[operation], "no draw for operation \(operation)")]
        }
        guard case let .committed(commandBuffer) = submission else {
            XCTFail("frame was skipped")
            return executor
        }
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return executor
    }

    // MARK: Fixture

    private func fixtureDirectory() throws -> URL {
        guard let url = TestScratch.externalFixtureURL(pathKey: "WPE_HLSL_CAPTURE_DIR") else {
            throw XCTSkip("Set LIVEWALLPAPER_EXTERNAL_FIXTURES=1 and WPE_HLSL_CAPTURE_DIR=<hlsl-capture directory>")
        }
        return url
    }

    private struct ManifestEntry: Decodable {
        let n: Int
        let name: String
    }

    private func loadProgram(_ name: String) throws -> WPEParityShaderArtifact {
        let directory = try fixtureDirectory()
        let manifest = try JSONDecoder().decode(
            [ManifestEntry].self, from: Data(contentsOf: directory.appending(path: "manifest.json"))
        )
        let vertex = try XCTUnwrap(manifest.first { $0.name == name + ".vert" }).n
        let fragment = try XCTUnwrap(manifest.first { $0.name == name + ".frag" }).n
        return try WPEParityShaderArtifact(
            vertex: loadStage(vertex, in: directory), fragment: loadStage(fragment, in: directory), geometry: nil
        )
    }

    private func loadStage(_ number: Int, in directory: URL) throws -> WPEParityShaderArtifact.Stage {
        let compiled = directory.appending(path: "compiled")
        let json = try Data(contentsOf: compiled.appending(path: "\(number).json"))
        let reflection = try JSONDecoder().decode(WPEStageReflection.self, from: Self.fillingVertexInputs(json))
        return try WPEParityShaderArtifact.Stage(
            metallib: Data(contentsOf: compiled.appending(path: "\(number).metallib")),
            reflection: reflection,
            functionName: reflection.entry
        )
    }

    /// The capture leaves `vertexInputs` empty while MSC's raw reflection lists them under `state.vertex_inputs`.
    private static func fillingVertexInputs(_ json: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              (object["vertexInputs"] as? [Any])?.isEmpty == true,
              let msc = object["mscReflection"] as? [String: Any],
              let state = msc["state"] as? [String: Any],
              let inputs = state["vertex_inputs"] as? [[String: Any]] else { return json }
        object["vertexInputs"] = inputs.map { input -> [String: Any] in
            ["name": input["name"] ?? "", "index": input["index"] ?? 0,
             "elementType": input["elementType"] ?? "", "columns": input["columnCount"] ?? 0]
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Metal helpers

    private static let texels: [UInt8] = (0 ..< side * side).flatMap { index -> [UInt8] in
        let (x, y) = (index % side, index / side)
        return [UInt8(x * 60 + 10), UInt8(y * 60 + 20), UInt8((x + y) * 30 + 5), UInt8(255 - (x * 4 + y) * 10)]
    }

    private func makeHarness() throws -> Harness {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let factory = WPEParityPipelineFactory(device: device)
        return try Harness(
            device: device,
            queue: XCTUnwrap(device.makeCommandQueue()),
            factory: factory,
            encoder: WPEParityDrawEncoder(factory: factory),
            arena: XCTUnwrap(WPEParityFrameArena(device: device, capacity: 64 * 1024))
        )
    }

    private func makeInput(_ harness: Harness) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Self.side, height: Self.side, mipmapped: false
        )
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(harness.device.makeTexture(descriptor: descriptor))
        texture.replace(region: MTLRegionMake2D(0, 0, Self.side, Self.side), mipmapLevel: 0,
                        withBytes: Self.texels, bytesPerRow: Self.side * 4)
        return texture
    }

    private func makeTexture(_ harness: Harness, mips: Int = 1) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: Self.side, height: Self.side, mipmapped: mips > 1
        )
        descriptor.mipmapLevelCount = mips
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        return try XCTUnwrap(harness.device.makeTexture(descriptor: descriptor))
    }

    private func makeDraw(_ harness: Harness, pipeline: WPEParityPipeline, vertices: [Float]) throws -> WPEParityDraw {
        let buffer = try XCTUnwrap(harness.device.makeBuffer(
            bytes: vertices, length: vertices.count * MemoryLayout<Float>.stride, options: .storageModeShared
        ))
        return WPEParityDraw(
            pipeline: pipeline,
            depthStencil: .wpe(depthTest: false, depthWrite: false),
            rasterizer: .wpe(flipFrontFace: false, cullingDisabled: true, slopeDepthBias: false, multisample: false),
            vertexBuffer: buffer,
            primitiveType: .triangleStrip,
            vertexCount: 4
        )
    }

    /// VS_INPUT: float3 POSITION0, float2 TEXCOORD0; D3D texcoord v=0 is the top row.
    private func passthroughDraw(
        _ harness: Harness, sampleCount: Int, input: MTLTexture,
        vertices: [Float] = [-1, 1, 0, 0, 0, -1, -1, 0, 0, 1, 1, 1, 0, 1, 0, 1, -1, 0, 1, 1]
    ) throws -> WPEParityDraw {
        let pipeline = try harness.factory.makePipeline(
            artifact: loadProgram("shaders/passthrough"), blend: .wpe(.normal, modifiers: .writeAlpha),
            colorPixelFormat: .rgba8Unorm, sampleCount: sampleCount
        )
        var draw = try makeDraw(harness, pipeline: pipeline, vertices: vertices)
        draw.textures = ["g_Texture0": input]
        draw.samplers = ["g_Texture0SamplerState": .wpe(filter: .point, address: .clamp)]
        return draw
    }

    /// VS_INPUT: float3 POSITION0, float4 COLOR0; PS writes vec4(g_Color, g_Alpha).
    private func flatDraw(_ harness: Harness, pipeline: WPEParityPipeline,
                          color: SIMD3<Float>, alpha: Float) throws -> WPEParityDraw {
        let corners: [(Float, Float)] = [(-1, 1), (-1, -1), (1, 1), (1, -1)]
        var draw = try makeDraw(harness, pipeline: pipeline, vertices: corners.flatMap { [$0.0, $0.1, 0, 1, 1, 1, 1] })
        let identity = WPEFloatMatrix(columns: (0 ..< 4).map { column in
            SIMD4<Float>((0 ..< 4).map { $0 == column ? 1 : 0 })
        })
        let constants: [String: WPECBufferValue] = [
            "g_ModelViewProjectionMatrix": .matrix(identity),
            "g_Color": .vector([color.x, color.y, color.z]),
            "g_Alpha": .float(alpha),
        ]
        draw.constants = [.vertex: constants, .fragment: constants]
        return draw
    }

    private func readBack(_ harness: Harness, _ texture: MTLTexture, level: Int = 0) throws -> [UInt8] {
        let side = max(1, Self.side >> level)
        let length = side * side * 4
        let buffer = try XCTUnwrap(harness.device.makeBuffer(length: length, options: .storageModeShared))
        let commandBuffer = try XCTUnwrap(harness.queue.makeCommandBuffer())
        let blit = try XCTUnwrap(commandBuffer.makeBlitCommandEncoder())
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: level, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: side, height: side, depth: 1), to: buffer,
                  destinationOffset: 0, destinationBytesPerRow: side * 4, destinationBytesPerImage: length)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)
        return Array(UnsafeRawBufferPointer(start: buffer.contents(), count: length))
    }

    private func assertPixels(_ output: [UInt8], equal expected: [UInt8], line: UInt = #line) {
        XCTAssertEqual(output.count, expected.count, line: line)
        for (index, pair) in zip(output, expected).enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(pair.0) - Int(pair.1)), 1, "byte \(index)", line: line)
        }
    }

    private func assertEvery(_ output: [UInt8], equals pixel: [UInt8], line: UInt = #line) {
        assertPixels(output, equal: (0 ..< output.count / 4).flatMap { _ in pixel }, line: line)
    }
}
#endif
