import LiveWallpaperCore
import SwiftUI

/// Reviews diagnostics before opening a public GitHub issue.
struct ReportBugSheet: View {
    let report: BugReport
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sanitizedLogURL: URL?
    @State private var browserFailed = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header

                Divider()

                diagnosticPreview
            }
            .padding(20)

            footer
        }
        .frame(
            minWidth: 520,
            idealWidth: 560,
            maxWidth: 720,
            minHeight: 460,
            idealHeight: 520,
            maxHeight: 760
        )
        .task(id: report.id) {
            guard let source = report.logFileURL, report.logFileExists else {
                sanitizedLogURL = nil
                return
            }
            sanitizedLogURL = await Self.makeSanitizedLogCopy(from: source)
        }
    }

    private var header: some View {
        SteamSheetHeader(
            icon: "ladybug.fill",
            title: "Report a Bug",
            iconTint: DesignTokens.Colors.Status.danger,
            subtitle: "Continuing sends the prefilled diagnostics to GitHub. Review them first; published issues are public."
        )
    }

    private var diagnosticPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Diagnostic snapshot")
                .font(.subheadline.weight(.medium))

            ScrollView {
                Text(verbatim: report.diagnosticMarkdown)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .frame(maxHeight: .infinity)

            if browserFailed {
                Label("The browser could not be opened. You can copy the diagnostics below.", systemImage: "exclamationmark.triangle")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
            }
            if let logURL = sanitizedLogURL {
                Label {
                    Text("Attach the sanitized log from Finder to the GitHub issue.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                }
                .help(Text(verbatim: logURL.path))
            }
        }
    }

    private var footer: some View {
        SheetFooterBar(
            primaryTitle: "Continue in Browser",
            primaryAction: {
                if BugReporter.openIssueInBrowser(report.issueURL) {
                    onDismiss()
                    dismiss()
                } else {
                    browserFailed = true
                }
            },
            cancelTitle: "Cancel",
            cancelAction: {
                onDismiss()
                dismiss()
            }
        ) {
            Button {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(report.diagnosticMarkdown, forType: .string)
            } label: {
                Label(copied ? "Copied" : "Copy Diagnostics", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            if let logURL = sanitizedLogURL {
                Button {
                    BugReporter.revealLogInFinder(logURL)
                } label: {
                    Label("Show Log in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .help(Text("Open Finder and highlight the sanitized log file"))
                .accessibilityLabel(Text("Show sanitized log in Finder"))
            }
        }
    }

    /// Scrubs the whole runtime log and writes it to a stable caches path the user can drag after the sheet dismisses.
    nonisolated private static func makeSanitizedLogCopy(from source: URL) async -> URL? {
        await Task.detached(priority: .userInitiated) {
            guard let raw = try? String(contentsOf: source, encoding: .utf8) else { return nil }
            let scrubbed = LogPrivacyRedactor.scrub(raw)

            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let destination = caches.appendingPathComponent("Loomscreen-log-sanitized.txt")
            do {
                try scrubbed.write(to: destination, atomically: true, encoding: .utf8)
                return destination
            } catch {
                return nil
            }
        }.value
    }
}
