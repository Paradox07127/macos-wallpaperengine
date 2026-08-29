#if !LITE_BUILD
import Foundation

/// Bounded breadth-first traversal of "this Workshop item needs those Workshop
/// items". Pure policy: the caller supplies the fetch, this decides what to
/// visit, when to stop, and what to tell the user was left undone.
enum WorkshopDependencyResolver {
    @MainActor
    static func resolve(
        rootWorkshopID: String,
        missingDependencyIDs: [String],
        limits: WorkshopDependencyLimits = WorkshopDependencyLimits(),
        isCancelled: () -> Bool = { Task.isCancelled },
        fetch: (String) async -> WorkshopDependencyFetchOutcome
    ) async -> WorkshopDependencyReport {
        var report = WorkshopDependencyReport()
        // Seeding with the root is what makes a cycle (A → B → A) terminate.
        var visited: Set<String> = [rootWorkshopID]
        var queue: [(id: String, depth: Int)] = []
        for id in missingDependencyIDs where visited.insert(id).inserted {
            queue.append((id, 1))
        }
        while !queue.isEmpty {
            if isCancelled() {
                report.wasCancelled = true
                report.skipped.append(contentsOf: queue.map(\.id))
                break
            }
            let next = queue.removeFirst()
            if next.depth > limits.maxDepth {
                report.truncations.insert(.depth)
                report.skipped.append(next.id)
                continue
            }
            if report.fetched.count + report.failures.count >= limits.maxItems {
                report.truncations.insert(.itemCount)
                report.skipped.append(next.id)
                continue
            }
            let outcome = await fetch(next.id)
            if let reason = outcome.failureReason {
                report.failures.append(WorkshopDependencyFailure(workshopID: next.id, reason: reason))
                continue
            }
            report.fetched.append(next.id)
            for id in outcome.dependencyIDs where visited.insert(id).inserted {
                queue.append((id, next.depth + 1))
            }
        }
        return report
    }
}

struct WorkshopDependencyLimits: Equatable, Sendable {
    /// Authored chains in the Workshop are one level deep in practice (scene →
    /// asset pack); 3 leaves room for a pack that pulls a pack without walking
    /// an unbounded graph.
    var maxDepth: Int = 3
    /// Every item is a separate SteamCMD invocation on the connector's serial
    /// queue, so wall-clock grows linearly with this number.
    var maxItems: Int = 12
    // Deliberately no byte budget: SteamCMD's progress lines usually omit byte
    // counts, so a size check read 0 and never fired. Depth and count are the
    // real bounds; a budget that cannot see sizes only looks like one.
}

enum WorkshopDependencyTruncation: Hashable, Sendable {
    case depth
    case itemCount
}

struct WorkshopDependencyFailure: Hashable, Sendable {
    let workshopID: String
    let reason: String
}

struct WorkshopDependencyFetchOutcome: Sendable {
    var dependencyIDs: [String] = []
    /// Non-nil marks the fetch as failed; traversal continues with the rest.
    var failureReason: String?
}

struct WorkshopDependencyReport: Equatable, Sendable {
    var fetched: [String] = []
    var failures: [WorkshopDependencyFailure] = []
    var truncations: Set<WorkshopDependencyTruncation> = []
    /// Wanted, but never attempted because a limit was already reached.
    var skipped: [String] = []
    var wasCancelled = false

    var isFullyResolved: Bool {
        failures.isEmpty && truncations.isEmpty && skipped.isEmpty && !wasCancelled
    }
}
#endif
