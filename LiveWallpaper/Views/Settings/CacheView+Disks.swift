#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    private func diskColor(_ kind: AppStorageLocation.Kind) -> Color {
        switch kind {
        case .video, .configuration: DesignTokens.Colors.accent
        case .query, .shaders, .temporary: DesignTokens.Colors.LibraryTint.schemes
        case .previews, .diagnostics: DesignTokens.Colors.Gauge.medium
        case .audio, .webData: DesignTokens.Colors.LibraryTint.aerials
        case .webCache, .covers, .legacyScenes: DesignTokens.Colors.Gauge.low
        case .preferences, .systemMetadata: DesignTokens.Colors.LibraryTint.systemWallpaper
        case .logs: DesignTokens.Colors.rating
        case .support: DesignTokens.Colors.accent.opacity(0.6)
        case .systemCaches, .steamTools, .steamProfiles, .credentials: DesignTokens.Colors.textSecondary
        case .application: DesignTokens.Colors.LibraryTint.systemWallpaper
        case .localWallpapers: DesignTokens.Colors.Gauge.low
        }
    }

    private var storageDiskItems: [StorageDiskItem] {
        var items: [StorageDiskItem] = [
            StorageDiskItem(
                id: "wallpapers",
                title: "Wallpapers",
                bytes: wallpaperBytes,
                color: DesignTokens.Colors.Gauge.low,
                searchTitles: ["Workshop Wallpapers", "Local Wallpaper Files", "Wallpaper Locations", "Linked Original Files", "Legacy Scene Files"],
                icon: "photo.on.rectangle.angled",
                url: inventory?.projectsRootURL,
                scopeRootURL: inventory?.projectsScopeRootURL,
                canRevealInFinder: inventory?.projectsRootURL != nil || !linkedSources.isEmpty || storageMeasurements.contains { $0.location.kind == .legacyScenes && $0.bytes > 0 },
                canClear: false,
                status: StorageDiskItem.summaryStatus(
                    inventoryIncomplete: inventory?.isIncomplete == true,
                    componentStatuses: storageMeasurements.filter { [.localWallpapers, .legacyScenes].contains($0.location.kind) }.map(\.status),
                    unresolvedSources: unresolvedSources
                ),
                detail: "Steam downloads, local imports and linked Apple Aerials. Each location is counted once. Choose a location to reveal its files in Finder."
            ),
            StorageDiskItem(
                id: "engine",
                title: "Engine Assets",
                bytes: engineAssetBytes,
                color: DesignTokens.Colors.accent,
                searchTitles: ["Engine Assets"],
                icon: "shippingbox",
                url: inventory?.engineAssetsURL,
                scopeRootURL: inventory?.engineAssetsScopeRootURL,
                canRevealInFinder: inventory?.engineAssetsURL != nil,
                canClear: false,
                status: inventory?.isIncomplete == true ? .partial : .complete,
                detail: "Shared scene materials, models, and shaders. Required by scenes that reference these files."
            ),
        ]
        if #available(macOS 26.0, *) {
            items.append(
                StorageDiskItem(
                    id: "systemWallpaper",
                    title: "System Wallpaper",
                    bytes: systemWallpaperBytes,
                    color: DesignTokens.Colors.LibraryTint.systemWallpaper,
                    searchTitles: ["System Wallpaper"],
                    icon: "display",
                    url: exportService.videosDirectory,
                    canRevealInFinder: true,
                    canClear: false,
                    status: .complete,
                    detail: "Video copies used by macOS. Remove videos from System Wallpaper to free space."
                )
            )
        }
        let wallpaperIDs = Set(storageMeasurements.filter { [.localWallpapers, .legacyScenes].contains($0.location.kind) }.map(\.id))
        let nonCache = storageMeasurements.filter { !$0.location.kind.isCache && !wallpaperIDs.contains($0.id) }.map { measurement in
            StorageDiskItem(
                id: measurement.id,
                title: measurement.location.kind.title,
                bytes: measurement.bytes,
                color: diskColor(measurement.location.kind),
                searchTitles: [measurement.location.kind.title],
                icon: measurement.location.kind.symbol,
                url: measurement.location.url,
                canRevealInFinder: measurement.location.kind.canRevealInFinder,
                canClear: false,
                status: measurement.status,
                detail: measurement.location.kind.detail,
                measurement: measurement
            )
        }
        return items + nonCache
    }

    private var cacheDiskItems: [StorageDiskItem] {
        storageMeasurements.filter(\.location.kind.isCache).map { measurement in
            StorageDiskItem(
                id: measurement.id,
                title: measurement.location.kind.title,
                bytes: measurement.bytes,
                color: diskColor(measurement.location.kind),
                searchTitles: [measurement.location.kind.title],
                icon: measurement.location.kind.symbol,
                url: measurement.location.url,
                canRevealInFinder: measurement.location.kind.canRevealInFinder,
                canClear: measurement.location.kind.canClear,
                status: measurement.status,
                detail: measurement.location.kind.detail,
                measurement: measurement
            )
        }
    }

    var storageSection: some View {
        // Grouped macOS forms ignore listRowBackground; a header carries no row background.
        Section {} header: {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack {
                    SettingsSearchSectionHeader("Storage", anchor: .storageDashboard)
                    Spacer()
                    Button {
                        exportService.refresh()
                        Task { await refreshStats() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(Text("Refresh"))
                    .accessibilityLabel(Text("Refresh"))
                    .disabled(isLoading || isClearing)
                }
                StorageRingsCard(
                    rings: [
                        StorageRingSpec(id: "storage", title: "Storage", items: storageDiskItems),
                        StorageRingSpec(id: "caches", title: "Caches", items: cacheDiskItems),
                    ],
                    isLoading: isLoading,
                    formatBytes: formattedDiskBytes,
                    hoveredItemID: $hoveredItemID,
                    selectedItemID: $selectedItemID
                )
                storageItemsCard
                cacheItemsCard
            }
        }
    }

    private var storageItemsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text("Storage")
                    .font(DesignTokens.Typography.sectionTitle)
                    .padding(.bottom, DesignTokens.Spacing.xs)

                // Before the first measurement every row reads 0 bytes; hiding them then would empty the card.
                let items = isLoading ? storageDiskItems : StorageDiskItem.listed(storageDiskItems)
                let total = items.reduce(0) { $0 + $1.bytes }
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                    }
                    storageItemRow(item: item, total: total)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var cacheItemsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack {
                    Text("Caches")
                        .font(DesignTokens.Typography.sectionTitle)
                    Spacer()
                    Text("Memory Caches").font(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                        .settingsSearchRow("Memory Caches")
                    StorageInfoButton {
                        infoNote("Decoded images, library thumbnails, scene textures, animation frames, compiled Metal pipelines and recent query results live in memory. They do not count toward disk storage and are released by their owners or when Loomscreen quits.")
                    }
                    if isClearing {
                        ProgressView().controlSize(.small)
                    }
                    Button("Clear All Caches", role: .destructive) { confirmClearAllCaches() }
                        .buttonStyle(.borderless).destructiveControlTint()
                        .disabled(isLoading || isClearing || clearableBytes == 0)
                }
                .padding(.bottom, DesignTokens.Spacing.xs)
                if let cleared = lastStorageFreedBytes {
                    Group {
                        if let freed = cleared {
                            Text("Freed \(Int64(clamping: freed), format: .byteCount(style: .file)).")
                        } else {
                            Text("Freed space could not be measured.")
                        }
                    }
                    .font(DesignTokens.Typography.caption).foregroundStyle(DesignTokens.Colors.textSecondary)
                }

                ForEach(Array((isLoading ? cacheDiskItems : StorageDiskItem.listed(cacheDiskItems)).enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                    }
                    storageItemRow(item: item, total: totalBytes, showsClearSlot: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .settingsSearchAnchorTarget(.storageCaches)
    }

    private func storageItemRow(item: StorageDiskItem, total: UInt64, showsClearSlot: Bool = false) -> some View {
        let isHovered = hoveredItemID == item.id
        let isSelected = selectedItemID == item.id

        return StorageSearchTitleReader(item: item) { searchTitle in
            SettingRow(
                icon: item.icon,
                iconColor: item.color,
                title: searchTitle,
                valueSubtitle: displayPath(for: item),
                titleBadge: statusBadge(for: item.status, canReveal: item.canRevealInFinder)
            ) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(verbatim: shareText(bytes: item.bytes, total: total))
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                        .monospacedDigit()
                        .frame(minWidth: 42, alignment: .trailing)

                    Text(verbatim: (item.status == .partial ? "≥ " : "") + formattedDiskBytes(item.bytes))
                        .font(DesignTokens.Typography.metric)
                        .foregroundStyle(DesignTokens.Colors.textPrimary)
                        .monospacedDigit()
                        .frame(minWidth: 64, alignment: .trailing)

                    Group {
                        if item.id == "wallpapers" {
                            wallpaperLocationMenu
                        } else if item.canRevealInFinder, let url = item.url {
                            Button {
                                openFolder(url, scopeRoot: item.scopeRootURL)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help(Text("Open Folder"))
                            .accessibilityLabel(Text("Open Folder"))
                            .disabled(item.status == .missing || item.status == .unavailable)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: Self.actionSlotWidth)

                    if showsClearSlot {
                        Group {
                            if item.canClear, let measurement = item.measurement {
                                Button(role: .destructive) {
                                    pendingCache = measurement
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .destructiveControlTint()
                                .help(Text("Clear Cache"))
                                .accessibilityLabel(Text("Clear Cache") + Text(verbatim: " · ") + Text(item.title))
                                .disabled(isLoading || isClearing || item.bytes == 0)
                            } else {
                                Color.clear
                            }
                        }
                        .frame(width: Self.actionSlotWidth)
                    }

                    Group {
                        if item.id == "wallpapers" {
                            StorageInfoButton { linkedSourcesPopover }
                        } else if let detail = item.detail {
                            StorageInfoButton {
                                itemDetailPopover(item, detail: detail)
                            }
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: Self.actionSlotWidth)
                }
            }
        }
        .help(item.detail.map { Text($0) } ?? Text(item.title))
        .padding(.horizontal, DesignTokens.Spacing.xs)
        .background {
            if isHovered || isSelected {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.sm, style: .continuous)
                    .fill(DesignTokens.Colors.accent.opacity(
                        isSelected ? DesignTokens.Opacity.selectedFill : DesignTokens.Opacity.hoverFill
                    ))
            }
        }
        .contentShape(Rectangle())
        .settledHover { hov in
            hoveredItemID = hov ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
        .onTapGesture {
            selectedItemID = (selectedItemID == item.id ? nil : item.id)
        }
        // `.activate` keeps clicks from moving focus; the row only joins the Tab loop under keyboard navigation.
        .focusable(interactions: .activate)
        .onKeyPress(keys: [.space, .return]) { _ in
            selectedItemID = (selectedItemID == item.id ? nil : item.id)
            return .handled
        }
        // A container element, so the trait and action stay off the row's Finder/clear/info buttons.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            selectedItemID = (selectedItemID == item.id ? nil : item.id)
        }
    }

    private static let actionSlotWidth: CGFloat = 18

    private func displayPath(for item: StorageDiskItem) -> String? {
        guard let url = item.url else { return nil }
        let rawPath = url.path(percentEncoded: false)
        // NSHomeDirectory() is the sandbox container; abbreviate only the real home.
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return StorageDiskItem.abbreviatingHome(rawPath, home: home)
    }

    private func shareText(bytes: UInt64, total: UInt64) -> String {
        let fraction = total > 0 ? Double(bytes) / Double(total) : 0
        return fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    private func statusBadge(for status: AppStorageMeasurement.Status, canReveal: Bool) -> SettingRowTitleBadge? {
        switch status {
        case .partial:
            return SettingRowTitleBadge(
                systemImage: "clock.arrow.circlepath",
                tint: DesignTokens.Colors.Status.caution,
                accessibilityLabel: Text("At least · scan incomplete")
            )
        case .unavailable:
            return SettingRowTitleBadge(
                systemImage: "exclamationmark.circle",
                tint: DesignTokens.Colors.Status.warning,
                accessibilityLabel: Text("Access unavailable")
            )
        case .missing:
            return SettingRowTitleBadge(
                systemImage: "minus.circle",
                tint: DesignTokens.Colors.textTertiary,
                accessibilityLabel: Text("No files yet")
            )
        case .complete:
            if !canReveal {
                return SettingRowTitleBadge(
                    systemImage: "lock",
                    tint: DesignTokens.Colors.textTertiary,
                    accessibilityLabel: Text("Read Only")
                )
            }
            return nil
        }
    }

    private func itemDetailPopover(_ item: StorageDiskItem, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack {
                Label {
                    Text(item.title)
                        .font(DesignTokens.Typography.bodyEmphasized)
                } icon: {
                    Image(systemName: item.icon)
                        .foregroundStyle(item.color)
                }
                Spacer()
                Text(verbatim: formattedDiskBytes(item.bytes))
                    .font(DesignTokens.Typography.metricEmphasized)
            }

            Text(detail)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = item.url {
                Divider()
                Text(verbatim: url.path(percentEncoded: false))
                    .font(DesignTokens.Typography.codeCaption)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: 300, alignment: .leading)
            }

            if item.canRevealInFinder || item.canClear {
                Divider()
                HStack {
                    if item.canRevealInFinder, let url = item.url {
                        Button {
                            openFolder(url, scopeRoot: item.scopeRootURL)
                        } label: {
                            Label("Open Folder", systemImage: "folder")
                        }
                        .buttonStyle(.borderless)
                        .disabled(item.status == .missing || item.status == .unavailable)
                    }
                    Spacer()
                    if item.canClear, let measurement = item.measurement {
                        Button("Clear Cache", role: .destructive) {
                            pendingCache = measurement
                        }
                        .buttonStyle(.borderless)
                        .destructiveControlTint()
                        .disabled(isLoading || isClearing || item.bytes == 0)
                    }
                }
            }
        }
        .frame(width: 280)
    }

    private func formattedDiskBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    private var linkedSourcesPopover: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            infoNote("Steam downloads, local imports and linked Apple Aerials. Each location is counted once. Choose a location to reveal its files in Finder.")
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    if let url = inventory?.projectsRootURL {
                        Button { openFolder(url, scopeRoot: inventory?.projectsScopeRootURL) } label: {
                            Text("Workshop Wallpapers") + Text(verbatim: " · " + formattedDiskBytes(inventory?.projectsTotalBytes ?? 0))
                        }
                        .buttonStyle(.borderless)
                    }
                    ForEach(linkedSources) { source in
                        Button {
                            guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(source.bookmark, target: .transient) else { return }
                            SecurityScopedBookmarkResolver.withScopedAccess(resolved.url) { _ in
                                NSWorkspace.shared.activateFileViewerSelecting([resolved.url])
                            }
                        } label: {
                            let bytes = storageMeasurements.first { $0.location.kind == .localWallpapers && $0.location.url == source.url }?.bytes ?? 0
                            Label { Text(verbatim: source.url.lastPathComponent + " · " + formattedDiskBytes(bytes)) } icon: { Image(systemName: "folder") }
                        }
                        .buttonStyle(.borderless).help(source.url.path(percentEncoded: false))
                    }
                }
            }
            .frame(maxHeight: 180)
            if unresolvedSources > 0 {
                infoNote("Some source bookmarks could not be resolved. Reconnect them in the Wallpaper Library.")
            }
        }
        .frame(width: 300)
    }

    private var wallpaperLocationMenu: some View {
        Menu {
            if let url = inventory?.projectsRootURL {
                Menu {
                    Button("Open Folder") { openFolder(url, scopeRoot: inventory?.projectsScopeRootURL) }
                    Divider()
                    ForEach(inventory?.projects ?? []) { project in
                        Button { openFolder(project.folderURL, scopeRoot: inventory?.projectsScopeRootURL) } label: {
                            Text(verbatim: project.workshopID + " · " + formattedDiskBytes(project.sizeBytes))
                        }
                    }
                } label: {
                    Text("Workshop Wallpapers") + Text(verbatim: " · " + formattedDiskBytes(inventory?.projectsTotalBytes ?? 0))
                }
            }
            ForEach(linkedSources) { source in
                let measurement = storageMeasurements.first { $0.location.kind == .localWallpapers && $0.location.url == source.url }
                Button {
                    guard case let .success(resolved) = SecurityScopedBookmarkResolver.shared.resolve(source.bookmark, target: .transient) else { return }
                    openFolder(resolved.url, scopeRoot: resolved.url)
                } label: {
                    Text(verbatim: source.url.path(percentEncoded: false) + " · " + formattedDiskBytes(measurement?.bytes ?? 0))
                }
                .disabled(measurement?.status == .missing || measurement?.status == .unavailable)
            }
            ForEach(storageMeasurements.filter { $0.location.kind == .legacyScenes && $0.bytes > 0 }) { measurement in
                Button { openFolder(measurement.location.url, scopeRoot: nil) } label: {
                    Text(measurement.location.kind.title) + Text(verbatim: " · " + formattedDiskBytes(measurement.bytes))
                }
            }
        } label: {
            Image(systemName: "folder")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(isLoading || (inventory?.projectsRootURL == nil && linkedSources.isEmpty && !storageMeasurements.contains { $0.location.kind == .legacyScenes && $0.bytes > 0 }))
        .help(Text("Show Wallpaper Files"))
        .accessibilityLabel(Text("Show Wallpaper Files"))
    }
}
#endif
