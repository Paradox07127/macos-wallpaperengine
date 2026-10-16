import AppKit
import LiveWallpaperCore
import SwiftUI

@available(macOS 26.0, *)
struct SystemWallpaperAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WallpaperExportService.self) private var service

    @State private var store = BookmarkStore.shared
    @State private var selection: Set<SystemWallpaperCandidate.ID> = []
    @State private var isPublishing = false
    @State private var failures: [String] = []
    @State private var isClosed = false
    @State private var preparationOptions = SystemWallpaperPreparationOptions()
    @State private var resolutionIndex = 1
    private let resolutions = [CGSize(width: 1280, height: 720), CGSize(width: 1920, height: 1080),
                               CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)]

    private var candidates: [SystemWallpaperCandidate] {
        SystemWallpaperCandidate.all(bookmarks: store.bookmarks, service: service)
    }

    private func hasSelection(of type: WallpaperType) -> Bool {
        candidates.contains { selection.contains($0.id) && $0.wallpaperType == type }
    }

    private var subtitle: LocalizedStringKey {
        #if LITE_BUILD
        "macOS saves a video copy that can play with Loomscreen closed."
        #else
        "Videos and live scenes can play with Loomscreen closed. Web wallpapers are recorded as video copies."
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            SteamSheetHeader(
                icon: "macwindow.on.rectangle",
                title: "Add to System Wallpaper",
                iconTint: .accentColor,
                subtitle: subtitle
            )
            .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            .padding(.top, DesignTokens.Settings.formVerticalMargin)

            chooseFilesRow
                .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                .padding(.vertical, DesignTokens.Spacing.md)

            if hasSelection(of: .scene) || hasSelection(of: .html) {
                preparationSettings
                    .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
            }

            body(for: candidates)
            if !failures.isEmpty {
                Text(verbatim: failures.joined(separator: "\n"))
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(DesignTokens.Colors.Status.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                    .padding(.vertical, DesignTokens.Spacing.sm)
            }

            if isPublishing {
                VStack {
                    if let progress = service.preparationProgress {
                        ProgressView(value: progress)
                        Button("Cancel Preparation") { service.cancelPreparation() }
                    }
                    Text("Preparation continues after you close this window. Check System Wallpaper for the result.")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
            }
            SheetFooterBar(
                primaryTitle: "Add",
                primaryAction: publishSelection,
                primaryDisabled: selection.isEmpty || isPublishing,
                cancelTitle: isPublishing ? "Close" : "Cancel",
                cancelAction: { isClosed = true; dismiss() }
            )
        }
        .frame(width: 620, height: 680)
        .background(DesignTokens.Colors.pageBackground)
    }

    @ViewBuilder
    private func body(for candidates: [SystemWallpaperCandidate]) -> some View {
        if candidates.isEmpty {
            IllustratedEmptyState(
                symbol: "film.stack",
                title: "No saved wallpapers"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                // Not the window's tile-size setting: at this sheet's fixed 620 pt,
                // `.large` leaves one column.
                LibraryGalleryGrid(size: .small, aspect: .wide) {
                    ForEach(candidates) { candidate in
                        SystemWallpaperCandidateTile(
                            candidate: candidate,
                            isSelected: selection.contains(candidate.id),
                            onToggle: { toggle(candidate) }
                        )
                    }
                }
                .libraryGridPadding()
            }
        }
    }

    private var preparationSettings: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            #if !LITE_BUILD
            if hasSelection(of: .scene) {
                Picker("Scenes", selection: $preparationOptions.sceneMode) {
                    Text("Live — keeps clocks and calendars accurate").tag(SystemWallpaperPreparationOptions.SceneMode.live)
                    Text("Video copy — records the current appearance").tag(SystemWallpaperPreparationOptions.SceneMode.videoCopy)
                }
            }
            #endif
            HStack {
                Picker("Resolution", selection: $resolutionIndex) {
                    ForEach(resolutions.indices, id: \.self) { index in
                        Text("\(Int(resolutions[index].width)) × \(Int(resolutions[index].height)) px").tag(index)
                    }
                }
                .onChange(of: resolutionIndex) { _, index in preparationOptions.size = resolutions[index] }
                if hasSelection(of: .html) || preparationOptions.sceneMode == .videoCopy {
                    Picker("Loop length", selection: $preparationOptions.duration) {
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("60 seconds").tag(60.0)
                    }
                }
                Picker("Frame rate", selection: $preparationOptions.framesPerSecond) {
                    Text("15 FPS").tag(15)
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                }
            }
            if hasSelection(of: .html) {
                Toggle("Web wallpaper contains a clock, calendar or live data", isOn: $preparationOptions.containsLiveData)
            }
            Text("Video copies freeze live information. Web recording opens a preview and may ask for screen recording access.")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(isPublishing)
    }

    private var chooseFilesRow: some View {
        Button {
            SystemWallpaperVideoImport.present(publishingInto: service)
            dismiss()
        } label: {
            Label("Choose Files", systemImage: "folder.badge.plus")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isPublishing)
    }

    private func toggle(_ candidate: SystemWallpaperCandidate) {
        if selection.contains(candidate.id) {
            selection.remove(candidate.id)
        } else {
            selection.insert(candidate.id)
        }
    }

    /// Accumulate per-item errors because later successes clear the service's `lastError`.
    private func publishSelection() {
        let chosen = candidates.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        isPublishing = true
        failures = []
        Task { @MainActor in
            var collected: [String] = []
            let generation = service.clearGeneration
            let cancellationGeneration = service.preparationCancellationGeneration
            for candidate in chosen {
                guard service.clearGeneration == generation,
                      service.preparationCancellationGeneration == cancellationGeneration else { break }
                do {
                    try await candidate.publish(using: service, options: preparationOptions)
                    selection.remove(candidate.id)
                } catch {
                    if service.preparationCancellationGeneration != cancellationGeneration {
                        break
                    }
                    collected.append("\(candidate.title): \(error.localizedDescription)")
                }
            }
            isPublishing = false
            failures = collected
            service.reportPublishFailures(collected)
            if collected.isEmpty, !isClosed {
                dismiss()
            }
        }
    }
}
