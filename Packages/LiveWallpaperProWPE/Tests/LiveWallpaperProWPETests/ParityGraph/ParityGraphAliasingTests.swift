import LiveWallpaperProWPE
import Testing

private typealias S = ParityGraphStream

private func pooled(_ id: WPEResourceID) -> WPELogicalResource {
    WPELogicalResource(id: id, width: 64, height: 64, lifetime: .pooled)
}

struct ParityGraphAliasingTests {
    static let covering = WPEDrawCoverage(alwaysExecutes: true, fullscreenGeometry: true, mayDiscard: false,
                                          writesEverySample: true)

    @Test func emptyProofAllocatesAsToday() throws {
        let resources = [pooled("P"), pooled("C"), pooled("Q"), S.persistent("S"), S.persistent("X")]
        let operations = [
            S.bind("P"), S.draw(), S.copy("S", "C"), S.bind("Q"), S.clear("Q"), S.draw(readsDestination: true),
            S.bind("X"), S.draw(sampling: ["P", "C", "Q"]),
        ]
        let today = try S.compile(resources, operations)
        let empty = try WPERenderGraphCompiler.compile(resources: resources, operations: operations,
                                                       discardableHistory: [], coverage: WPERenderGraphCoverageProof())
        #expect(empty == today)
        S.expectPooledStorage(empty)

        let factsOnly = try WPERenderGraphCompiler.compile(
            resources: resources, operations: operations,
            coverage: WPERenderGraphCoverageProof(draws: [1: Self.covering])
        )
        #expect(factsOnly.storage == today.storage)
        #expect(factsOnly.allocationGroups == today.allocationGroups)
    }

    @Test func provenFullscreenOpaqueDrawFirstIsAliased() throws {
        let resources = [pooled("P"), S.persistent("X")]
        let operations = [S.bind("P"), S.draw(), S.bind("X"), S.draw(sampling: ["P"])]
        let graph = try compile(resources, operations, covering: [1])
        #expect(graph.storage["P"] == .aliased(group: 0))
        #expect(graph.encoders[0].attachment("P")?.load == .dontCare)

        let unproven = try compile(resources, operations)
        #expect(unproven.storage["P"] == .dedicated)
    }

    @Test func provenDrawFirstWithoutLaterReaderIsMemoryless() throws {
        let graph = try compile([pooled("P")], [S.bind("P"), S.draw(), S.draw(readsDestination: true)], covering: [1])
        #expect(graph.storage["P"] == .memoryless)
    }

    @Test func clearOrCopyFirstNeedsNoDrawFacts() throws {
        let graph = try compile([S.persistent("S"), pooled("C"), pooled("Q"), S.persistent("X")], [
            S.copy("S", "C"), S.bind("X"), S.draw(sampling: ["C"]),
            S.bind("Q"), S.clear("Q"), S.draw(readsDestination: true), S.bind("X"), S.draw(sampling: ["Q"]),
        ])
        #expect(graph.storage["C"] == .aliased(group: 0))
        #expect(graph.storage["Q"] == .aliased(group: 0))
    }

    enum Uncovered: CaseIterable {
        case partial, discard, depth, alphaMax, skippable, sampleMask
    }

    @Test(arguments: Uncovered.allCases) func uncoveredDrawFirstStaysDedicated(_ draw: Uncovered) throws {
        var facts = (executes: true, fullscreen: true, discards: false, everySample: true)
        var operation = S.draw()
        switch draw {
        case .partial: facts.fullscreen = false
        case .discard: facts.discards = true
        case .depth: operation = S.draw(depthTest: true)
        case .alphaMax: operation = S.draw(readsDestination: true)
        case .skippable: facts.executes = false
        case .sampleMask: facts.everySample = false
        }
        let coverage = WPEDrawCoverage(alwaysExecutes: facts.executes, fullscreenGeometry: facts.fullscreen,
                                       mayDiscard: facts.discards, writesEverySample: facts.everySample)
        let graph = try compile([pooled("P"), S.transient("D", format: "depth32float"), S.persistent("X")],
                                [S.bind("P", depth: "D"), S.clearDepth("D"), operation,
                                 S.bind("X"), S.draw(sampling: ["P"])],
                                facts: [2: coverage])
        #expect(graph.storage["P"] == .dedicated)
    }

