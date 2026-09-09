import LiveWallpaperCore
import SwiftUI

/// The preview owns the explanation; the same issue does not also need a banner.
struct WallpaperFailureView: View {
    let failure: WallpaperFailureSnapshot
    var isCurrentAttempt = true
    var onRetry: (() -> Void)?
    var onViewDesktop: (() -> Void)?
    var onChooseSource: (() -> Void)?
    @State private var showsDetails = false
    @State private var report: BugReport?

    var body: some View {
        ScrollView {
            VStack(spacing: DesignTokens.Spacing.xl) {
                IllustratedEmptyState(
                    symbol: "exclamationmark.triangle",
                    title: failure.wallpaperType == .scene ? "Scene could not be loaded" : "Wallpaper could not be loaded",
                    symbolColor: DesignTokens.Colors.Status.warning,
                    variant: .compact
                )
                VStack(spacing: DesignTokens.Spacing.sm) {
                    Text(verbatim: failure.title)
                        .font(DesignTokens.Typography.pageTitle)
                    Text(verbatim: failure.cause.reason)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    // The code is what a bug report is filed against, so it gets
                    // a real control rather than living only inside the details sheet.
                    ErrorCodeChip(
                        code: failure.cause.code,
                        tint: DesignTokens.Colors.Status.warning
                    )
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: DesignTokens.Spacing.sm) {
                    if isCurrentAttempt, let onChooseSource,
                       ["scene.source_unavailable", "scene.cache_missing", "runtime.fileAccessDenied", "runtime.sandboxRevoked", "NSCocoaErrorDomain.257"].contains(failure.cause.code) {
                        Button("Apply Project Folder", action: onChooseSource).buttonStyle(.borderedProminent)
                    } else if failure.cause.canRetry, isCurrentAttempt, let onRetry {
                        Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                    }
                    Button("View Details") { showsDetails = true }.buttonStyle(.bordered)
                }
                VStack(spacing: DesignTokens.Spacing.sm) {
                    if failure.stage == "runtime" {
                        Text("Wallpaper playback stopped because of this error.")
                    } else if let previous = failure.previousWallpaper {
                        Text("Desktop kept the previous wallpaper: \(previous)")
                    } else {
                        Text("No wallpaper was applied to this display.")
                    }
                    if let onViewDesktop {
                        Button("View Current Wallpaper", action: onViewDesktop).buttonStyle(.borderless)
                    }
                }
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

                HStack(spacing: DesignTokens.Spacing.lg) {
                    if let id = failure.workshopID, !id.isEmpty,
                       id.allSatisfy(\.isNumber),
                       let url = URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)") {
                        Link("Open in Workshop", destination: url).buttonStyle(.link)
                    }
                    feedbackButton
                }
                .font(DesignTokens.Typography.caption)
            }
            .padding(DesignTokens.Spacing.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.Colors.pageBackground)
        .sheet(isPresented: $showsDetails) {
            WallpaperFailureDetails(failure: failure)
        }
        .sheet(item: $report) { value in ReportBugSheet(report: value, onDismiss: { report = nil }) }
    }

    private var feedbackButton: some View {
        Button {
            report = BugReporter.makeReport(activeWallpapers: [], failureContext: failure)
        } label: {
            Label("Report this Problem…", systemImage: "ladybug")
        }
        .buttonStyle(.borderless)
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

    var body: some View {
        if let failure = attempt.failure {
            WallpaperFailureView(failure: failure, onRetry: {
                screenManager.retryWallpaperAttempt(for: screen)
            }, onViewDesktop: {
                screenManager.inspectWallpaperAttempt(false, for: screen)
            }, onChooseSource: {
                #if !LITE_BUILD
                guard let url = WPEFolderPicker.chooseImportFolder() else { return }
                Task { @MainActor in await screenManager.importWallpaperEngineProject(at: url, for: screen) }
                #endif
            })
            .id(attempt.id)
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
}
