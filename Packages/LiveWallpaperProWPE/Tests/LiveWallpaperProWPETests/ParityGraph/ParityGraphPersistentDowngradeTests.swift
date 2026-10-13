import LiveWallpaperProWPE
import Testing

private typealias S = ParityGraphStream

/// Every stream runs twice: `.pooled` gets the expected storage, `.persistent` must stay dedicated.
struct ParityGraphPersistentDowngradeTests {
    static let lifetimes: [WPEResourceLifetime] = [.pooled, .persistent]

    @Test(arguments: lifetimes) func clearedFirstIsAliasedOrMemoryless(lifetime: WPEResourceLifetime) throws {
        let sampled = try compile([target("P", lifetime), S.persistent("X")], [
            S.bind("P"), S.clear("P"), S.draw(readsDestination: true), S.bind("X"), S.draw(sampling: ["P"]),
        ])
        expect(sampled, "P", lifetime, pooled: .aliased(group: 0))

        let attachmentOnly = try compile([target("P", lifetime)],
                                           [S.bind("P"), S.clear("P"), S.draw(readsDestination: true)])
        expect(attachmentOnly, "P", lifetime, pooled: .memoryless)
    }

    @Test(arguments: lifetimes) func disjointClearedTargetsShareAGroup(lifetime: WPEResourceLifetime) throws {
        let graph = try compile([target("P1", lifetime), target("P2", lifetime), S.persistent("X")], [
            S.bind("P1"), S.clear("P1"), S.draw(readsDestination: true), S.bind("X"), S.draw(sampling: ["P1"]),
            S.bind("P2"), S.clear("P2"), S.draw(readsDestination: true), S.bind("X"), S.draw(sampling: ["P2"]),
        ])
        #expect(graph.allocationGroups == (lifetime == .pooled ? [["P1", "P2"]] : []))
        expect(graph, "P1", lifetime, pooled: .aliased(group: 0))
        expect(graph, "P2", lifetime, pooled: .aliased(group: 0))
    }

    @Test(arguments: lifetimes) func opaqueDrawFirstIsAliased(lifetime: WPEResourceLifetime) throws {
        let graph = try compile([target("P", lifetime), S.persistent("X")], [
            S.bind("P"), S.draw(overwrites: true), S.bind("X"), S.draw(sampling: ["P"]),
        ])
        expect(graph, "P", lifetime, pooled: .aliased(group: 0))
    }

    @Test(arguments: lifetimes) func blendedDrawFirstStaysDedicated(lifetime: WPEResourceLifetime) throws {
        let graph = try compile([target("P", lifetime), S.persistent("X")], [
            S.bind("P"), S.draw(readsDestination: true), S.bind("X"), S.draw(sampling: ["P"]),
        ])
        #expect(graph.storage["P"] == .dedicated)
    }

    @Test(arguments: lifetimes) func sampledFirstStaysDedicated(lifetime: WPEResourceLifetime) throws {
        let graph = try compile([target("P", lifetime), S.persistent("X")], [
            S.bind("X"), S.draw(sampling: ["P"]), S.bind("P"), S.draw(overwrites: true),
            S.bind("X"), S.draw(sampling: ["P"]),
        ])
        #expect(graph.storage["P"] == .dedicated)
    }

    @Test(arguments: lifetimes) func partiallyLoadedMipStaysDedicated(lifetime: WPEResourceLifetime) throws {
        let bindMip1 = WPERenderOperation(pass: "bind", .setTargets(color: [WPETextureView("P", mips: 1 ..< 2)],
                                                                    depth: nil))
        let graph = try compile([target("P", lifetime, mips: 2), S.persistent("X")], [
            S.bind("P"), S.draw(overwrites: true), bindMip1, S.draw(), S.bind("X"), S.draw(sampling: ["P"]),
        ])
        #expect(graph.storage["P"] == .dedicated)
    }

    @Test(arguments: lifetimes) func fullCopyFirstIsAliased(lifetime: WPEResourceLifetime) throws {
        let graph = try compile([S.persistent("S"), target("P", lifetime), S.persistent("X")], [
            S.copy("S", "P"), S.bind("X"), S.draw(sampling: ["P"]),
        ])
        expect(graph, "P", lifetime, pooled: .aliased(group: 0))
    }

    @Test(arguments: lifetimes) func mipCopyCoversOnlyWithGeneratedMips(lifetime: WPEResourceLifetime) throws {
        let resources = [S.persistent("S"), target("P", lifetime, mips: 3), S.persistent("X")]
        let generated = try compile(resources, [
            S.copy("S", "P"), S.generateMips("P"), S.bind("X"), S.draw(sampling: ["P"]),
        ])
        expect(generated, "P", lifetime, pooled: .aliased(group: 0))

        let mipZeroOnly = try compile(resources, [S.copy("S", "P"), S.bind("X"), S.draw(sampling: ["P"])])
        #expect(mipZeroOnly.storage["P"] == .dedicated)
    }

    @Test(arguments: lifetimes) func finalStoreIsDontCareWhenNothingLaterReadsIt(lifetime: WPEResourceLifetime) throws {
        let graph = try compile([target("P", lifetime), S.persistent("X")], [
            S.bind("P"), S.draw(overwrites: true), S.bind("X"), S.draw(sampling: ["P"]),
            S.bind("P"), S.draw(readsDestination: true),
        ])
        expect(graph, "P", lifetime, pooled: .aliased(group: 0))
        #expect(graph.encoders[0].attachment("P")?.store == .store)
        #expect(graph.encoders[2].attachment("P")?.store == (lifetime == .pooled ? .dontCare : .store))
    }

    /// This fixture explicitly opts into graph-local scratch semantics. Product named RTs do not opt in.
    private func compile(_ resources: [WPELogicalResource], _ operations: [WPERenderOperation]) throws
        -> WPECompiledRenderGraph {
        try WPERenderGraphCompiler.compile(resources: resources, operations: operations,
                                           discardableHistory: Set(resources.filter { $0.lifetime == .pooled }.map(\.id)))
    }

    private func target(_ id: WPEResourceID, _ lifetime: WPEResourceLifetime, mips: Int = 1) -> WPELogicalResource {
        WPELogicalResource(id: id, width: 64, height: 64, mipCount: mips, lifetime: lifetime)
    }

    private func expect(_ graph: WPECompiledRenderGraph, _ id: WPEResourceID, _ lifetime: WPEResourceLifetime,
                        pooled: WPEResourceStorage, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(graph.storage[id] == (lifetime == .pooled ? pooled : .dedicated), "\(id)",
                sourceLocation: sourceLocation)
    }
}