    @Test(arguments: [
        pooled(WPEParitySceneResource.fullFrameBuffer), pooled("_rt_MipMappedFrameBuffer"),
        pooled(WPEParitySceneResource.layerCompositeA("7")),
        WPELogicalResource(id: "fbo", width: 64, height: 64, lifetime: .pooled, initialClear: S.black),
    ])
    func namedHistoriesStayDedicated(_ resource: WPELogicalResource) throws {
        let graph = try compile([S.persistent("S"), resource, S.persistent("X")], [
            S.copy("S", resource.id), S.bind("X"), S.draw(sampling: [resource.id]),
        ])
        #expect(graph.storage[resource.id] == .dedicated)
    }

    @Test func swapAndScopeMembersStayDedicated() throws {
        let scope = WPEResourceBindingScope.effect(objectID: "1", effectID: "2")
        let graph = try compile([S.persistent("S"), pooled("A"), pooled("B"), pooled("C"), S.persistent("X")], [
            S.copy("S", "A"), S.copy("S", "B"), S.copy("S", "C"),
            WPERenderOperation(pass: "swap", .swapResources(first: "A", second: "B")),
            WPERenderOperation(pass: "scope", .resourceScope(scope: scope, resources: ["C"])),
            S.bind("X"), S.draw(sampling: ["A", "B", "C"]),
        ])
        #expect(graph.storage["A"] == .dedicated)
        #expect(graph.storage["B"] == .dedicated)
        #expect(graph.storage["C"] == .dedicated)
    }

    @Test func pingPongCompositesStayDedicated() throws {
        let (first, second): (WPEResourceID, WPEResourceID) = ("sc.64.64.bc0", "sc.64.64.bc1")
        let resources = [S.persistent("S"), pooled(first), pooled(second), S.persistent("X")]
        // Two effects without bit4: fill the second composite, draw the first, read it back.
        let flipped = try compile(resources, [
            S.copy("S", second), S.bind(first), S.draw(sampling: [second]), S.bind("X"), S.draw(sampling: [first]),
        ], covering: [2], owners: [0: "L", 1: "L", 2: "L", 3: "L", 4: "L"])
        #expect(flipped.storage[first] == .dedicated)
        #expect(flipped.storage[second] == .dedicated)

        // bit4 with two effects: the pooled partner of layerCompositeA is drawn first.
        let layerA = WPEParitySceneResource.layerCompositeA("L")
        let bit4 = try compile(resources + [pooled(layerA)], [
            S.copy("S", layerA), S.bind(second), S.draw(sampling: [layerA]), S.bind("X"), S.draw(sampling: [second]),
        ], covering: [2], owners: [0: "L", 1: "L", 2: "L", 3: "L", 4: "L"])
        #expect(bit4.storage[second] == .dedicated)

        let single = try compile(resources, [S.copy("S", first), S.bind("X"), S.draw(sampling: [first])],
                                 owners: [0: "L", 1: "L", 2: "L"])
        #expect(single.storage[first] == .aliased(group: 0))
    }

