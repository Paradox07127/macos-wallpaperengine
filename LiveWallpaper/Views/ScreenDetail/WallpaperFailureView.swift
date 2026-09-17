import LiveWallpaperCore
import SwiftUI

/// Deliberately not an `InlineNoticeBanner`: here the failure *is* the page's content.
struct WallpaperFailureView: View {
    let failure: WallpaperFailureSnapshot
    var isCurrentAttempt = true
    var onRetry: (() -> Void)?
    var onViewDesktop: (() -> Void)?
    var onChooseSource: (() -> Void)?
    /// Non-nil when this display has a configuration worth clearing.
    var onClearDisplay: (() -> Void)?
    @State private var showsDetails = false

    private var failureClass: WallpaperFailureClass {
        failure.cause.failureClass
    }

    /// Historic failures keep only the Workshop link: retrying or re-linking would act on
    /// the display's current assignment, not on the one being read about.
    private var recovery: [WallpaperFailureRecovery] {
        let actions = failure.cause.recovery(
            workshopID: failure.workshopID,
            canChooseSource: onChooseSource != nil
        )
        guard isCurrentAttempt else {
            return actions.filter { action in
                if case .openWorkshop = action {
                    return true
                }
                return false
            }
        }
        return actions
    }

    var body: some View {
        ScrollView {
            // Uneven on purpose: the recovery belongs to the diagnosis above it, the display section does not.
            VStack(alignment: .leading, spacing: 0) {
                diagnosis
                Divider()
                    .padding(.vertical, DesignTokens.Spacing.xl)
                displayOutcome
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
        .sheet(isPresented: $showsDetails) {
            WallpaperFailureDetails(failure: failure)
        }
    }

    private var diagnosis: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            Image(systemName: failureClass.symbol)
                .font(.system(size: 32))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(failureClass.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    Text(failureClass.kicker)
                        .font(DesignTokens.Typography.captionEmphasized)
                        .foregroundStyle(failureClass.tint)
                        .textCase(.uppercase)
                    Spacer(minLength: DesignTokens.Spacing.sm)
                    ErrorCodeChip(code: failure.cause.code, tint: failureClass.tint)
                }
                Text(verbatim: failure.title)
                    .font(DesignTokens.Typography.pageTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignTokens.Spacing.xxs)
                Text(verbatim: failure.cause.reason)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignTokens.Spacing.md)
                actionRow
                    .padding(.top, DesignTokens.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            WallpaperFailureRecoveryActions(
                recovery: recovery,
                onRetry: onRetry,
                onChooseSource: onChooseSource,
                isCompact: false
            )
            Button("View Details") { showsDetails = true }
                .buttonStyle(.bordered)
        }
    }

    private var displayOutcome: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("On this display")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            outcomeSentence
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // The Spacer is load-bearing: the destructive control must never sit adjacent to the safe one.
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let onViewDesktop {
                    Button("View Current Wallpaper", action: onViewDesktop)
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: DesignTokens.Spacing.xl)
                // Destructive controls never take prominent (DESIGN.md rule 8).
                if isCurrentAttempt, let onClearDisplay {
                    Button(role: .destructive, action: onClearDisplay) {
                        Label("Clear Wallpaper", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .destructiveControlTint()
                    .help(Text("Stops this display's wallpaper and forgets its settings. Downloaded files are kept."))
                    .accessibilityHint(Text("Stops this display's wallpaper and forgets its settings. Downloaded files are kept."))
                }
            }
        }
    }

    @ViewBuilder
    private var outcomeSentence: some View {
        if failure.stage == "runtime" {
            Text("Wallpaper playback stopped because of this error.")
        } else if let previous = failure.previousWallpaper {
            Text("Desktop kept the previous wallpaper: \(previous)")
        } else {
            Text("No wallpaper was applied to this display.")
        }
    }
}

private struct WallpaperFailureDetails: View {
    let failure: WallpaperFailureSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var report: BugReport?

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            SteamSheetHeader(icon: "doc.text.magnifyingglass", title: "Failure Details")
            Text(verbatim: failure.title).font(DesignTokens.Typography.sectionTitle)
            ScrollView {
                Text(verbatim: failure.diagnosticText)
                    .font(DesignTokens.Typography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SheetFooterBar(primaryTitle: "Done", primaryAction: { dismiss() }, leading: {
                Button {
                    report = BugReporter.makeReport(activeWallpapers: [], failureContext: failure)
                } label: { Label("Report this Problem…", systemImage: "ladybug") }
                    .buttonStyle(.borderless)
            })
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(width: 560, height: 480)
        .sheet(item: $report) { value in ReportBugSheet(report: value, onDismiss: { report = nil }) }
    }
}

struct WallpaperAttemptPreview: View {
    let screen: Screen
    let attempt: WallpaperLoadAttempt
    @Environment(ScreenManager.self) private var screenManager
    @State private var pendingDestructive: PendingDestructive?

    var body: some View {
        if let failure = attempt.failure {
            WallpaperFailureView(
                failure: failure,
                onRetry: { screenManager.retryWallpaperAttempt(for: screen) },
                onViewDesktop: { screenManager.inspectWallpaperAttempt(false, for: screen) },
                onChooseSource: chooseSourceAction,
                onClearDisplay: clearDisplayAction
            )
            .id(attempt.id)
            .confirmDestructive($pendingDestructive)
        } else {
            VStack(spacing: DesignTokens.Spacing.lg) {
                ProgressView().accessibilityLabel(Text("Preparing wallpaper…"))
                Text(verbatim: LogPrivacyRedactor.scrub(attempt.title)).font(DesignTokens.Typography.pageTitle)
                Text("Preparing wallpaper…").font(DesignTokens.Typography.body).foregroundStyle(.secondary)
                Button("Cancel") {
                    guard screenManager.wallpaperLoads.attempt(for: screen)?.id == attempt.id else { return }
                    screenManager.beginExplicitWallpaperSelection(for: screen)
                }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Lite ships no project importer, so the action is absent rather than a button that does
    /// nothing — its source-relink codes reach a revoked video file in Lite too.
    private var chooseSourceAction: (() -> Void)? {
        #if LITE_BUILD
        return nil
        #else
        return {
            guard let url = WPEFolderPicker.chooseImportFolder() else { return }
            Task { @MainActor in await screenManager.importWallpaperEngineProject(at: url, for: screen) }
        }
        #endif
    }

    /// Absent when there is nothing saved to clear, so the page never offers to
    /// remove a configuration this display does not have.
    private var clearDisplayAction: (() -> Void)? {
        guard screenManager.getConfiguration(for: screen) != nil else { return nil }
        return {
            pendingDestructive = PendingDestructive(
                .clearCurrentWallpaper(displayName: screen.name)
            ) {
                screenManager.clearWallpaperForScreen(screen)
                // Drops the failed attempt too, otherwise the page the user just
                // escaped from stays on screen describing a wallpaper that is
                // no longer assigned to anything.
                screenManager.beginExplicitWallpaperSelection(for: screen)
            }
        }
    }
}
