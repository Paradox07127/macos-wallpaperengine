#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct SubscriptionSyncSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(WorkshopSetupController.self) private var setupController

    @State private var sync = WorkshopSubscriptionSync()
    @State private var downloads = WorkshopDownloadCoordinator.shared
    @State private var showingSignIn = false

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
            .padding(DesignTokens.Spacing.xl)

            missingList

            SheetFooterBar(
                primaryTitle: primaryTitle,
                primaryAction: primaryAction,
                primaryDisabled: primaryDisabled,
                cancelTitle: "Done",
                cancelAction: { dismiss() }
            )
        }
        .frame(width: SteamSheetWidth.dense)
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
            } else {
                Text("\(missing.count) subscribed wallpapers are missing from this Mac.")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
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
    private var missingList: some View {
        if case let .ready(missing) = sync.phase, !missing.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(missing, id: \.self) { itemID in
                        row(for: itemID)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(DesignTokens.Colors.surfaceRaised)
        }
    }

    private func row(for itemID: UInt64) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: sync.title(for: itemID))
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                Text(verbatim: String(itemID))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            // Progress is the download queue's, not a second one: this only
            // reads back the phase that queue already publishes.
            downloadStatus(for: itemID)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Spacing.xs)
    }

    @ViewBuilder
    private func downloadStatus(for itemID: UInt64) -> some View {
        switch downloads.phase(for: itemID) {
        case .idle:
            EmptyView()
        case .downloading, .importing:
            ProgressView().controlSize(.small)
        case .succeeded, .succeededAsPreset:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.active)
        case let .failed(reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.danger)
                .help(Text(verbatim: reason))
        }
    }

    // MARK: - Footer

    private var hasMissing: Bool {
        if case let .ready(missing) = sync.phase {
            return !missing.isEmpty
        }
        return false
    }

    private var primaryTitle: LocalizedStringKey {
        hasMissing ? "Download all" : "Check subscriptions"
    }

    private var primaryDisabled: Bool {
        sync.phase == .checking
    }

    private func primaryAction() {
        if hasMissing {
            sync.downloadMissing(using: doctor)
        } else {
            Task { await sync.refresh(using: doctor) }
        }
    }
}
#endif
