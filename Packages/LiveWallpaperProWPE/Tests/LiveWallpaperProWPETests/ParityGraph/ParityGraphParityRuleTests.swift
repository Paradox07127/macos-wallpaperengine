import LiveWallpaperProWPE
import Testing

private typealias S = ParityGraphStream

struct ParityGraphFrameEntryTests {
    @Test func persistentPartialFirstDrawLoadsPreviousFrame() throws {
        let operations = [S.bind("P"), S.draw()]
        let persistent = try S.compile([S.persistent("P")], operations)
        #expect(try #require(persistent.encoders[0].attachment("P")).load == .load)

        let transient = try S.compile([S.transient("P")], operations)
        #expect(try #require(transient.encoders[0].attachment("P")).load == .dontCare)
    }

    @Test func persistentFirstUseThatCoversTheViewSkipsTheLoad() throws {
        let cleared = try S.compile([S.persistent("P")], [S.bind("P"), S.clear("P"), S.draw()])
        #expect(try #require(cleared.encoders[0].attachment("P")).load == .clear(.color(S.black)))

        let overwritten = try S.compile([S.persistent("P")], [S.bind("P"), S.draw(overwrites: true)])
        #expect(try #require(overwritten.encoders[0].attachment("P")).load == .dontCare)

        let blended = try S.compile([S.persistent("P")], [S.bind("P"), S.draw(readsDestination: true, overwrites: true)])
        #expect(try #require(blended.encoders[0].attachment("P")).load == .load)
    }

    @Test func persistentFirstUseAfterBeingSampledStillLoads() throws {
        let graph = try S.compile([S.persistent("P"), S.persistent("X")],
                                  [S.bind("X"), S.draw(sampling: ["P"], overwrites: true), S.bind("P"), S.draw()])
        #expect(try #require(graph.encoders[1].attachment("P")).load == .load)
        #expect(try #require(graph.encoders[1].attachment("P")).store == .store)
    }

    @Test func depthClearValueComesFromTheOperation() throws {
        func compile(_ value: Double) throws -> WPELoadAction? {
            let resources = [S.persistent("C"), S.persistent("D", format: "depth32float")]
            let graph = try S.compile(resources, [
                S.bind("C", depth: "D"),
                WPERenderOperation(pass: "clearDepth", .clearDepth(WPETextureView("D"), depth: value)),
                S.draw(depthTest: true, depthWrite: true),
            ])
            return graph.encoders.first?.depthAttachment?.load
        }
        #expect(try compile(0) == .clear(.depth(0)))
        #expect(try compile(0.25) == .clear(.depth(0.25)))
    }
}

struct ParityGraphMemorylessTests {
    private let resources = [S.transient("T"), S.persistent("X")]

    @Test func transientWithoutClearOrOverwriteIsNotMemoryless() throws {
        let partial = try S.compile(resources, [S.bind("T"), S.draw()])
        #expect(try #require(partial.encoders[0].attachment("T")).store == .dontCare)
        #expect(partial.storage["T"] == .aliased(group: 0))

        let cleared = try S.compile(resources, [S.bind("T"), S.clear("T"), S.draw()])
        #expect(cleared.storage["T"] == .memoryless)

        let overwritten = try S.compile(resources, [S.bind("T"), S.draw(overwrites: true)])
        #expect(overwritten.storage["T"] == .memoryless)
    }

    @Test func blendOverUnclearedTransientIsNotMemoryless() throws {
        let blended = try S.compile(resources, [S.bind("T"), S.draw(readsDestination: true, overwrites: true)])
        #expect(blended.storage["T"] == .aliased(group: 0))
    }

    @Test func depthSharedByTwoEncodersIsNotMemoryless() throws {
        let resources = [S.persistent("A"), S.persistent("B"), S.transient("D", format: "depth32float")]
        let shared = try S.compile(resources, [
            S.bind("A", depth: "D"), S.clearDepth("D"), S.draw(depthTest: true, depthWrite: true),
            S.bind("B", depth: "D"), S.draw(depthTest: true, depthWrite: true),
        ])
        #expect(shared.encoders.count == 2)
        #expect(try #require(shared.encoders[0].depthAttachment).store == .store)
        #expect(try #require(shared.encoders[1].depthAttachment).load == .load)
        #expect(shared.storage["D"] == .aliased(group: 0))

        let single = try S.compile(resources, [
            S.bind("A", depth: "D"), S.clearDepth("D"), S.draw(depthTest: true, depthWrite: true),
        ])
        #expect(single.storage["D"] == .memoryless)
    }

