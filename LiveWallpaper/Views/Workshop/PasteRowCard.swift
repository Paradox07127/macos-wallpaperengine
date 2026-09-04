#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct PasteRowCard: View {
    let row: WorkshopPasteQueueModel.QueueRow
    let onRetry: () -> Void
    let onRemove: () -> Void
    let onOpenInSteam: () -> Void
    let onCopyDiagnostic: () -> Void
    /// `nil` when this row has no usable id, or SteamCMD isn't ready to download.
    var onDownload: (() -> Void)?
    var downloadPhase: WorkshopDownloadCoordinator.DownloadPhase = .idle

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 8) {
                header
                if row.state == .ready, let metadata = row.metadata {
                    SteamWorkshopMetadataView(metadata: metadata)
                } else if row.state == .fetchingMetadata {
                    SkeletonLines()
                } else if let error = row.error {
                    WorkshopRowErrorStrip(error: error)
                }
                footerActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(DesignTokens.Spacing.cardInset)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
        }
        .shadow(
            color: .black.opacity(DesignTokens.Card.restShadowOpacity),
            radius: DesignTokens.Card.restShadowRadius,
            x: 0,
            y: DesignTokens.Card.restShadowYOffset
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Subviews

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
        ZStack {
            shape.fill(Color.secondary.opacity(0.12))
            if let url = row.metadata?.previewImageURL {
                WorkshopPreviewImage(url: url)
                    .accessibilityHidden(true)
            } else if row.state == .fetchingMetadata {
                ProgressView().controlSize(.small)
            } else if row.state == .invalidInput {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Colors.Status.caution)
            } else {
                Image(systemName: "cube.transparent")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 152, height: 86)
        .clipShape(shape)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: titleText)
                .font(DesignTokens.Typography.sectionTitle)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch row.state {
        case .ready:
            StatusChip(verbatim: String(localized: "Ready", bundle: .appLanguage, comment: "Workshop paste row status badge."), tint: DesignTokens.Colors.Status.active, systemImage: "checkmark.seal.fill")
        case .fetchingMetadata:
            StatusChip(verbatim: String(localized: "Fetching…", bundle: .appLanguage, comment: "Workshop paste row status badge."), tint: .blue, systemImage: "hourglass")
        case .invalidInput:
            StatusChip(verbatim: String(localized: "Invalid", bundle: .appLanguage, comment: "Workshop paste row status badge."), tint: DesignTokens.Colors.Status.caution, systemImage: "exclamationmark.triangle.fill")
        case .failed:
            StatusChip(verbatim: errorBadgeLabel, tint: DesignTokens.Colors.Status.danger, systemImage: "xmark.octagon.fill")
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        HStack(spacing: 8) {
            if row.steamURL != nil {
                Button(action: onOpenInSteam) {
                    Label("Open in Steam", systemImage: "arrow.up.forward.app")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.borderless)
            }

            if row.state == .failed, !isInvalidInputState {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.borderless)
            }

            downloadAction

            Spacer()

            if row.state == .failed || row.state == .invalidInput {
                Button(action: onCopyDiagnostic) {
                    Label("Copy diagnostic", systemImage: "doc.on.clipboard")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "xmark.circle")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(DesignTokens.Colors.Status.danger)
            .accessibilityLabel(Text("Remove from queue"))
        }
    }

    /// Downloading a pasted id is the one install path that needs no Steam Web
    /// API key — only a signed-in SteamCMD. The search tab needs the key.
    @ViewBuilder
    private var downloadAction: some View {
        if let onDownload {
            switch downloadPhase {
            case .downloading, .importing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(downloadPhase == .importing ? "Importing…" : "Downloading…")
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                }
            case .succeeded:
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.Status.active)
            case .succeededAsPreset:
                // A preset is not a wallpaper, and saying "Installed" here sends
                // the user looking for it in the library.
                Label("Preset added", systemImage: "checkmark.circle.fill")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.Status.active)
            case .failed(let reason):
                Button(action: onDownload) {
                    Label("Retry download", systemImage: "arrow.down.circle")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text(verbatim: reason))
            case .idle:
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(DesignTokens.Typography.body)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Derived strings

    private var titleText: String {
        if let metadata = row.metadata, !metadata.title.isEmpty {
            return metadata.title
        }
        if let id = row.publishedFileID {
            return String(
                localized: "Workshop item \(id)",
                bundle: .appLanguage, comment: "Workshop paste row title when only a published file ID is known."
            )
        }
        return row.originalInput
    }

    private var errorBadgeLabel: String {
        switch row.error {
        case .itemPrivate:
            return String(localized: "Private", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .itemBanned:
            return String(localized: "Banned", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .itemNotFound:
            return String(localized: "Not found", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .timeout, .networkUnreachable:
            return String(localized: "Network", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .rateLimited:
            return String(localized: "Rate limit", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .unauthorized:
            return String(localized: "Locked", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .http(let status):
            return String(localized: "HTTP \(status)", bundle: .appLanguage, comment: "Workshop paste error badge. Placeholder is HTTP status.")
        case .responseParseFailure, .schemaMismatch:
            return String(localized: "Bad payload", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .invalidInput:
            return String(localized: "Invalid", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .cancelled:
            return String(localized: "Cancelled", bundle: .appLanguage, comment: "Workshop paste error badge.")
        case .unknown, .none:
            return String(localized: "Failed", bundle: .appLanguage, comment: "Workshop paste error badge.")
        }
    }

    private var isInvalidInputState: Bool {
        if case .invalidInput = row.error { return true }
        return row.state == .invalidInput
    }

    private var accessibilityLabel: Text {
        switch row.state {
        case .ready:
            return Text("\(titleText), ready", comment: "Workshop paste row accessibility label. %@ is the workshop item title.")
        case .fetchingMetadata:
            return Text("\(titleText), fetching details", comment: "Workshop paste row accessibility label. %@ is the workshop item title.")
        case .invalidInput:
            return Text("\(titleText), invalid", comment: "Workshop paste row accessibility label. %@ is the original pasted input.")
        case .failed:
            return Text("\(titleText), failed: \(errorBadgeLabel)", comment: "Workshop paste row accessibility label. Placeholders are the item title and a short error label.")
        }
    }
}

// MARK: - Helper Views

private struct SkeletonLines: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<2, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 10)
                    .frame(maxWidth: index == 0 ? .infinity : 220, alignment: .leading)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

private struct SteamWorkshopMetadataView: View {
    let metadata: SteamWorkshopMetadata

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !metadata.shortDescription.isEmpty {
                Text(verbatim: metadata.shortDescription)
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let size = metadata.fileSizeBytes {
                    Label(WorkshopByteFormatter.string(size), systemImage: "doc")
                }
                if let updated = metadata.timeUpdated {
                    Label(WorkshopRelativeDateFormatter.string(updated), systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }
}

private struct WorkshopRowErrorStrip: View {
    let error: SteamWorkshopMetadataError

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .imageScale(.small)
            Text(verbatim: copy)
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))
    }

    private var tint: Color {
        switch error {
        case .itemBanned, .itemNotFound, .responseParseFailure, .schemaMismatch:
            return DesignTokens.Colors.Status.danger
        case .rateLimited:
            return DesignTokens.Colors.Status.warning
        case .invalidInput, .itemPrivate, .timeout, .networkUnreachable,
             .unauthorized, .http:
            return DesignTokens.Colors.Status.caution
        case .cancelled, .unknown:
            return .secondary
        }
    }

    private var icon: String {
        switch error {
        case .itemBanned, .itemNotFound, .responseParseFailure, .schemaMismatch:
            return "xmark.octagon.fill"
        case .invalidInput:
            return "exclamationmark.triangle.fill"
        case .itemPrivate:
            return "eye.slash"
        case .timeout, .networkUnreachable:
            return "wifi.exclamationmark"
        case .rateLimited:
            return "tortoise"
        case .unauthorized:
            return "lock.fill"
        case .http:
            return "network.slash"
        case .cancelled:
            return "slash.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var copy: String {
        switch error {
        case .invalidInput:
            return String(
                localized: "Not a valid Steam Workshop URL.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .itemPrivate:
            return String(
                localized: "This item is private or friends-only and can't be previewed here.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .itemBanned:
            return String(
                localized: "Steam has flagged this item as unavailable.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .itemNotFound:
            return String(
                localized: "Workshop item not found. It may have been removed.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .timeout, .networkUnreachable:
            return String(
                localized: "Couldn't reach Steam. Check your connection.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .rateLimited(let retry):
            if let retry {
                return String(
                    localized: "Steam is rate-limiting. Retrying in \(Int(retry))s.",
                    bundle: .appLanguage, comment: "Workshop paste error detail. Placeholder is seconds until retry."
                )
            }
            return String(
                localized: "Steam is rate-limiting. Retrying shortly.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .unauthorized:
            return String(
                localized: "Steam couldn't load this item's details. You can still open it in Steam.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .http(let status):
            return String(
                localized: "Steam couldn't load this item (HTTP \(status)).",
                bundle: .appLanguage, comment: "Workshop paste error detail. Placeholder is HTTP status."
            )
        case .responseParseFailure, .schemaMismatch:
            return String(
                localized: "Steam returned an unexpected response.",
                bundle: .appLanguage, comment: "Workshop paste error detail."
            )
        case .cancelled:
            return String(localized: "Cancelled", bundle: .appLanguage, comment: "Workshop paste request cancelled.")
        case .unknown(let detail):
            return detail.isEmpty
                ? String(localized: "Something went wrong.", bundle: .appLanguage, comment: "Generic workshop paste error.")
                : detail
        }
    }
}

// MARK: - Formatters

/// Shows a fallback icon when `WorkshopPreviewImageLoader` rejects the URL
/// (allow-list miss, wrong content-type, oversize, etc.).
/// Shared with the detail sheet's preset list; both show a small allow-listed
/// Workshop preview and must fail the same quiet way.
struct WorkshopPreviewImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var didFail = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if didFail {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            let loaded = await WorkshopPreviewImageLoader.shared.load(url)
            await MainActor.run {
                image = loaded
                didFail = (loaded == nil)
            }
        }
    }
}

enum WorkshopRelativeDateFormatter {
    static func string(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// Views and favorites put the magnitude suffix inside the number, so one
/// catalog key covers all three magnitudes.
enum WorkshopCountFormatter {
    static func compact(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", locale: .current, Double(count) / 1_000_000.0)
        }
        if count >= 1000 {
            return String(format: "%.1fK", locale: .current, Double(count) / 1000.0)
        }
        return count.formatted()
    }
}
#endif
