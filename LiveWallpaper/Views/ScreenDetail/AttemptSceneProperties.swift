#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct AttemptSceneProperties: View {
    let screen: Screen
    let attempt: WallpaperLoadAttempt
    @Environment(ScreenManager.self) private var screenManager
    @State private var schema: WallpaperEngineProjectPropertySchema?
    @State private var failure: WallpaperFailureCause?
    @State private var resolved = false
    @State private var reload = 0
    @State private var report: BugReport?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                Text(verbatim: LogPrivacyRedactor.scrub(attempt.title)).font(DesignTokens.Typography.sectionTitle)
                if let schema, let descriptor {
                    WPESceneCustomSettingsCard(screen: screen, schema: schema, descriptor: Binding(
                        get: { self.descriptor ?? descriptor },
                        set: { screenManager.updateAttemptDescriptor($0, attemptID: attempt.id, for: screen) }
                    ), attemptID: attempt.id)
                        .disabled(attempt.phase != .failed)
                    Text("Changes will be used on the next retry.")
                        .font(DesignTokens.Typography.caption).foregroundStyle(.secondary)
                } else if let failure {
                    Label("Unable to Read Settings", systemImage: "exclamationmark.triangle")
                        .font(DesignTokens.Typography.bodyEmphasized)
                    Text(verbatim: failure.reason).font(DesignTokens.Typography.body).textSelection(.enabled)
                    Button("Reload Settings") { reload += 1 }.buttonStyle(.bordered)
                    Button {
                        report = BugReporter.makeReport(activeWallpapers: [], failureContext: settingsFailure(cause: failure))
                    } label: { Label("Report this Problem…", systemImage: "ladybug") }
                        .buttonStyle(.borderless)
                } else if resolved {
                    IllustratedEmptyState(symbol: "slider.horizontal.3", title: "No scene options", variant: .compact)
                } else {
                    ProgressView().accessibilityLabel(Text("Loading settings…"))
                }
            }
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignTokens.Colors.pageBackground)
        .task(id: loadKey) {
            schema = nil; failure = nil; resolved = false
            guard let descriptor else {
                guard attempt.phase == .failed else { return }
                failure = WallpaperFailureCause(code: "schema.unavailable", reason: String(localized: "Settings are unavailable because the project could not be read.", bundle: .appLanguage))
                return
            }
            let result = await WPESceneProjectSchemaLoader.load(descriptor: descriptor, wpeOrigin: attempt.origin)
            guard !Task.isCancelled else { return }
            schema = result.schema
            resolved = result.schema != nil || result.isExpectedAbsence
            failure = resolved ? nil : result.failure ?? WallpaperFailureCause(code: "schema.read", reason: result.log)
        }
        .sheet(item: $report) { value in ReportBugSheet(report: value, onDismiss: { report = nil }) }
    }

    private var descriptor: SceneDescriptor? {
        guard let current = screenManager.wallpaperLoads.attempt(for: screen), current.id == attempt.id,
              case let .scene(descriptor) = current.configuration?.activeWallpaper else { return nil }
        return descriptor
    }

    private var loadKey: String {
        "\(attempt.id):\(attempt.phase):\(descriptor?.cacheRelativePath ?? ""): \(descriptor?.entryFile ?? ""): \(reload)"
    }

    private func settingsFailure(cause: WallpaperFailureCause) -> WallpaperFailureSnapshot {
        WallpaperFailureSnapshot(id: attempt.id, title: attempt.title, workshopID: attempt.origin?.workshopID,
                                 displayName: screen.name, stage: "settings", cause: cause,
                                 previousWallpaper: attempt.failure?.previousWallpaper, timestamp: Date(), diagnostics: "")
    }
}
#endif
