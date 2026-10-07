#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// All entry points share the app-lifetime coordinator and serial queue.
struct WorkshopDownloadsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @State private var downloads = WorkshopDownloadCoordinator.shared
    @State private var queue = WorkshopDownloadQueue.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SteamSheetHeader(icon: "arrow.down.circle", title: "Downloads")
                .padding(DesignTokens.Spacing.xl)
            if downloads.downloadOrder.isEmpty {
                IllustratedEmptyState(
                    symbol: "arrow.down.circle", title: "No downloads yet",
                    message: "Workshop downloads will appear here."
                )
                .padding(DesignTokens.Spacing.xl)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                        ForEach(downloads.downloadOrder.reversed(), id: \.self) { itemID in
                            downloadRow(itemID)
                            Divider()
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.xl)
                }
                .frame(maxHeight: 420)
            }
            SheetFooterBar(primaryTitle: "Done", primaryAction: { dismiss() })
        }
        .frame(width: SteamSheetWidth.dense)
        .background(DesignTokens.Colors.pageBackground)
    }

    private func downloadRow(_ itemID: UInt64) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                Text(verbatim: downloads.titles[itemID] ?? String(itemID))
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if queue.isQueued(itemID) || downloads.isBusy(itemID) {
                    Button("Cancel") { queue.cancel(itemID) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if case .failed = downloads.phase(for: itemID) {
                    Button("Retry") { queue.retry(itemID, using: doctor) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!doctor.isDownloadReady)
                        .help(Text(verbatim: doctor.downloadBlockerMessage ?? ""))
                } else if downloads.cancelledItems.contains(itemID) {
                    Button("Retry") { queue.retry(itemID, using: doctor) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!doctor.isDownloadReady)
                } else if downloads.phase(for: itemID) == .idle, downloads.retryRequest(for: itemID) != nil {
                    Button("Download") { queue.retry(itemID, using: doctor) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!doctor.isDownloadReady)
                }
                if !queue.isQueued(itemID), !downloads.isBusy(itemID) {
                    Button {
                        downloads.removeFromHistory(itemID)
                    } label: {
                        Label("Remove from download history", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(Text("Remove from download history"))
                }
            }
            if queue.isQueued(itemID) {
                Label("Queued", systemImage: "clock")
                    .foregroundStyle(.secondary)
            } else {
                switch downloads.phase(for: itemID) {
                case .downloading, .importing:
                    WorkshopDownloadProgress(itemID: itemID)
                case let .failed(reason):
                    Label("Download failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.danger)
                    Text(verbatim: reason)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                case .succeeded:
                    Label("Completed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.active)
                case .succeededAsPreset:
                    Label("Preset added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.active)
                case .idle:
                    if downloads.cancelledItems.contains(itemID) {
                        Label("Cancelled", systemImage: "xmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Download", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(DesignTokens.Typography.caption)
        .accessibilityElement(children: .contain)
    }
}

/// Shared numeric progress for the download list and pasted items; ticks expire stale speed.
struct WorkshopDownloadProgress: View {
    let itemID: UInt64
    var listedSize: UInt64?
    private var downloads: WorkshopDownloadCoordinator {
        .shared
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let presentation = WorkshopDownloadPresentation.make(
                ticketState: nil, screenName: "", wallpapersOn: true,
                phase: downloads.phase(for: itemID),
                isFetchingDependencies: downloads.fetchingDependencies.contains(itemID),
                fraction: downloads.progress[itemID],
                downloadedBytes: downloads.progressBytes[itemID]?.downloaded,
                totalBytes: downloads.progressBytes[itemID]?.total ?? listedSize ?? downloads.listedSizes[itemID],
                bytesPerSecond: downloads.bytesPerSecond(for: itemID, at: context.date),
                isInstalled: false, reportsSave: false, blocker: nil,
                transferState: downloads.transferState(for: itemID, at: context.date)
            )
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(verbatim: presentation.status)
                        .font(DesignTokens.Typography.caption)
                    if !presentation.detail.isEmpty {
                        Text(verbatim: presentation.detail)
                            .font(DesignTokens.Typography.metric)
                    }
                }
                .foregroundStyle(.secondary)
                switch presentation.progress {
                case let .fraction(value): ProgressView(value: value)
                case .indeterminate: ProgressView().controlSize(.small)
                case .none: EmptyView()
                }
            }
        }
    }
}
#endif
