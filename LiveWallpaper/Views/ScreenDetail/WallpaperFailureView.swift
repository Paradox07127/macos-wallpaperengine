import LiveWallpaperCore
import SwiftUI

/// The preview owns the explanation; the same issue does not also need a banner.
///
/// Deliberately not an `InlineNoticeBanner`: here the failure *is* the page's
/// content, and a tinted notice box floating in an otherwise empty column reads
/// as an annotation on something that is not there.
struct WallpaperFailureView: View {
    let failure: WallpaperFailureSnapshot
    var isCurrentAttempt = true
    var onRetry: (() -> Void)?
    var onViewDesktop: (() -> Void)?
    var onChooseSource: (() -> Void)?
    /// Non-nil when this display has a configuration worth clearing. This page is
    /// the user's only way out of a wallpaper that cannot load — the header's
    /// trash is hidden while a failed attempt is being inspected — so the escape
    /// has to exist here or not at all.
    var onClearDisplay: (() -> Void)?
    @State private var showsDetails = false

    private var failureClass: WallpaperFailureClass {
        failure.cause.failureClass
    }

    /// Historic failures get no recovery row: retrying or re-linking would act on
    /// the display's current assignment, not on the one being read about.
    private var recovery: [WallpaperFailureRecovery] {
        guard isCurrentAttempt else { return [] }
        return failure.cause.recovery(
            workshopID: failure.workshopID,
            canChooseSource: onChooseSource != nil
        )
    }

    var body: some View {
        ScrollView {
            // Uneven on purpose. A uniform stack spacing gives every boundary
            // the same weight, which is what made the page read as one slab of
            // text: the recovery belongs to the diagnosis above it, the display
            // section does not.
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

    /// Outcome, then subject, then the sentence the reader came for.
    ///
    /// The depth here is spacing rhythm and type scale, not nested containers:
    /// the kicker/title pair is set tight so it reads as one unit, the
    /// explanation is pushed away from it, and the error code leaves the reading
    /// column entirely so three things — not four — compete for the first look.
    private var diagnosis: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.lg) {
            // Hierarchical rendering, not a tinted plate behind it: the glyph
            // gets its own depth without another surface on the page.
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
                // Tight to the kicker: outcome and subject are one unit.
                Text(verbatim: failure.title)
                    .font(DesignTokens.Typography.pageTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignTokens.Spacing.xxs)
                // Primary weight and pushed clear of the pair above, because
                // this is the sentence the reader actually came for. It used to
                // sit below the error code in visual priority.
                Text(verbatim: failure.cause.reason)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DesignTokens.Spacing.md)
                // Inside the glyph's column, not back at the page margin: the
                // recovery is part of the failure, and a row starting further
                // left than the sentence it answers reads as a separate block.
                actionRow
                    .padding(.top, DesignTokens.Spacing.xl)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The only row allowed a prominent button, and only when a recovery leads
    /// it — a class with no way forward gets no prominent button at all, because
    /// prominent means "press this and it is fixed".
    private var actionRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            WallpaperFailureRecoveryActions(
                recovery: recovery,
                onRetry: onRetry,
                onChooseSource: onChooseSource,
                isCompact: false
            )
            // Belongs with the failure, not with the display: reading the log is
            // what you do when the recovery beside it did not apply. Never
            // prominent, always last.
            Button("View Details") { showsDetails = true }
                .buttonStyle(.bordered)
        }
    }

    /// What the display is doing now, and how to stop it doing that. Separated
    /// from the recovery row by a divider so the destructive control is never
    /// adjacent to Retry.
    private var displayOutcome: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            // Names the section, so the reader knows this block is about the
            // display rather than more detail about the failure — the question
            // the flat version left them to work out from the wording.
            Text("On this display")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            outcomeSentence
                .font(DesignTokens.Typography.body)
                .foregroundStyle(DesignTokens.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // Safe action on the leading edge where the eye lands, destructive
            // pushed to the far edge: they are the same row so the section reads
            // as one footer, but they are never adjacent to mis-click between.
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

    /// Lite ships no project importer, so the action has to be absent rather
    /// than a button that silently does nothing — the source-relink codes it
    /// answers (`runtime.fileAccessDenied`, `NSCocoaErrorDomain.257`) reach a
    /// revoked video file in Lite too.
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
