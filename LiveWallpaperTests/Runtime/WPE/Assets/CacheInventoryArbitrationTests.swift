import Foundation
@testable import LiveWallpaper
import Testing

/// A **source-shape** guard, not a behavioural one: the arbitration lives in `private`
/// state on a SwiftUI `View`, so there is no seam to drive two overlapping scans through.
@Suite("Cache inventory scan arbitration")
struct CacheInventoryArbitrationTests {
    private static let path = "LiveWallpaper/Views/Settings/CacheView+Actions.swift"

    @Test("The newest inventory walk is the one that publishes")
    func staleWalkCannotPublish() throws {
        let source = try RepositoryRoot.source(Self.path)
        let body = try #require(
            Self.body(after: "private func refreshInventory() async {", in: source),
            "refreshInventory has been renamed or restructured — re-derive this guard"
        )

        let bump = try #require(body.range(of: "inventoryGeneration &+= 1"), "generation is never advanced")
        let capture = try #require(
            body.range(of: "let generation = inventoryGeneration"),
            "the starting generation is never captured"
        )
        let awaitScan = try #require(body.range(of: "await scan.value"), "the walk is no longer awaited")
        let guardLine = try #require(
            body.range(of: "guard generation == inventoryGeneration else { return }"),
            "a finished walk publishes without checking it is still the newest"
        )

        #expect(bump.lowerBound < capture.lowerBound, "captured a generation the bump had not reached yet")
        #expect(capture.lowerBound < awaitScan.lowerBound, "captured after the await, so it can never go stale")
        #expect(awaitScan.lowerBound < guardLine.lowerBound, "checked staleness before the walk could finish")

        for mutation in ["inventory = scanned", "isLoadingInventory = false", "inventoryScan = nil"] {
            let write = try #require(body.range(of: mutation), "\(mutation) is gone — re-derive this guard")
            #expect(
                guardLine.lowerBound < write.lowerBound,
                "\(mutation) runs before the staleness check, so an older walk still publishes"
            )
        }
    }

    @Test("A superseded refresh starts no scans once linked sources resolve")
    func supersededRefreshStartsNoScans() throws {
        let source = try RepositoryRoot.source(Self.path)
        let body = try #require(
            Self.body(after: "private func refreshInventory() async {", in: source),
            "refreshInventory has been renamed or restructured — re-derive this guard"
        )
        let resolve = try #require(body.range(of: "await StorageLinkedSources.current"), "linked sources are no longer awaited")
        let recheck = try #require(
            body.range(of: "guard generation == inventoryGeneration, !Task.isCancelled else { return }"),
            "a refresh superseded while resolving linked sources still starts its scans"
        )
        let firstScan = try #require(body.range(of: "Task {"), "the scans are no longer started as tasks")
        #expect(resolve.lowerBound < recheck.lowerBound, "rechecked before the await that can go stale")
        #expect(recheck.lowerBound < firstScan.lowerBound, "a scan starts before the recheck")
    }

    private static func body(after declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        var depth = 1
        var index = start.upperBound
        while index < source.endIndex {
            if source[index] == "{" {
                depth += 1
            }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[start.upperBound ..< index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