    /// Two layers with effect FBOs, then the HDR bloom pyramid.
    @Test func sceneWithBloomSharesThreeHeaps() throws {
        let (bc0, bc1): (WPEResourceID, WPEResourceID) = ("sc.64.64.bc0", "sc.64.64.bc1")
        let (hcb1, hcb2, renderTarget): (WPEResourceID, WPEResourceID, WPEResourceID)
            = ("_rt_HalfCompoBuffer1", "_rt_HalfCompoBuffer2", "render_target")
        let layerA = WPEParitySceneResource.layerCompositeA("B")
        let ffb = WPEParitySceneResource.fullFrameBuffer
        let resources = [
            WPELogicalResource(id: "backbuffer", width: 64, height: 64, lifetime: .output),
            pooled(bc0), pooled(bc1), pooled(hcb1), pooled(hcb2), pooled(renderTarget), pooled(layerA), pooled(ffb),
            pooled("_rt_2FrameBuffer"), pooled("_rt_4FrameBuffer"), pooled("_rt_8FrameBuffer"),
        ]
        var operations: [WPERenderOperation] = []
        var owners: [Int: String] = [:]
        var covering: Set<Int> = []
        func emit(_ owner: String?, _ operation: WPERenderOperation, proven: Bool = false) {
            owners[operations.count] = owner
            if proven {
                covering.insert(operations.count)
            }
            operations.append(operation)
        }
        emit("A", S.copy("backbuffer", bc0))
        emit("A", S.bind(hcb1))
        emit("A", S.draw(sampling: [bc0]), proven: true)
        emit("A", S.bind(hcb2))
        emit("A", S.draw(sampling: [hcb1]), proven: true)
        emit("A", S.bind("backbuffer"))
        emit("A", S.draw(sampling: [hcb2], readsDestination: true))
        emit("B", S.copy("backbuffer", bc1))
        emit("B", S.bind(renderTarget))
        emit("B", S.draw(sampling: [bc1]), proven: true)
        emit("B", S.bind(layerA))
        emit("B", S.draw(sampling: [renderTarget]), proven: true)
        emit("B", S.bind("backbuffer"))
        emit("B", S.draw(sampling: [layerA], readsDestination: true))
        emit("A", S.bind("backbuffer"))
        emit("A", S.draw(sampling: [bc0], readsDestination: true))
        emit(nil, S.copy("backbuffer", ffb))
        for (target, source) in [("_rt_2FrameBuffer", ffb), ("_rt_4FrameBuffer", "_rt_2FrameBuffer"),
                                 ("_rt_8FrameBuffer", "_rt_4FrameBuffer")] as [(WPEResourceID, WPEResourceID)] {
            emit(nil, S.bind(target))
            emit(nil, S.draw(sampling: [source]), proven: true)
        }
        for (target, source) in [("_rt_4FrameBuffer", "_rt_8FrameBuffer"),
                                 ("_rt_2FrameBuffer", "_rt_4FrameBuffer")] as [(WPEResourceID, WPEResourceID)] {
            emit(nil, S.bind(target))
            emit(nil, S.draw(sampling: [source], readsDestination: true))
        }
        emit(nil, S.bind("backbuffer"))
        emit(nil, S.draw(sampling: [ffb, "_rt_2FrameBuffer"]))

        let graph = try compile(resources, operations, covering: covering, owners: owners)
        #expect(graph.allocationGroups == [
            [bc0, "_rt_2FrameBuffer"], [hcb1, bc1, "_rt_4FrameBuffer"], [hcb2, renderTarget, "_rt_8FrameBuffer"],
        ])
        #expect(graph.storage[layerA] == .dedicated)
        #expect(graph.storage[ffb] == .dedicated)
    }

    /// Every pooled resource is offered for discard; the compiler decides which ones it may take.
    private func compile(_ resources: [WPELogicalResource], _ operations: [WPERenderOperation],
                         covering: Set<Int> = [], facts: [Int: WPEDrawCoverage] = [:],
                         owners: [Int: String] = [:]) throws -> WPECompiledRenderGraph {
        let draws = facts.merging(covering.map { ($0, Self.covering) }) { explicit, _ in explicit }
        return try WPERenderGraphCompiler.compile(
            resources: resources, operations: operations,
            discardableHistory: Set(resources.filter { $0.lifetime == .pooled }.map(\.id)),
            coverage: WPERenderGraphCoverageProof(draws: draws, owners: owners)
        )
    }
}
