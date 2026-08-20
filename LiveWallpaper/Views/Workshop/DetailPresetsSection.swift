#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Presets published for one wallpaper, listed inside its Workshop detail page.
///
/// Steam has no "is a preset" flag we can query — a preset is only identifiable
/// once its `project.json` has been unpacked. What Steam does offer is
/// `child_publishedfileid` ("Find all items that reference the given item"),
/// and a preset references the wallpaper it restyles. So this lists *referencing
/// items* and lets the import path make the final call: whatever turns out to be
/// a preset registers as one, anything else lands in the library as a wallpaper.
/// Nothing is discarded on a wrong guess.
struct DetailPresetsSection: View {
    /// Published file id of the wallpaper whose presets these are. Taken as a
    /// plain id rather than a `WorkshopQueryItem` so the installed-library
    /// inspector, which only has a history entry, can show the same section.
    let wallpaperID: UInt64
    let communityURL: URL
    let doctor: SteamCMDDoctorService

    @Environment(WorkshopServices.self) private var services
    @State private var state: LoadState = .idle
    @State private var searchText = ""
    @State private var isExpanded = false
    /// Steam's `total` for the reference query. We fetch a single 50-item page,
    /// so this can exceed the loaded count — that's the truncation signal.
    @State private var totalAvailable: Int?
    /// Which wallpaper `state` describes. `.task(id:)` re-runs on a new id but
    /// `@State` survives, so without this the early-return below kept showing
    /// the previous wallpaper's presets after switching items.
    @State private var loadedFor: UInt64?

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([WorkshopQueryItem])
        case failed(WorkshopQueryError)
    }

    /// Below this the filter field costs more room than it saves.
    private static let searchThreshold = 5
    /// A popular wallpaper can have dozens of presets, and the inspector is a
    /// narrow column shared with the description and tags.
    private static let collapsedLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            header

            switch state {
            case .idle, .loading:
                loadingRows
            case .failed(let error):
                failureRow(error)
            case .loaded(let presets):
                if presets.isEmpty {
                    emptyRow
                } else {
                    loadedList(presets)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: wallpaperID) { await load() }
    }

    @ViewBuilder
    private func loadedList(_ presets: [WorkshopQueryItem]) -> some View {
        let matches = filtered(presets)
        let shown = isExpanded ? matches : Array(matches.prefix(Self.collapsedLimit))
        let hidden = matches.count - shown.count

        if presets.count >= Self.searchThreshold {
            searchField
        }
        if matches.isEmpty {
            noMatchesRow
        } else {
            ForEach(shown) { preset in
                WorkshopPresetRow(preset: preset, doctor: doctor)
                if preset.id != shown.last?.id {
                    Divider()
                }
            }
            if hidden > 0 {
                Button("Show \(hidden) more") { isExpanded = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            } else if isExpanded, matches.count > Self.collapsedLimit {
                Button("Show fewer") { isExpanded = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
        }
        if totalCount(loaded: presets.count) > presets.count {
            Text("Showing the top \(presets.count) of \(totalCount(loaded: presets.count)) presets.", bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        communityFallbackLink
    }

    /// Header/truncation count: Steam's total when known, never below what we
    /// actually loaded.
    private func totalCount(loaded: Int) -> Int {
        max(totalAvailable ?? loaded, loaded)
    }

    private var header: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Text("Presets", bundle: .main)
                .font(DesignTokens.Typography.bodyEmphasized)
            if case .loaded(let presets) = state, !presets.isEmpty {
                Text(verbatim: "\(totalCount(loaded: presets.count))")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            InfoTooltipButton(
                text: "Presets are settings other people saved for this wallpaper. Downloading one adds it to the Preset menu in this wallpaper's scene settings — it does not add another wallpaper."
            )
            Spacer(minLength: 0)
        }
    }

    private var loadingRows: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: DesignTokens.Spacing.sm) {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                        .fill(DesignTokens.Colors.surfaceRaised)
                        .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                        RoundedRectangle(cornerRadius: 3).fill(DesignTokens.Colors.surfaceRaised)
                            .frame(width: 120, height: 10)
                        RoundedRectangle(cornerRadius: 3).fill(DesignTokens.Colors.surfaceRaised)
                            .frame(width: 72, height: 9)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel(Text("Loading presets"))
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("No presets have been published for this wallpaper.", bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            communityFallbackLink
        }
    }

    private var noMatchesRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("No presets match your search.", bundle: .main)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            Button("Clear") { searchText = "" }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func failureRow(_ error: WorkshopQueryError) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            if error == .missingAPIKey {
                // Not a failure worth an alarm icon: browsing works without a
                // key on the paste path, so this is a capability notice.
                Text("Add your Steam Web API key to see presets for this wallpaper.", bundle: .main)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label {
                    Text("Couldn't load presets.", bundle: .main)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.warning)
                }
                .font(DesignTokens.Typography.caption)

                Button("Retry") { Task { await load(force: true) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: DesignTokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            // Local filtering only: the whole candidate set arrived in one
            // request, and re-querying per keystroke would burn the shared
            // Steam rate limit that the rest of Workshop browsing depends on.
            TextField("Filter presets", text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.caption)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                .fill(DesignTokens.Colors.surfaceRaised.opacity(0.72))
        )
    }

    /// Always offered, because `child_publishedfileid` only finds presets whose
    /// dependency Steam actually indexed — an empty list is not proof that none
    /// exist.
    private var communityFallbackLink: some View {
        Button {
            NSWorkspace.shared.open(communityURL)
        } label: {
            Label("Look for more on Steam", systemImage: "arrow.up.right.square")
                .font(DesignTokens.Typography.caption)
        }
        .buttonStyle(.link)
    }

    private func filtered(_ presets: [WorkshopQueryItem]) -> [WorkshopQueryItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return presets }
        return presets.filter {
            $0.title.localizedCaseInsensitiveContains(needle)
                || ($0.creatorPersonaName?.localizedCaseInsensitiveContains(needle) ?? false)
        }
    }

    private func load(force: Bool = false) async {
        if loadedFor == wallpaperID, !force, case .loaded = state { return }
        // Retry spawns an unstructured Task, which does not die with the view
        // identity the way `.task(id:)` does. Without this, retrying on item A
        // and then switching to B publishes A's presets under B.
        let requested = wallpaperID
        // A filter typed for the previous wallpaper would silently hide the new
        // list, and a collapsed/expanded state from a 30-preset item makes no
        // sense on a 2-preset one.
        searchText = ""
        isExpanded = false
        state = .loading
        totalAvailable = nil
        do {
            let page = try await services.queryService.fetch(
                WorkshopQueryRequest(
                    sort: .mostPopular,
                    numPerPage: 50,
                    childPublishedFileID: requested
                )
            )
            guard !Task.isCancelled, requested == wallpaperID else { return }
            // The wallpaper itself can come back in its own reference list.
            let presets = page.items.filter { $0.id != requested }
            state = .loaded(presets)
            // Deduct whatever we filtered out locally so the header total
            // matches what the list could ever show.
            totalAvailable = page.totalAvailable.map { max(0, $0 - (page.items.count - presets.count)) }
            loadedFor = requested
        } catch let error as WorkshopQueryError {
            guard error != .cancelled, !Task.isCancelled, requested == wallpaperID else { return }
            state = .failed(error)
            loadedFor = requested
        } catch {
            guard !Task.isCancelled, requested == wallpaperID else { return }
            state = .failed(.responseParseFailure)
            loadedFor = requested
        }
    }
}

/// One preset row: preview, title, author, and a download control that says what
/// downloading will actually do.
private struct WorkshopPresetRow: View {
    let preset: WorkshopQueryItem
    let doctor: SteamCMDDoctorService

    private var downloads: WorkshopDownloadCoordinator { .shared }
    private var phase: WorkshopDownloadCoordinator.DownloadPhase {
        downloads.phase(for: preset.id)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Group {
                if let url = preset.previewImageURL {
                    WorkshopPreviewImage(url: url)
                } else {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                        .fill(DesignTokens.Colors.surfaceRaised)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous))

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(preset.title)
                    .font(DesignTokens.Typography.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let author = preset.creatorPersonaName {
                    Text(author)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DesignTokens.Spacing.xs)

            control
        }
        .padding(.vertical, DesignTokens.Spacing.xxs)
    }

    @ViewBuilder
    private var control: some View {
        switch phase {
        case .downloading, .importing:
            ProgressView().controlSize(.small)
        case .succeededAsPreset:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(DesignTokens.Colors.Status.active)
                .help(Text("Added to this wallpaper's presets"))
                .accessibilityLabel(Text("Added to this wallpaper's presets"))
        case .succeeded:
            // Not a preset after all — it imported as its own wallpaper. Saying
            // "added to presets" here would send the user looking in the wrong
            // place.
            Image(systemName: "photo.fill")
                .foregroundStyle(.secondary)
                .help(Text("Turned out to be a wallpaper; it's in your library"))
                .accessibilityLabel(Text("Turned out to be a wallpaper; it's in your library"))
        case .idle, .failed:
            Button {
                downloads.download(itemID: preset.id, title: preset.title, using: doctor)
            } label: {
                Image(systemName: phase == .idle ? "arrow.down.circle" : "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(!doctor.hasBoundBinary)
            .help(doctor.hasBoundBinary
                  ? Text("Download this preset")
                  : Text("Set up SteamCMD first"))
            .accessibilityLabel(Text("Download this preset"))
        }
    }
}
#endif
