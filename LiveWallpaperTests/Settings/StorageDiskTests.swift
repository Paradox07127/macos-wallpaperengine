#if !LITE_BUILD
@testable import LiveWallpaper
import SwiftUI
import Testing

@Suite("Storage disk proportions")
struct StorageDiskTests {
    private func item(_ id: String, _ bytes: UInt64) -> StorageDiskItem {
        StorageDiskItem(id: id, title: "Storage", bytes: bytes, color: .accentColor)
    }

    @Test func proportionsIncludeTinyCategoriesWithoutInflatingThem() {
        let slices = StorageDiskSlice.partition([item("large", 999_999), item("tiny", 1), item("empty", 0)])
        #expect(slices.map(\.id) == ["large", "tiny"])
        #expect(slices[0].start == 0)
        #expect(abs(slices[0].end - 0.999999) < 0.000000001)
        #expect(slices[1].start == slices[0].end)
        #expect(abs(slices[1].end - 1) < 0.000000001)
    }

    @Test func emptyAndZeroScansHaveNoInvalidAngles() {
        #expect(StorageDiskSlice.partition([]).isEmpty)
        #expect(StorageDiskSlice.partition([item("empty", 0)]).isEmpty)
    }

    @Test func legendListsEveryNonZeroItemLargestFirstWithOneArcEach() {
        let spec = StorageRingSpec(id: "ring", title: "Storage", items: [
            item("a", 30), item("zero", 0), item("b", 700), item("c", 5),
            item("d", 90), item("e", 1), item("f", 400), item("g", 12),
        ])
        let expected = ["b", "f", "d", "a", "g", "c", "e"]
        #expect(spec.legend.map(\.id) == expected)
        #expect(StorageDiskSlice.partition(spec.legend).map(\.id) == expected)
    }

    @Test func locationRowsHideMeasuredEmptyLocationsButKeepUnknownSizes() {
        let rows: [(String, UInt64, AppStorageMeasurement.Status)] = [
            ("full", 10, .complete), ("empty", 0, .complete), ("absent", 0, .missing),
            ("failed", 0, .unavailable), ("partial", 0, .partial),
        ]
        let items = rows.map { StorageDiskItem(id: $0.0, title: "Storage", bytes: $0.1, color: .accentColor, status: $0.2) }
        #expect(StorageDiskItem.listed(items).map(\.id) == ["full", "failed", "partial"])
    }

    @Test func veryLargeTotalsDoNotOverflowThePartition() {
        let slices = StorageDiskSlice.partition([item("first", .max), item("second", .max)])
        #expect(slices.count == 2)
        #expect(slices[0].end == 0.5)
        #expect(slices[1].start == 0.5)
        #expect(slices[1].end == 1)
    }

    @Test func anyIncompleteWallpaperComponentMakesTheSummaryPartial() {
        func summary(_ incomplete: Bool, _ statuses: [AppStorageMeasurement.Status], _ unresolved: Int) -> AppStorageMeasurement.Status {
            StorageDiskItem.summaryStatus(inventoryIncomplete: incomplete, componentStatuses: statuses, unresolvedSources: unresolved)
        }
        #expect(summary(false, [.complete, .missing], 0) == .complete)
        #expect(summary(true, [.complete], 0) == .partial)
        #expect(summary(false, [.complete, .partial], 0) == .partial)
        #expect(summary(false, [.unavailable], 0) == .partial)
        #expect(summary(false, [.complete], 1) == .partial)
    }

    @Test func ringTotalIsPartialWheneverARowIs() {
        func ring(_ statuses: [AppStorageMeasurement.Status]) -> StorageRingSpec {
            let items = statuses.enumerated().map { index, status in
                StorageDiskItem(id: "\(index)", title: "Storage", bytes: 1, color: .accentColor, status: status)
            }
            return StorageRingSpec(id: "ring", title: "Storage", items: items)
        }
        #expect(!ring([.complete, .missing]).isTotalPartial)
        #expect(ring([.complete, .partial]).isTotalPartial)
        #expect(ring([.complete, .unavailable]).isTotalPartial)
    }

    @Test func homeIsAbbreviatedOnlyAtADirectoryBoundary() {
        #expect(StorageDiskItem.abbreviatingHome("/Users/ann/x", home: "/Users/ann") == "~/x")
        #expect(StorageDiskItem.abbreviatingHome("/Users/ann", home: "/Users/ann") == "~")
        #expect(StorageDiskItem.abbreviatingHome("/Users/anna/x", home: "/Users/ann") == "/Users/anna/x")
    }
}
#endif
