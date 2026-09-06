import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

/// The settings inspector's copy of the board. It used to draw nothing but
/// widget names, so a layout could not be judged before it went on the desktop;
/// it now draws the real cards from frozen data, and must still not start a
/// single sampler to do it.
@Suite("Monitor inspector board preview")
@MainActor
struct BoardPreviewContentTests {
    private func delivered(
        at reference: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> (snapshot: MonitorSnapshot, history: MonitorHistorySnapshot) {
        let fixture = MonitorBoardPreviewFixture.sample(at: reference)
        return (fixture.snapshot, fixture.history)
    }

    @Test("the default mode draws real widgets from the last delivered reading")
    func defaultModeDrawsWidgets() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let preview = MonitorBoardPreview.resolve(mode: .snapshot, latest: delivered(at: reference))
        #expect(preview.tile == .widget)
        #expect(preview.capturedAt == reference)
        #expect(!preview.history.sampleTimes.isEmpty)
    }

    @Test("a preview with no reading shows an empty state rather than fabricated zeroes")
    func noReadingShowsEmptyState() {
        let preview = MonitorBoardPreview.resolve(mode: .snapshot, latest: nil)
        #expect(preview.tile == .empty)
        #expect(preview.snapshot == nil)
        #expect(preview.capturedAt == nil)
        #expect(preview.history == MonitorHistorySnapshot())
    }

    @Test("names mode stays available for a canvas too small to read")
    func namesModeRemainsAvailable() {
        let preview = MonitorBoardPreview.resolve(mode: .names, latest: delivered())
        #expect(preview.tile == .names)
        #expect(MonitorBoardPreviewMode.allCases.count == 3)
    }

    @Test("sample data fills all 27 card kind and size combinations")
    func sampleDataCoversEveryCard() throws {
        let preview = MonitorBoardPreview.resolve(mode: .sample, latest: nil)
        let snapshot = try #require(preview.snapshot)
        var combinations = 0
        var covered: Set<MonitorWidgetKind> = []
        for kind in MonitorWidgetKind.allCases {
            for size in kind.allowedSizes {
                combinations += 1
                let context = MonitorWidgetContext(
                    snapshot: snapshot,
                    history: preview.history,
                    placement: MonitorWidgetPlacement(kind: kind, size: size),
                    isEditing: false,
                    reduceMotion: true,
                    now: preview.chartReference(fallback: Date())
                )
                #expect(context.readingsNotice == nil, "\(kind) \(size) had nothing to draw")
                covered.insert(kind)
            }
        }
        // A literal on purpose: deriving it from allowedSizes only restates how
        // combinations was counted, so it stays green through any change to the
        // size table. Adding a widget must land here and confirm the fixture
        // feeds the new card.
        #expect(combinations == 27)
        #expect(MonitorWidgetKind.allCases.allSatisfy { covered.contains($0) })
    }

    /// The chart window's reference is the frozen instant, so a preview left
    /// open does not slide its own data off the left edge of the axis.
    @Test("charts read the frozen instant, not the drawing clock")
    func chartsUseTheFrozenReference() {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let preview = MonitorBoardPreview.resolve(mode: .snapshot, latest: delivered(at: reference))
        let muchLater = reference.addingTimeInterval(3600)
        #expect(preview.chartReference(fallback: muchLater) == reference)

        let window = preview.history.chartWindow(
            reference: preview.chartReference(fallback: muchLater), seconds: 60
        )
        let points = preview.history.points(preview.history.cpuTotal, in: window)
        #expect(!points.isEmpty)
        #expect(points.compactMap(\.value).count == points.count)
    }

    @Test("a later reading does not change what an already captured preview draws")
    func capturedPreviewIsFrozen() {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let captured = MonitorBoardPreview.resolve(mode: .snapshot, latest: delivered(at: first))
        let later = MonitorBoardPreview.resolve(
            mode: .snapshot, latest: delivered(at: first.addingTimeInterval(600))
        )
        #expect(captured.capturedAt == first)
        #expect(captured != later)
    }

    /// The whole point of reading frozen data: turning the preview on must not
    /// be a way to start a source the user never authorized.
    @Test("reading the preview's data leases no runtime and starts no source")
    func previewReadStartsNothing() async {
        let runtime = Runtime()
        let controller = OverlayController(runtime: runtime)
        let generationBefore = runtime.broker.currentGeneration

        #expect(controller.lastDeliveredData == nil)

        #expect(await runtime.debugActiveLeaseCount == 0)
        #expect(await runtime.debugActiveSourceCount == 0)
        #expect(await runtime.debugActiveOptions == nil)
        #expect(runtime.broker.currentGeneration == generationBefore)
    }

    @Test("an inspector host draws what its preview resolves to")
    func hostDrawsResolvedPreview() {
        let configuration = MonitorBoardConfiguration(
            widgets: [MonitorWidgetPlacement(kind: .cpu, size: .medium)],
            refreshHz: 1,
            mouseInteractionEnabled: false
        )
        let live = HostView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        #expect(live.previewTile == nil, "the desktop board has no preview")

        let host = HostView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration,
            preview: MonitorBoardPreview.resolve(mode: .snapshot, latest: delivered())
        )
        #expect(host.previewTile == .widget)

        host.setPreview(MonitorBoardPreview.resolve(mode: .names, latest: delivered()))
        #expect(host.previewTile == .names)

        host.setPreview(MonitorBoardPreview.resolve(mode: .snapshot, latest: nil))
        #expect(host.previewTile == .empty)
    }

    /// The mode's own data, not the desktop's: a fixture read must not depend on
    /// whether the machine happens to have delivered anything.
    @Test("sample mode is available with no desktop reading at all")
    func sampleModeIndependentOfDesktop() {
        let preview = MonitorBoardPreview.resolve(mode: .sample, latest: nil)
        #expect(preview.tile == .widget)
        #expect(preview.capturedAt == MonitorBoardPreviewFixture.referenceDate)
        let repeated = MonitorBoardPreview.resolve(mode: .sample, latest: nil)
        #expect(repeated == preview, "the fixture must be reproducible")
    }
}
