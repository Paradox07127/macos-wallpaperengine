#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct PasteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SteamCMDDoctorService.self) private var doctor
    @State private var model = WorkshopPasteQueueModel()
    @State private var downloads = WorkshopDownloadCoordinator.shared
    @State private var toastVisible = false
    @FocusState private var textFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                SteamSheetHeader(
                    icon: "tray.and.arrow.down.fill",
                    title: "Add from Steam Workshop",
                    iconTint: .accentColor
                )
                pasteArea
                downloadReadinessBanner
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.top, DesignTokens.Settings.formVerticalMargin)
            .padding(.bottom, DesignTokens.Spacing.md)

            queueHeader
            queueArea

            // Queue actions commit immediately; Done closes without discarding them (W3-S3).
            SheetFooterBar(
                primaryTitle: "Done",
                primaryAction: { dismiss() }
            )
        }
        .frame(
            minWidth: SteamSheetWidth.dense,
            idealWidth: SteamSheetWidth.dense,
            maxWidth: 720
        )
        .fixedSize(horizontal: false, vertical: true)
        .background(DesignTokens.Colors.pageBackground)
        .overlay(alignment: .bottom) {
            ExportToast(isPresented: $toastVisible)
                .padding(.bottom, 22)
                .allowsHitTesting(false)
        }
        .onAppear { textFieldIsFocused = true }
        .onDisappear { model.removeAll() }
    }

    // MARK: - Queue header

    @ViewBuilder
    private var queueHeader: some View {
        if !model.rows.isEmpty {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("\(model.rows.count) queued")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: DesignTokens.Spacing.sm)

                if !downloadableRows.isEmpty {
                    Button {
                        for row in downloadableRows { downloadAction(for: row)?() }
                    } label: {
                        Label("Download all", systemImage: "arrow.down.circle.fill")
                            .font(DesignTokens.Typography.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Menu {
                    Button("Open all in Steam") { model.openAllInSteam() }
                    Divider()
                    Button("Clear queue", role: .destructive) { model.removeAll() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("Queue actions"))
            }
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.bottom, DesignTokens.Spacing.xs)
        }
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
                .accessibilityLabel(Text("Workshop URLs or item IDs"))
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.rawInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Queue area

    @ViewBuilder
    private var queueArea: some View {
        if !model.rows.isEmpty {
            queueList
        }
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: DesignTokens.Spacing.md) {
                ForEach(model.rows) { row in
                    PasteRowCard(
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
        .frame(minHeight: 200, idealHeight: 280, maxHeight: 520)
    }

    // MARK: - Download readiness

    /// Explains why row download actions are hidden until setup is ready.
    @ViewBuilder
    private var downloadReadinessBanner: some View {
        if let reason = doctor.downloadBlockerMessage {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                    .accessibilityHidden(true)
                Text(verbatim: reason)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                DesignTokens.Colors.Status.warning.opacity(0.10),
                in: RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
            )
        }
    }

    /// Rows that have an id and are not already downloading or installed.
    private var downloadableRows: [WorkshopPasteQueueModel.QueueRow] {
        guard doctor.isDownloadReady else { return [] }
        return model.rows.filter { row in
            guard let id = row.publishedFileID else { return false }
            return downloads.phase(for: id) == .idle
        }
    }

    // MARK: - Helpers

    /// `nil` hides the button: no id to download, or SteamCMD hasn't been set up
    /// and signed in, in which case the Workshop setup sheet is the way through.
    private func downloadAction(for row: WorkshopPasteQueueModel.QueueRow) -> (() -> Void)? {
        guard let itemID = row.publishedFileID, doctor.isDownloadReady else { return nil }
        let title = row.metadata?.title ?? String(itemID)
        return { downloads.download(itemID: itemID, title: title, using: doctor) }
    }

    private func openInSteam(_ row: WorkshopPasteQueueModel.QueueRow) {
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
        if summary.added > 0 {
            fragments.append(String(localized: "\(summary.added) added", bundle: .appLanguage, comment: "Paste queue ingestion summary fragment."))
        }
        if summary.duplicates > 0 {
            fragments.append(String(localized: "\(summary.duplicates) duplicate", bundle: .appLanguage, comment: "Paste queue ingestion summary fragment."))
        }
        if summary.invalid > 0 {
            fragments.append(String(localized: "\(summary.invalid) invalid", bundle: .appLanguage, comment: "Paste queue ingestion summary fragment."))
        }
        return fragments.joined(separator: " · ")
    }
}
#endif
