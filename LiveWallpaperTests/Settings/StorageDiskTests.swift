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

    @Test func calloutsSpreadEvenlyOverTheCardHeightInArcOrder() {
        let arcs: [(id: String, start: Double, end: Double)] = (0 ..< 5).map { index in
            let offset = Double(index) * 0.01
            return (id: "a\(index)", start: 0.70 + offset, end: 0.71 + offset)
        }
        let callouts = StorageCallout.layout(arcs: arcs, center: CGPoint(x: 100, y: 80), radius: 60, height: 160)
        let left = callouts.filter { !$0.isTrailing }
        #expect(left.map(\.id) == ["a4", "a3", "a2", "a1", "a0"])
        #expect(left.map(\.labelY) == [16, 48, 80, 112, 144])
    }

    @Test func calloutsTakeTheSideOfTheirArc() {
        let callouts = StorageCallout.layout(arcs: [(id: "right", start: 0, end: 0.5), (id: "left", start: 0.5, end: 1)],
                                             center: .zero, radius: 10, height: 100)
        #expect(callouts.first { $0.id == "right" }?.isTrailing == true)
        #expect(callouts.first { $0.id == "left" }?.isTrailing == false)
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

    @Test func homeIsAbbreviatedOnlyAtADirectoryBoundary() {
        #expect(StorageDiskItem.abbreviatingHome("/Users/ann/x", home: "/Users/ann") == "~/x")
        #expect(StorageDiskItem.abbreviatingHome("/Users/ann", home: "/Users/ann") == "~")
        #expect(StorageDiskItem.abbreviatingHome("/Users/anna/x", home: "/Users/ann") == "/Users/anna/x")
    }
}
#endif
