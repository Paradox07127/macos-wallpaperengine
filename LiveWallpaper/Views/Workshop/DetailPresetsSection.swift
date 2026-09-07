#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Presets published for one wallpaper, listed inside its Workshop detail page.
/// Steam offers `child_publishedfileid` ("find all items referencing the given
/// item"); a preset references the wallpaper it restyles and carries the
/// `Preset` tag, which is what `DetailPresetsQuery` keeps. The import path
/// still decides what a download really is (`succeededAsPreset` vs `succeeded`).
struct DetailPresetsSection: View {
    /// Published file id of the wallpaper whose presets these are. Taken as a
    /// plain id rather than a `WorkshopQueryItem` so the installed-library
    /// inspector, which only has a history entry, can show the same section.
    let wallpaperID: UInt64
    let communityURL: URL
    let doctor: SteamCMDDoctorService

    @Environment(WorkshopServices.self) private var services
    /// The grid card's spoiler setting, by its named key (`MatureContentSettings`).
    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blurMatureThumbnails = true
    @State private var model = DetailPresetsModel()
    @State private var searchText = ""
    @State private var isExpanded = false
    /// Ephemeral, like the grid card's: a new detail page blurs again.
    @State private var revealedIDs: Set<UInt64> = []
    @State private var pendingRevealID: UInt64?
    @State private var showingAgeConfirm = false

    private var state: DetailPresetsModel.LoadState {
        model.state
    }

    private var totalAvailable: Int? {
        model.totalAvailable
    }

    /// Adding or losing a key while the inspector is open must re-run the
    /// query, not wait for the next item.
    private var loadKey: DetailPresetsModel.LoadKey {
        .init(wallpaperID: wallpaperID, keyless: services.isKeyless)
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
            case .keyless:
                keylessRow
            case .loaded(let presets):
                if presets.isEmpty {
                    emptyRow
                } else {
                    loadedList(presets)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: loadKey) { await model.load(loadKey, services: services) }
        // A filter typed for the previous wallpaper would silently hide the new
        // list, and a collapsed/expanded state from a 30-preset item makes no
        // sense on a 2-preset one.
        .onChange(of: state) { _, state in
            guard state == .loading else { return }
            searchText = ""
            isExpanded = false
        }
        .alert("Show mature content?", isPresented: $showingAgeConfirm) {
            Button(role: .cancel) {} label: { Text("Cancel") }
            Button(role: .destructive) {
                MatureContentSettings.confirm()
                if let id = pendingRevealID {
                    revealedIDs.insert(id)
                }
            } label: {
                Text("I am 18 or older")
            }
        } message: {
            Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
        }
    }

    /// The grid card's spoiler rule, shared with the Required items rows.
    nonisolated static func blursThumbnail(for item: WorkshopQueryItem, blursMature: Bool) -> Bool {
        DetailRequiredItemsSection.blursThumbnail(tags: item.tags, blursMature: blursMature)
    }

    private func isBlurred(_ item: WorkshopQueryItem) -> Bool {
        Self.blursThumbnail(for: item, blursMature: blurMatureThumbnails) && !revealedIDs.contains(item.id)
    }

    /// Gated by the same one-time 18+ confirmation as the grid card.
    private func requestReveal(_ id: UInt64) {
        if MatureContentSettings.isConfirmed {
            revealedIDs.insert(id)
        } else {
            pendingRevealID = id
            showingAgeConfirm = true
        }
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
                WorkshopPresetRow(preset: preset, doctor: doctor, isBlurred: isBlurred(preset)) {
                    requestReveal(preset.id)
                }
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
            Text("Showing the top \(presets.count) of \(totalCount(loaded: presets.count)) presets.")
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
            Text("Presets")
                .font(DesignTokens.Typography.bodyEmphasized)
            if case .loaded(let presets) = state, !presets.isEmpty {
                Text(verbatim: "\(totalCount(loaded: presets.count))")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            InfoTooltipButton(
                text: "Downloaded presets appear in this wallpaper’s scene settings, without adding a wallpaper."
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
            Text("No presets have been published for this wallpaper.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            communityFallbackLink
        }
    }

    private var noMatchesRow: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Text("No presets match your search.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
            Button("Clear") { searchText = "" }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            Spacer(minLength: 0)
        }
    }

    /// The keyless page cannot list presets (`childpublishedfileid` returns
    /// nothing in its items section, measured 2026-09-07), so the section is
    /// one link to where Steam shows them.
    private var keylessRow: some View {
        Button {
            NSWorkspace.shared.open(communityURL)
        } label: {
            Label("View presets on Steam", systemImage: "arrow.up.right.square")
                .font(DesignTokens.Typography.caption)
        }
        .buttonStyle(.link)
    }

    private func failureRow(_ error: WorkshopQueryError) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label {
                Text("Couldn't load presets.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
            }
            .font(DesignTokens.Typography.caption)

            // The row named the operation but never the failure, so a
            // rate limit and an unreachable Steam offered the same Retry
            // with no way to tell which one would help.
            Text(verbatim: error.causeDescription)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Retry") { Task { await model.load(loadKey, services: services, force: true) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
}

/// The section's load state, kept off the view so the reuse rule is testable:
/// `.task(id:)` re-runs when the key changes, but `@State` survives it.
@MainActor
@Observable
final class DetailPresetsModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([WorkshopQueryItem])
        case failed(WorkshopQueryError)
        /// No usable Web API key: nothing to list, only Steam's page to link to.
        case keyless
    }