    @Test func persistentTargetIsNeverMemoryless() throws {
        let persistent = try S.compile([S.persistent("T")], [S.bind("T"), S.clear("T"), S.draw()])
        #expect(persistent.storage["T"] == .dedicated)

        let transient = try S.compile([S.transient("T")], [S.bind("T"), S.clear("T"), S.draw()])
        #expect(transient.storage["T"] == .memoryless)
    }
}

struct ParityGraphHeapLayoutTests {
    private let requirements: [WPEResourceID: (size: Int, alignment: Int)] = [
        "T1": (1000, 256), "T2": (3000, 512), "T3": (700, 1024),
    ]

    private func layout(_ graph: WPECompiledRenderGraph) -> WPEHeapLayout {
        graph.heapLayout { requirements[$0.id] ?? (0, 1) }
    }

    @Test func disjointTransientsShareAnOffsetSizedByTheLargestMember() throws {
        let graph = try S.compile([S.transient("T1"), S.transient("T2"), S.persistent("X")], [
            S.bind("T1"), S.draw(overwrites: true), S.bind("X"), S.draw(sampling: ["T1"]),
            S.bind("T2"), S.draw(overwrites: true), S.bind("X"), S.draw(sampling: ["T2"]),
        ])
        let heap = layout(graph)
        #expect(heap.offsets == ["T1": 0, "T2": 0])
        #expect(heap.size == 3000)
    }

    @Test func overlappingTransientsGetSeparateAlignedOffsets() throws {
        let graph = try S.compile([S.transient("T2"), S.transient("T3"), S.persistent("X")], [
            S.bind("T2"), S.draw(overwrites: true), S.bind("T3"), S.draw(overwrites: true),
            S.bind("X"), S.draw(sampling: ["T2", "T3"]),
        ])
        let heap = layout(graph)
        #expect(heap.offsets == ["T2": 0, "T3": 3072])
        #expect(heap.size == 3772)
    }

    @Test func onlyAliasedResourcesArePlacedInTheHeap() throws {
        let imported = WPELogicalResource(id: "I", width: 64, height: 64, lifetime: .imported)
        let graph = try S.compile([S.transient("T1"), S.transient("M"), S.persistent("X"), imported], [
            S.bind("T1"), S.draw(sampling: ["I"], overwrites: true),
            S.bind("M"), S.clear("M"), S.draw(),
            S.bind("X"), S.draw(sampling: ["T1"]),
        ])
        #expect(graph.storage["M"] == .memoryless)
        #expect(graph.storage["I"] == .external)
        #expect(graph.storage["X"] == .dedicated)
        #expect(layout(graph).offsets == ["T1": 0])
    }
}

struct ParityGraphMipCopyTests {
    @Test func singleMipSourceCopiesIntoMipZeroOfAMipmappedDestination() throws {
        let resources = [S.persistent("A"), S.transient("M", mips: 4)]
        let graph = try S.compile(resources, [S.bind("A"), S.clear("A"), S.copy("A", "M"), S.generateMips("M")])
        #expect(S.depends(graph, 2, on: 1, "M", mip: 0))
        #expect(!graph.dependencies.contains { $0.producer == 1 && $0.subresource.mip > 0 })
    }

    @Test func unequalMipCountsAboveOneAreRejected() {
        let resources = [S.transient("A", mips: 2), S.transient("M", mips: 4)]
        #expect(throws: WPEParityGraphError.incompatibleCopy(operation: 0)) {
            try S.compile(resources, [S.copy("A", "M")])
        }
        #expect(throws: WPEParityGraphError.incompatibleCopy(operation: 0)) {
            try S.compile([S.transient("M", mips: 4), S.transient("A")], [S.copy("M", "A")])
        }
    }
}

struct ParityGraphResolveCompatibilityTests {
    @Test func incompatibleFormatsAndMultisampleMipChainsAreRejected() {
        for (source, destination) in [
            (S.transient("M", samples: 4), S.persistent("R", format: "rgba16float")),
            (S.transient("M", mips: 2, samples: 4), S.persistent("R")),
        ] {
            #expect(throws: WPEParityGraphError.invalidResolve(operation: 0)) {
                try S.compile([source, destination], [S.resolve("M", "R")])
            }
        }
    }

    @Test func resolvingToMipZeroKeepsTheRemainingDestinationMipsIndependent() throws {
        let graph = try S.compile([S.transient("M", samples: 4), S.transient("R", mips: 4)], [
            S.bind("M"), S.clear("M"), S.draw(), S.resolve("M", "R"), S.generateMips("R"),
        ])
        let resolveWrites = graph.accesses[3].writes.map(\.subresource)
        #expect(resolveWrites == [WPESubresource("R", mip: 0)])
        #expect(graph.accesses[4].reads.map(\.subresource) == resolveWrites)
        #expect(graph.accesses[4].writes.map(\.subresource) == (1 ..< 4).map { WPESubresource("R", mip: $0) })
    }
}
