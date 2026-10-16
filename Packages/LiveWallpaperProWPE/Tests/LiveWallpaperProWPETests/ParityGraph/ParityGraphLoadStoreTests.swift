import LiveWallpaperProWPE
import Testing

private typealias S = ParityGraphStream

struct ParityGraphLoadStoreTests {
    private let clearBlack = WPELoadAction.clear(.color(S.black))

    @Test func readsObserveEntryHistoryWithoutReorderingTheWriter() throws {
        let graph = try S.compile([S.persistent("P"), S.persistent("X")],
                                  [S.bind("X"), S.draw(sampling: ["P"]), S.bind("P"), S.draw(overwrites: true)])
        #expect(graph.accesses[1].reads.map(\.subresource.resource) == ["P"])
        #expect(graph.accesses[1].reads.first?.revision == 0)
        #expect(graph.steps.map(\.operations) == [[1], [3]])
        #expect(S.depends(graph, 1, on: 0, "P"))
    }

    @Test func pooledWriterKeepsContentsForADifferentFutureGraph() throws {
        let history = WPELogicalResource(id: "P", width: 64, height: 64, lifetime: .pooled)
        let writer = try WPERenderGraphCompiler.compile(resources: [history],
                                                        operations: [S.bind("P"), S.draw(overwrites: true)])
        #expect(writer.storage["P"] == .dedicated)
        #expect(writer.encoders.first?.attachment("P")?.store == .store)
    }

    @Test func clearBeforeFirstDrawFoldsIntoLoadClear() throws {
        let resources = [S.persistent("A")]
        let folded = try S.compile(resources, [S.bind("A"), S.clear("A"), S.draw()])
        #expect(folded.steps.count == 1)
        #expect(try #require(folded.encoders[0].attachment("A")).load == clearBlack)

        let uncleared = try S.compile(resources, [S.bind("A"), S.draw()])
        #expect(try #require(uncleared.encoders[0].attachment("A")).load == .load)
    }

    @Test func clearBetweenDrawsIsNotMovedToEncoderEntry() throws {
        let resources = [S.persistent("A")]
        let between = try S.compile(resources, [S.bind("A"), S.draw(), S.clear("A"), S.draw()])
        #expect(between.encoders.count == 2)
        let first = try #require(between.encoders[0].attachment("A"))
        #expect(first.load == .load)
        // The clear overwrites everything the first draw produced.
        #expect(first.store == .dontCare)
        #expect(try #require(between.encoders[1].attachment("A")).load == clearBlack)

        let leading = try S.compile(resources, [S.bind("A"), S.clear("A"), S.draw(), S.draw()])
        #expect(leading.encoders.count == 1)
        #expect(try #require(leading.encoders[0].attachment("A")).load == clearBlack)
    }

    @Test func clearOnlyResultReadLaterStillExecutes() throws {
        let graph = try S.compile([S.transient("T"), S.persistent("X")],
                                  [S.clear("T"), S.bind("X"), S.draw(sampling: ["T"], overwrites: true)])
        #expect(graph.steps.count == 2)
        let cleared = try #require(graph.encoders[0].attachment("T"))
        #expect(cleared.load == clearBlack)
        #expect(cleared.store == .store)
    }

    @Test func persistentTargetStoresItsFinalVersion() throws {
        let operations = [S.bind("P"), S.draw(overwrites: true)]
        let persistent = try S.compile([S.persistent("P")], operations)
        #expect(try #require(persistent.encoders[0].attachment("P")).store == .store)

        let transient = try S.compile([S.transient("P")], operations)
        #expect(try #require(transient.encoders[0].attachment("P")).store == .dontCare)
    }

