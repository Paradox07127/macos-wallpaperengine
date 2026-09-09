import Foundation
import LiveWallpaperCore
import SwiftUI

// MARK: - Inspector preview content

/// What the inspector's copy of the board draws in place of the desktop's live
/// data. The desktop itself never has one of these.
enum MonitorBoardPreviewMode: String, CaseIterable, Sendable {
    /// The last reading the desktop actually took, frozen.
    case snapshot
    /// A fixed fixture, so long text and full content can be checked.
    case sample
    /// Icon and name only — legible on a canvas too small for a real tile.
    case names

    static let defaultsKey = "Monitor.PreviewMode"

    var title: LocalizedStringKey {
        switch self {
        case .snapshot: "Last reading"
        case .sample: "Sample data"
        case .names: "Names only"
        }
    }
}

/// Frozen snapshot, history and capture time for an inspector preview. Holding them stable
/// prevents relayout during dragging; the preview owns no runtime lease.
struct MonitorBoardPreview: Equatable {
    /// Which tile a preview draws. Split out of the view so the choice is
    /// assertable without a rendering host.
    enum Tile: Equatable {
        case widget
        case names
        /// No reading was ever taken, so there is nothing honest to draw.
        case empty
    }

    var mode: MonitorBoardPreviewMode
    var snapshot: MonitorSnapshot?
    var history: MonitorHistorySnapshot
    /// Chart reference time — `MonitorChartWindow.reference` — and the instant
    /// whose age is shown. Nil only when there is no snapshot to draw.
    var capturedAt: Date?

    init(
        mode: MonitorBoardPreviewMode,
        snapshot: MonitorSnapshot? = nil,
        history: MonitorHistorySnapshot = MonitorHistorySnapshot(),
        capturedAt: Date? = nil
    ) {
        self.mode = mode
        self.snapshot = snapshot
        self.history = history
        self.capturedAt = capturedAt
    }

    var tile: Tile {
        switch mode {
        case .names: .names
        case .snapshot, .sample: snapshot == nil ? .empty : .widget
        }
    }

    /// The frozen instant, or the caller's clock when there is nothing frozen —
    /// an empty tile draws no chart, so the fallback never reaches an axis.
    func chartReference(fallback: Date) -> Date {
        capturedAt ?? fallback
    }

    /// The desktop's last delivered reading, or the fixture, depending on mode.
    /// `latest` is passed in rather than read here so this stays a pure value
    /// and the caller owns the (read-only) trip to the overlay controller.
    @MainActor
    static func resolve(
        mode: MonitorBoardPreviewMode,
        latest: (snapshot: MonitorSnapshot, history: MonitorHistorySnapshot)?
    ) -> MonitorBoardPreview {
        switch mode {
        case .names:
            return MonitorBoardPreview(mode: .names)
        case .sample:
            let fixture = MonitorBoardPreviewFixture.sample()
            return MonitorBoardPreview(
                mode: .sample,
                snapshot: fixture.snapshot,
                history: fixture.history,
                capturedAt: fixture.capturedAt
            )
        case .snapshot:
            guard let latest else { return MonitorBoardPreview(mode: .snapshot) }
            return MonitorBoardPreview(
                mode: .snapshot,
                snapshot: latest.snapshot,
                history: latest.history,
                capturedAt: Self.capturedAt(of: latest.snapshot)
            )
        }
    }

    /// When the reading was taken, preferring the sampler's own stamp over the
    /// hub's compose time. A snapshot that carries neither is undatable, and
    /// pretending it is "now" would show a fresh age for an unknown reading.
    static func capturedAt(of snapshot: MonitorSnapshot) -> Date? {
        let stamp = snapshot.system?.sampledAt ?? snapshot.timestamp
        guard stamp.isFinite, stamp > 0 else { return nil }
        return Date(timeIntervalSince1970: stamp)
    }
}

// MARK: - Empty state

/// Drawn instead of a widget when no reading has ever been delivered. It says
/// so rather than drawing zeroes that would look like an idle machine.
struct MonitorPreviewEmptyTile: View {
    let kind: MonitorWidgetKind
    var cellHeight: CGFloat
    var cornerRadius: CGFloat = MonitorBoardGeometry.appleCornerRadius

    var body: some View {
        WidgetContainer(
            label: WidgetFactory.displayName(kind),
            systemImage: WidgetFactory.icon(kind),
            cellHeight: cellHeight,
            cornerRadius: cornerRadius
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text(verbatim: "—")
                    .font(DesignTokens.Typography.hero)
                Text(MonitorBoardPreviewStrings.noReadings)
                    .font(DesignTokens.Typography.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Design.inkMuted)
            .accessibilityElement(children: .combine)
        }
    }
}

enum MonitorBoardPreviewStrings {
    static var noReadings: LocalizedStringKey {
        "No readings captured yet"
    }

    static var sampleDataCaption: String {
        String(
            localized: "Sample data, not this Mac",
            bundle: .appLanguage,
            comment: "Inspector board preview caption for the fixed sample-data mode."
        )
    }

    static var noSnapshotCaption: String {
        String(
            localized: "No readings captured yet",
            bundle: .appLanguage,
            comment: "Inspector board preview caption when the desktop has never delivered a reading."
        )
    }

    /// `age` is a formatted relative date ("12 seconds ago").
    static func snapshotAge(_ age: String) -> String {
        String(
            format: String(
                localized: "Frozen: reading from %@",
                bundle: .appLanguage,
                comment: "Inspector board preview caption; %@ is a relative time such as \"12 seconds ago\"."
            ),
            age
        )
    }

    static func relativeAge(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
