import LiveWallpaperProWPE
import Testing

private typealias S = ParityGraphStream

struct ParityGraphEncoderTests {
    @Test func adjacentDrawsToTheSameTargetsShareOneEncoder() throws {
        let graph = try S.compile([S.persistent("A"), S.persistent("B")],
                                  [S.bind("A"), S.draw(), S.bind("B"), S.bind("A"), S.draw()])
        #expect(graph.steps.count == 1)
        #expect(graph.steps[0].operations == [1, 4])
        #expect(graph.operations[4].pass == "draw")
    }

    @Test func copyBreaksTheEncoderAndOrdersBothSides() throws {
        let graph = try S.compile([S.persistent("A"), S.persistent("B")],
                                  [S.bind("A"), S.draw(), S.copy("A", "B"), S.draw()])
        #expect(graph.steps.map(\.operations) == [[1], [2], [3]])
        #expect(graph.steps[1].kind == .copy(source: "A", destination: "B"))
        #expect(S.depends(graph, 1, on: 0, "A", .readAfterWrite))
        #expect(S.depends(graph, 2, on: 1, "A", .writeAfterRead))
        #expect(S.depends(graph, 2, on: 0, "A", .writeAfterWrite))
    }

    @Test func generateMipsBreaksTheEncoderAndOrdersBothSides() throws {
        let graph = try S.compile([S.transient("A", mips: 3), S.persistent("X")],
                                  [S.bind("A"), S.draw(), S.generateMips("A"), S.draw(),
                                   S.bind("X"), S.draw(sampling: ["A"])])
        #expect(graph.steps.count == 4)
        #expect(graph.steps[1].kind == .generateMips("A"))
        #expect(S.depends(graph, 1, on: 0, "A", .readAfterWrite))
        #expect(S.depends(graph, 2, on: 1, "A", .writeAfterRead))
        #expect(S.depends(graph, 3, on: 1, "A", mip: 2, .readAfterWrite))
    }

    @Test func resolveBreaksTheEncoder() throws {
        let graph = try S.compile([S.transient("M", samples: 4), S.transient("R")],
                                  [S.bind("M"), S.draw(), S.resolve("M", "R"), S.draw(readsDestination: true)])
        #expect(graph.encoders.count == 2)
        #expect(graph.steps[0].operations == [1, 2])
        #expect(S.depends(graph, 1, on: 0, "M", .readAfterWrite))
    }

    @Test func drawsWithoutABoundaryStayMerged() throws {
        let graph = try S.compile([S.transient("M", samples: 4)],
                                  [S.bind("M"), S.draw(), S.draw(readsDestination: true)])
        #expect(graph.encoders.count == 1)
        #expect(graph.dependencies.isEmpty)
    }
}

struct ParityGraphAllocationTests {
    private func sequential(second: WPELogicalResource) throws -> WPECompiledRenderGraph {
        try S.compile([S.transient("T1"), second, S.persistent("X")], [
            S.bind("T1"), S.draw(overwrites: true), S.bind("X"), S.draw(sampling: ["T1"]),
            S.bind("T2"), S.draw(overwrites: true), S.bind("X"), S.draw(sampling: ["T2"]),
        ])
    }

    @Test func disjointTransientsShareOneGroup() throws {
        let graph = try sequential(second: S.transient("T2"))
        #expect(graph.lifetimes["T1"] == 0 ... 1)
        #expect(graph.lifetimes["T2"] == 2 ... 3)
        #expect(graph.allocationGroups == [["T1", "T2"]])
        #expect(graph.storage["T1"] == .aliased(group: 0))
        #expect(graph.storage["T2"] == .aliased(group: 0))
    }

    @Test func overlappingTransientsGetSeparateGroups() throws {
        let graph = try S.compile([S.transient("T1"), S.transient("T2"), S.persistent("X")], [
            S.bind("T1"), S.draw(overwrites: true), S.bind("T2"), S.draw(overwrites: true),
            S.bind("X"), S.draw(sampling: ["T1", "T2"]),
        ])
        #expect(graph.allocationGroups == [["T1"], ["T2"]])
    }

    @Test func persistentResourcesNeverJoinAGroup() throws {
        let graph = try sequential(second: S.persistent("T2"))
        #expect(graph.allocationGroups == [["T1"]])
        #expect(graph.storage["T2"] == .dedicated)
        #expect(graph.storage["X"] == .dedicated)
    }

    @Test func attachmentOnlyDepthIsMemoryless() throws {
        let resources = [S.persistent("C"), S.transient("D", format: "depth32float"), S.persistent("X")]
        let prefix = [S.bind("C", depth: "D"), S.clearDepth("D"), S.draw(depthTest: true, depthWrite: true)]
        let attachmentOnly = try S.compile(resources, prefix)
        let depth = try #require(attachmentOnly.encoders[0].depthAttachment)
        #expect(depth.load == .clear(.depth(0)))
        #expect(depth.store == .dontCare)
        #expect(attachmentOnly.storage["D"] == .memoryless)
        #expect(attachmentOnly.allocationGroups.isEmpty)

        let sampled = try S.compile(resources, prefix + [S.bind("X"), S.draw(sampling: ["D"])])
        #expect(try #require(sampled.encoders[0].depthAttachment).store == .store)
        #expect(sampled.storage["D"] == .aliased(group: 0))
    }

    @Test func msaaSourceResolvedAtEncoderExitIsMemoryless() throws {
        let resources = [S.transient("M", samples: 4), S.transient("R"), S.persistent("X")]
        let prefix = [S.bind("M"), S.clear("M"), S.draw(), S.resolve("M", "R"),
                      S.bind("X"), S.draw(sampling: ["R"])]
        #expect(try S.compile(resources, prefix).storage["M"] == .memoryless)

        let reread = try S.compile(resources, prefix + [S.bind("M"), S.draw(readsDestination: true)])
        #expect(reread.storage["M"] != .memoryless)
    }
}
