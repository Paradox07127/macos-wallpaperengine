#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct WorkshopPasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @State private var model = WorkshopPasteQueueModel()
    @State private var downloads = WorkshopDownloadCoordinator.shared
    @State private var toastVisible = false
    @FocusState private var textFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pasteArea
            downloadReadinessBanner
            Divider()
            queueArea
        }
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 720, minHeight: 340, idealHeight: 420, maxHeight: 760)
        .background(DesignTokens.Colors.pageBackground)
        .overlay(alignment: .bottom) {
            DiagnosticExportToast(isPresented: $toastVisible)
                .padding(.bottom, 22)
                .allowsHitTesting(false)
        }
        .onAppear { textFieldIsFocused = true }
        .onDisappear { model.removeAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Add from Steam Workshop")
                    .font(DesignTokens.Typography.sectionTitle)
                Text("Paste Workshop URLs or item IDs. No Web API key needed — that's only for searching.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)

            if !downloadableRows.isEmpty {
                Button {
                    for row in downloadableRows { downloadAction(for: row)?() }
                } label: {
                    Label("Download all", systemImage: "arrow.down.circle.fill")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .help(Text("Download every queued item with SteamCMD"))
            }

            Button {
                model.openAllInSteam()
            } label: {
                Image(systemName: "arrow.up.forward.app.fill")
            }
            .controlSize(.small)
            .disabled(model.rows.isEmpty)
            .help(Text("Open all in Steam"))
            .accessibilityLabel(Text("Open all in Steam"))

            Button(role: .destructive) {
                model.removeAll()
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .disabled(model.rows.isEmpty)
            .help(Text("Clear queue"))
            .accessibilityLabel(Text("Clear queue"))

            Button("Done") { dismiss() }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
    }

    // MARK: - Paste area

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                            .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
                    }
                TextEditor(text: Binding(
                    get: { model.rawInput },
                    set: { model.updateRawInput($0) }
                ))
                .focused($textFieldIsFocused)
                .font(DesignTokens.Typography.body)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .scrollContentBackground(.hidden)

                if model.rawInput.isEmpty {
                    Text("https://steamcommunity.com/sharedfiles/filedetails/?id=…\n3725117707\nsteam://url/CommunityFilePage/…")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DesignTokens.Spacing.cardInset)
                        .padding(.vertical, DesignTokens.Spacing.cardInset)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 66, maxHeight: 96)

            HStack(spacing: 8) {
                if let summary = model.lastIngestionSummary, summary != .init(added: 0, duplicates: 0, invalid: 0) {
                    Text(summaryString(summary))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(Text(summaryString(summary)))
                }
                Spacer()
                Button {
                    model.ingestFromRawInput()
                } label: {
                    Label("Add to queue", systemImage: "plus.circle.fill")
                        .font(DesignTokens.Typography.bodyEmphasized)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
    }

    // MARK: - Queue area

    @ViewBuilder
    private var queueArea: some View {
        if model.rows.isEmpty {
            emptyState
        } else {
            queueList
        }
    }

    private var emptyState: some View {
        IllustratedEmptyState(
            symbol: "tray",
            title: "Paste a Workshop URL to get started.",
            message: "Only public metadata is read for each item. Your Steam credentials stay in SteamCMD."
        )
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.md) {
                ForEach(model.rows) { row in
                    WorkshopPasteRowCard(
                        row: row,
                        onRetry: { model.retry(rowID: row.id) },
                        onRemove: { model.remove(rowID: row.id) },
                        onOpenInSteam: { openInSteam(row) },
                        onCopyDiagnostic: { copyDiagnostic(for: row.id) },
                        onDownload: downloadAction(for: row),
                        downloadPhase: row.publishedFileID.map { downloads.phase(for: $0) } ?? .idle
                    )
                }
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.vertical, DesignTokens.Settings.formVerticalMargin)
        }
    }

    // MARK: - Download readiness

    /// Without this the Download buttons simply do not render, which reads as a
    /// missing feature rather than a missing setup step.
    @ViewBuilder
    private var downloadReadinessBanner: some View {
        if !doctor.isDownloadReady {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up SteamCMD to download here")
                        .font(DesignTokens.Typography.bodyEmphasized)
                    Text("Pasted items still preview and open in Steam. Downloading needs SteamCMD signed in to your own account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DesignTokens.Colors.Status.warning.opacity(0.10),
                in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
            )
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.bottom, DesignTokens.Settings.formVerticalMargin)
        }
    }

    /// Rows that have an id and are not already downloading or installed.
    private var downloadableRows: [WorkshopPasteQueueModel.Row] {
        guard doctor.isDownloadReady else { return [] }
        return model.rows.filter { row in
            guard let id = row.publishedFileID else { return false }
            return downloads.phase(for: id) == .idle
        }
    }

    // MARK: - Helpers

    /// `nil` hides the button: no id to download, or SteamCMD hasn't been set up
    /// and signed in, in which case the Workshop setup sheet is the way through.
    private func downloadAction(for row: WorkshopPasteQueueModel.Row) -> (() -> Void)? {
        guard let itemID = row.publishedFileID, doctor.isDownloadReady else { return nil }
        let title = row.metadata?.title ?? String(itemID)
        return { downloads.download(itemID: itemID, title: title, using: doctor) }
    }

    private func openInSteam(_ row: WorkshopPasteQueueModel.Row) {
        guard let url = row.steamURL else { return }
        NSWorkspace.shared.open(url)
    }

    @MainActor
    private func copyDiagnostic(for rowID: UUID) {
        guard let payload = model.diagnosticPayload(for: rowID) else { return }
        if payload.copyToPasteboard() {
            withAnimation(.easeOut(duration: 0.18)) { toastVisible = true }
        }
    }

    private func summaryString(_ summary: WorkshopPasteQueueModel.IngestionSummary) -> String {
        var fragments: [String] = []
        if summary.added > 0 { fragments.append("\(summary.added) added") }
        if summary.duplicates > 0 { fragments.append("\(summary.duplicates) duplicate") }
        if summary.invalid > 0 { fragments.append("\(summary.invalid) invalid") }
        return fragments.joined(separator: " · ")
    }
}
#endif