    @Test func persistentDepthTestedButNotWrittenKeepsPreviousFrame() throws {
        let resources = [S.persistent("P"), S.persistent("D", format: "depth32float")]
        let readOnly = try S.compile(resources, [S.bind("P", depth: "D"),
                                                 S.draw(overwrites: true, depthTest: true, depthWrite: false)])
        let depth = try #require(readOnly.encoders[0].attachment("D"))
        #expect(depth.load == .load)
        #expect(depth.store == .store)

        let written = try S.compile(resources, [S.bind("P", depth: "D"),
                                                S.draw(overwrites: true, depthTest: true, depthWrite: true)])
        #expect(try #require(written.encoders[0].attachment("D")).store == .store)
    }

    @Test func blendReadingDestinationLoadsPreviousContents() throws {
        func compile(_ last: WPERenderOperation) throws -> WPECompiledRenderGraph {
            try S.compile([S.transient("A"), S.transient("C")],
                          [S.bind("A"), S.draw(overwrites: true), S.copy("A", "C"), last])
        }
        let blended = try compile(S.draw(readsDestination: true, overwrites: true))
        #expect(blended.encoders.count == 2)
        #expect(try #require(blended.encoders[0].attachment("A")).store == .store)
        #expect(try #require(blended.encoders[1].attachment("A")).load == .load)
        #expect(blended.steps[2].reads.map(\.subresource) == [WPESubresource("A")])

        let opaque = try compile(S.draw(overwrites: true))
        #expect(try #require(opaque.encoders[1].attachment("A")).load == .dontCare)
        #expect(opaque.steps[2].reads.isEmpty)
    }

    @Test func intermediateWithoutLaterReaderDiscardsContents() throws {
        func compile(sampling: [WPEResourceID]) throws -> WPECompiledRenderGraph {
            try S.compile([S.transient("T"), S.persistent("X")],
                          [S.bind("T"), S.draw(overwrites: true), S.bind("X"), S.draw(sampling: sampling, overwrites: true)])
        }
        let unread = try compile(sampling: [])
        #expect(try #require(unread.encoders[0].attachment("T")).store == .dontCare)

        let read = try compile(sampling: ["T"])
        #expect(try #require(read.encoders[0].attachment("T")).store == .store)
        #expect(S.depends(read, 1, on: 0, "T"))
    }

    @Test func msaaWithoutLaterMultisampleReadResolvesOnly() throws {
        let resources = [S.transient("M", samples: 4), S.transient("R"), S.persistent("X")]
        let prefix = [S.bind("M"), S.clear("M"), S.draw(), S.resolve("M", "R"),
                      S.bind("X"), S.draw(sampling: ["R"], overwrites: true)]
        let resolveOnly = try S.compile(resources, prefix)
        #expect(resolveOnly.steps.count == 2)
        #expect(try #require(resolveOnly.encoders[0].attachment("M")).store == .multisampleResolve(into: "R"))
        #expect(S.depends(resolveOnly, 1, on: 0, "R"))

        let reread = try S.compile(resources, prefix + [S.bind("M"), S.draw(readsDestination: true)])
        #expect(try #require(reread.encoders[0].attachment("M")).store == .storeAndMultisampleResolve(into: "R"))
        #expect(try #require(reread.encoders[2].attachment("M")).load == .load)
    }

    @Test func resolveIsNotFoldedWhenItsDestinationIsTouchedFirst() throws {
        let resources = [S.transient("M", samples: 4), S.persistent("R")]
        let separated = try S.compile(resources, [S.bind("M"), S.draw(), S.bind("R"), S.draw(), S.resolve("M", "R")])
        #expect(separated.steps.count == 3)
        #expect(separated.steps[2].kind == .resolve(source: "M", destination: "R"))
        #expect(try #require(separated.encoders[0].attachment("M")).store == .store)
        #expect(S.depends(separated, 2, on: 0, "M"))
        #expect(S.depends(separated, 2, on: 1, "R"))

        let adjacent = try S.compile(resources, [S.bind("R"), S.draw(), S.bind("M"), S.draw(), S.resolve("M", "R")])
        #expect(adjacent.steps.count == 2)
        #expect(try #require(adjacent.encoders[1].attachment("M")).store == .multisampleResolve(into: "R"))
    }
}