    struct LoadKey: Hashable {
        let wallpaperID: UInt64
        let keyless: Bool
    }

    private(set) var state: LoadState = .idle
    /// Steam's `total` for the reference query. We fetch a single 50-item page,
    /// so this can exceed the loaded count — that's the truncation signal.
    private(set) var totalAvailable: Int?
    /// Which key `state` describes: without this the early return in `load`
    /// kept showing the previous wallpaper's presets after switching items, and
    /// (keyed by id alone) kept the list after the key was lost or rejected.
    private var loadedFor: LoadKey?
    /// Retry spawns an unstructured Task, which does not die with the view
    /// identity the way `.task(id:)` does. Without this, retrying on item A
    /// and then switching to B publishes A's presets under B.
    private var requested: LoadKey?

    func load(_ key: LoadKey, services: WorkshopServices, force: Bool = false) async {
        if loadedFor == key, !force, case .loaded = state {
            return
        }
        requested = key
        state = .loading
        totalAvailable = nil
        do {
            let outcome = try await DetailPresetsQuery.load(wallpaperID: key.wallpaperID, services: services)
            guard !Task.isCancelled, requested == key else { return }
            switch outcome {
            case .keyless:
                state = .keyless
            case let .loaded(result):
                state = .loaded(result.presets)
                totalAvailable = result.totalAvailable
            }
            loadedFor = key
        } catch let error as WorkshopQueryError {
            guard error != .cancelled, !Task.isCancelled, requested == key else { return }
            // The key vanished between the gate and the fetch: same answer as
            // never having had one.
            state = error == .missingAPIKey ? .keyless : .failed(error)
            loadedFor = key
        } catch {
            guard !Task.isCancelled, requested == key else { return }
            state = .failed(.responseParseFailure)
            loadedFor = key
        }
    }
}

/// The query behind `DetailPresetsSection`, kept off the view so the Preset
/// filter and the keyless gate are testable without rendering it.
enum DetailPresetsQuery {
    struct Result: Equatable {
        let presets: [WorkshopQueryItem]
        /// Steam's total for the Preset-tagged reference query; can exceed
        /// `presets.count` (truncation signal).
        let totalAvailable: Int?
    }

    enum Outcome: Equatable {
        case keyless
        case loaded(Result)
    }

    /// `child_publishedfileid` answers "everything referencing this item" —
    /// collections and other wallpapers included, and the wallpaper itself can
    /// come back in its own list. Only the `Preset` tag says "restyles it".
    static func presets(in items: [WorkshopQueryItem], of wallpaperID: UInt64) -> [WorkshopQueryItem] {
        items.filter { item in
            item.id != wallpaperID
                && item.tags.contains { $0.caseInsensitiveCompare("Preset") == .orderedSame }
        }
    }

    /// The keyless page returns nothing for `childpublishedfileid` in its items
    /// section (measured 2026-09-07), so without a usable key there is no list
    /// to fetch — only Steam's own page to link to.
    @MainActor
    static func load(wallpaperID: UInt64, services: WorkshopServices) async throws -> Outcome {
        guard !services.isKeyless else { return .keyless }
        // `requiredtags` combines with `child_publishedfileid` server-side
        // (measured 2026-09-07: total 16701 → 16697, all 50 tagged Preset), so
        // a preset past the 50th reference is not lost and `total` counts
        // presets. `presets(in:of:)` stays as the safety net.
        let page = try await services.queryService.fetch(
            WorkshopQueryRequest(
                sort: .mostPopular, numPerPage: 50, requiredTags: ["Preset"], childPublishedFileID: wallpaperID
            )
        )
        return .loaded(Result(presets: presets(in: page.items, of: wallpaperID), totalAvailable: page.totalAvailable))
    }
}

/// One preset row: preview, title, author, and a download control that says what
/// downloading will actually do.
private struct WorkshopPresetRow: View {
    let preset: WorkshopQueryItem
    let doctor: SteamCMDDoctorService
    let isBlurred: Bool
    let onReveal: () -> Void

    private var downloads: WorkshopDownloadCoordinator { .shared }
    private var phase: WorkshopDownloadCoordinator.DownloadPhase {
        downloads.phase(for: preset.id)
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if isBlurred {
                Button(action: onReveal) {
                    RequiredItemThumbnail(url: preset.previewImageURL, isBlurred: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mature content hidden. Activate to reveal."))
            } else {
                RequiredItemThumbnail(url: preset.previewImageURL, isBlurred: false)
            }

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
                .help(Text("Wallpaper added to library"))
                .accessibilityLabel(Text("Wallpaper added to library"))
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
