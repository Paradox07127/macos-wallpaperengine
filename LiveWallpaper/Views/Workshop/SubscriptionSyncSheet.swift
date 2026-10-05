#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct SubscriptionSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var setupController

    @State private var sync = WorkshopSubscriptionSync()
    @State private var downloads = WorkshopDownloadCoordinator.shared
    @State private var queue = WorkshopDownloadQueue.shared
    @State private var showingSignIn = false
    /// Leading edge of a row's title text, so dividers start after the checkbox.
    @State private var titleInset: CGFloat = 0

    private static let rowSpace = "SubscriptionSyncRows"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "arrow.down.circle",
                    title: "Sync subscribed wallpapers",
                    subtitle: "Downloads subscribed Wallpaper Engine items missing from this Mac. No files are deleted or subscriptions removed."
                )
                statusArea
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.xl)
            .padding(.bottom, rows.isEmpty ? DesignTokens.Spacing.xl : DesignTokens.Spacing.md)

            missingSection

            SheetFooterBar(
                primaryTitle: primaryTitle,
                primaryAction: primaryAction,
                primaryDisabled: primaryDisabled,
                cancelTitle: "Done",
                cancelAction: { dismiss() },
                leading: {
                    if sync.hasActiveDownloads {
                        Button("Cancel downloads") { sync.cancelDownloads() }
                            .buttonStyle(.bordered)
                    }
                }
            )
        }
        .frame(width: SteamSheetWidth.dense)
        .task {
            if sync.phase == .idle {
                await sync.refresh(using: doctor)
            }
        }
        .onChange(of: downloadedIDs, initial: true) { _, downloaded in
            sync.selection.subtract(downloaded)
        }
        .sheet(isPresented: $showingSignIn) {
            AppLanguageScope(defaults: .appScoped()) {
                SteamSignInSheet { accountName in
                    setupController.adoptSignedInAccount(accountName)
                }
            }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusArea: some View {
        switch sync.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: DesignTokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Reading your Steam subscriptions…")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
        case let .ready(missing):
            if missing.isEmpty {
                Label("Everything you're subscribed to is already on this Mac.", systemImage: "checkmark.circle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.active)
            }
        case let .failed(reason):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .fixedSize(horizontal: false, vertical: true)
                if sync.requiresSignIn {
                    Button("Sign In") { showingSignIn = true }
                }
            }
        }
    }

    // MARK: - Missing items

    @ViewBuilder
    private var missingSection: some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                listHeader
                GroupBox {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows, id: \.self) { itemID in
                                row(for: itemID)
                                if itemID != rows.last {
                                    Divider().padding(.leading, titleInset)
                                }
                            }
                        }
                        .coordinateSpace(.named(Self.rowSpace))
                    }
                    .frame(maxHeight: 300)
                }
                .groupBoxStyle(ContainerGroupBoxStyle())
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)
        }
    }

    private var listHeader: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Toggle(sources: rows.filter(isSelectable).map { selectionBinding(for: $0) }, isOn: \.self) {
                Text("Select all")
            }
            .toggleStyle(.checkbox)
            .disabled(!rows.contains(where: isSelectable))

            Text("\(selectedCount) of \(rows.count) selected")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer(minLength: DesignTokens.Spacing.sm)

            Button {
                Task { await sync.refresh(using: doctor) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Check again"))
            .help(Text("Check again"))
            .disabled(sync.phase == .checking)
        }
    }

    private func row(for itemID: UInt64) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Toggle(isOn: selectionBinding(for: itemID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: sync.title(for: itemID))
                        .font(DesignTokens.Typography.body)
                        .lineLimit(1)
                    Text(verbatim: String(itemID))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(Self.rowSpace)).minX
                } action: {
                    titleInset = $0
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!isSelectable(itemID))

            Spacer(minLength: DesignTokens.Spacing.sm)
            downloadStatus(for: itemID)
        }
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private func downloadStatus(for itemID: UInt64) -> some View {
        if queue.isQueued(itemID) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text("Waiting")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                cancelButton(for: itemID)
            }
        } else {
            switch downloads.phase(for: itemID) {
            case .idle:
                EmptyView()
            case .downloading:
                HStack(spacing: DesignTokens.Spacing.xs) {
                    if let fraction = downloads.progress[itemID] {
                        ProgressView(value: fraction)
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(DesignTokens.Typography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        let received = WorkshopDownloadPresentation.detailText(
                            downloaded: downloads.progressBytes[itemID]?.downloaded, total: nil,
                            bytesPerSecond: nil, fraction: nil
                        )
                        if !received.isEmpty {
                            Text(verbatim: received)
                                .font(DesignTokens.Typography.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    cancelButton(for: itemID)
                }
            case .importing:
                HStack(spacing: DesignTokens.Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text("Importing…")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                    cancelButton(for: itemID)
                }
            case .succeeded, .succeededAsPreset:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.active)
                    .accessibilityLabel(Text("Installed"))
            case let .failed(reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .help(Text(verbatim: reason))
                    .accessibilityLabel(Text("Download failed"))
            }
        }
    }

    private func cancelButton(for itemID: UInt64) -> some View {
        Button {
            queue.cancel(itemID)
            sync.selection.remove(itemID)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Cancel download"))
        .help(Text("Cancel download"))
    }

    // MARK: - Selection

    private var missing: [UInt64] {
        if case let .ready(missing) = sync.phase {
            return missing
        }
        return []
    }

    private var rows: [UInt64] {
        sync.rows
    }

    private var downloadedIDs: Set<UInt64> {
        Set(rows.filter(wasJustDownloaded))
    }

    private var selectedCount: Int {
        rows.filter { sync.selection.contains($0) }.count
    }

    /// Only unticks a row that finished; whether it is installed is the latest check's call, so it stays selectable.
    private func wasJustDownloaded(_ itemID: UInt64) -> Bool {
        switch downloads.phase(for: itemID) {
        case .succeeded, .succeededAsPreset: true
        default: false
        }
    }

    private func isSelectable(_ itemID: UInt64) -> Bool {
        !downloads.isBusy(itemID)
    }

    private func selectionBinding(for itemID: UInt64) -> Binding<Bool> {
        Binding(
            get: { sync.selection.contains(itemID) },
            set: { isOn in
                if isOn {
                    sync.selection.insert(itemID)
                } else {
                    sync.selection.remove(itemID)
                    queue.remove(itemID)
                }
            }
        )
    }

    // MARK: - Footer

    private var primaryTitle: LocalizedStringKey {
        missing.isEmpty ? "Check subscriptions" : "Download selected"
    }

    private var primaryDisabled: Bool {
        missing.isEmpty ? sync.phase == .checking : sync.downloadableSelection().isEmpty
    }

    private func primaryAction() {
        if missing.isEmpty {
            Task { await sync.refresh(using: doctor) }
        } else {
            sync.downloadSelected(using: doctor)
        }
    }
}
#endif
