#if !LITE_BUILD
import Foundation
import Testing
@testable import LiveWallpaper

@MainActor
@Suite("Workshop dependency fetch traversal")
struct WorkshopDependencyResolverTests {

    /// Fake "ID → its dependency IDs" graph; records the fetch order so a cycle
    /// shows up as a repeat visit instead of a hang.
    private final class FakeGraph {
        let edges: [String: [String]]
        let failing: Set<String>
        private(set) var visits: [String] = []

        init(edges: [String: [String]], failing: Set<String> = []) {
            self.edges = edges
            self.failing = failing
        }

        func fetch(_ id: String) -> WorkshopDependencyFetchOutcome {
            visits.append(id)
            if failing.contains(id) {
                return WorkshopDependencyFetchOutcome(failureReason: "boom \(id)")
            }
            return WorkshopDependencyFetchOutcome(dependencyIDs: edges[id] ?? [])
        }
    }

    @Test("a dependency cycle visits each item once instead of expanding forever")
    func cycleTerminates() async {
        let graph = FakeGraph(edges: ["B": ["A", "C"], "C": ["B", "A"]])
        let report = await WorkshopDependencyResolver.resolve(
            rootWorkshopID: "A",
            missingDependencyIDs: ["B"],
            fetch: { graph.fetch($0) }
        )

        #expect(graph.visits == ["B", "C"])
        #expect(report.fetched == ["B", "C"])
        #expect(report.isFullyResolved)
    }

    @Test("items past the depth limit are skipped and reported as truncated")
    func depthLimitTruncates() async {
        let graph = FakeGraph(edges: ["B": ["C"], "C": ["D"], "D": ["E"]])
        let report = await WorkshopDependencyResolver.resolve(
            rootWorkshopID: "A",
            missingDependencyIDs: ["B"],
            limits: WorkshopDependencyLimits(maxDepth: 2),
            fetch: { graph.fetch($0) }
        )

        #expect(graph.visits == ["B", "C"])
        #expect(report.truncations.contains(.depth))
        #expect(report.skipped == ["D"])
        #expect(!report.isFullyResolved)
    }

    @Test("the item-count limit stops the traversal and reports truncation")
    func itemCountLimitTruncates() async {
        let graph = FakeGraph(edges: ["B": ["C"], "C": ["D"], "D": []])
        let report = await WorkshopDependencyResolver.resolve(
            rootWorkshopID: "A",
            missingDependencyIDs: ["B"],
            limits: WorkshopDependencyLimits(maxItems: 2),
            fetch: { graph.fetch($0) }
        )

        #expect(graph.visits == ["B", "C"])
        #expect(report.truncations.contains(.itemCount))
        #expect(report.skipped == ["D"])
    }

    @Test("one failing dependency is reported without stopping its siblings or touching the root")
    func failureIsIsolated() async {
        let graph = FakeGraph(edges: ["B": [], "C": []], failing: ["B"])
        let report = await WorkshopDependencyResolver.resolve(
            rootWorkshopID: "A",
            missingDependencyIDs: ["B", "C"],
            fetch: { graph.fetch($0) }
        )

        #expect(graph.visits == ["B", "C"])
        #expect(!graph.visits.contains("A"))
        #expect(report.fetched == ["C"])
        #expect(report.failures == [WorkshopDependencyFailure(workshopID: "B", reason: "boom B")])
        #expect(report.truncations.isEmpty)
    }
}
#endif
