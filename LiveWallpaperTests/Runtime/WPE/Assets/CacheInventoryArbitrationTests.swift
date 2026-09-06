import Foundation
@testable import LiveWallpaper
import Testing

/// `WPECacheManagementView.refreshInventory` arbitrates overlapping inventory
/// walks: `wpeHistoryDidChange` fires on every apply and bookmark edit, so a
/// second scan routinely starts while the first is still walking the tree.
/// Only the newest may publish.
///
/// This is a **source-shape** guard, not a behavioural one, and the distinction
/// matters when reading a green run: the arbitration lives in `private` state on
/// a SwiftUI `View`, so there is no seam to drive two overlapping scans through.
/// `WPEStorageInventoryTests` calls `WPEStorageInventory.compute` directly and
/// therefore never reaches this code at all — deleting the guard left the whole
/// suite green, which is why this file exists.
///
/// It pins the *ordering*, because that is what breaks: bump, then capture, then
/// await, then compare before touching any published state. Asserting only that
/// the words appear would pass a version that captured before it bumped.
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

        // Every write to published state must sit behind the guard; a write above
        // it would leak a stale walk's result no matter what the guard returns.
        for mutation in ["inventory = scanned", "isLoadingInventory = false", "inventoryScan = nil"] {
            let write = try #require(body.range(of: mutation), "\(mutation) is gone — re-derive this guard")
            #expect(
                guardLine.lowerBound < write.lowerBound,
                "\(mutation) runs before the staleness check, so an older walk still publishes"
            )
        }
    }

    /// The brace-matched body that follows `declaration`'s opening `{`.
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
