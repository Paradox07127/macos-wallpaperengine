#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

struct WorkshopInspectorContent: View {
    let item: WorkshopQueryItem
    let doctor: SteamCMDDoctorService
    /// nil disables the author link (plain author text).
    var onBrowseCreator: ((String, String?) -> Void)?
    /// nil → tags render as plain labels.
    var onSelectTag: ((String) -> Void)?
    /// Opens another item in this inspector (Required items rows); nil hides the section.
    var onOpenItem: ((UInt64) -> Void)?

    @Environment(\.openURL) private var openURL
    @Environment(ScreenManager.self) private var screenManager
    @Environment(WorkshopServices.self) private var services
    @State private var installedEntry: WPEHistoryEntry?

    /// Named constants, not literals: the grid card reads the same two keys
    /// through `MatureContentSettings`, and a typo here would silently give the
    /// detail view its own private spoiler setting.
    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blurMatureThumbnails = true
    /// One-time 18+ confirmation, shared with the grid card.
    @AppStorage(MatureContentSettings.confirmed, store: .appScoped()) private var matureConfirmed = false
    @State private var matureRevealed = false
    @State private var showingAgeConfirm = false
    @State private var showingApplyPopover = false
    @State private var descriptionExpanded = false

    /// Blur the hero until clicked, mirroring the grid card's spoiler gate so
    /// opening details never auto-plays adult content unprompted.
    private var shouldBlurHero: Bool {
        blurMatureThumbnails && item.isMatureRated && !matureRevealed
    }

    private var downloadCoordinator: WorkshopDownloadCoordinator { .shared }
    private var downloadPhase: WorkshopDownloadCoordinator.DownloadPhase {
        downloadCoordinator.phase(for: item.id)
    }
    private var downloadProgressFraction: Double? {
        downloadCoordinator.progress[item.id]
    }
    private var downloadProgressBytes: WorkshopDownloadCoordinator.DownloadProgressBytes? {
        downloadCoordinator.progressBytes[item.id]
    }

    private var identityBlock: some View {
        WorkshopDetailIdentityHeader(
            item: item,
            isKeyless: services.isKeyless,
            onBrowseCreator: onBrowseCreator
        )
    }

    private var actionsGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                actionsColumn
                downloadStatusNote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    private var presetsGroup: some View {
        GroupBox {
            DetailPresetsSection(
                wallpaperID: item.id,
                communityURL: item.steamCommunityURL,
                doctor: doctor
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    /// The page's "Required items" (what a Preset restyles).
    @ViewBuilder
    private var requiredItemsGroup: some View {
        if !item.requiredItemIDs.isEmpty, let onOpenItem {
            GroupBox {
                DetailRequiredItemsSection(itemIDs: item.requiredItemIDs, onOpenItem: onOpenItem)
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }

    private var aboutGroup: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if !item.tags.isEmpty {
                    tagsSection
                }
                descriptionSection
                communityLinksRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                hero

                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    identityBlock
                    actionsGroup
                    requiredItemsGroup
                    presetsGroup
                    aboutGroup
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DesignTokens.Colors.pageBackground)
        .onAppear { refreshInstalledEntry() }
        .onChange(of: item.id) { _, _ in
            refreshInstalledEntry()
            descriptionExpanded = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            refreshInstalledEntry()
        }
    }

    private func refreshInstalledEntry() {
        let id = String(item.id)
        installedEntry = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            .first { $0.origin.workshopID == id }
    }

    // MARK: - Hero

    private var hero: some View {
        // A Button keeps one stable view identity across the reveal (branching
        // on `shouldBlurHero` would rebuild the thumbnail and lose its unblur
        // animation); hit-testing gates instead of `.disabled` so `.plain`
        // never dims the artwork. Keyboard activation bypasses hit-testing,
        // hence the guard in the action.
        Button {
            if shouldBlurHero {
                requestReveal()
            }
        } label: {
            AnimatedGIFThumbnail(url: item.previewImageURL, playbackMode: .autoPlay, previewSize: .hero, isBlurred: shouldBlurHero)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                        .strokeBorder(Color.primary.opacity(DesignTokens.Card.strokeOpacity), lineWidth: DesignTokens.Card.strokeWidth)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(shouldBlurHero)
        .accessibilityHidden(!shouldBlurHero)
        .accessibilityLabel(Text("Show mature content?"))
        .padding([.horizontal, .top], DesignTokens.Spacing.lg)
            .alert("Show mature content?", isPresented: $showingAgeConfirm) {
                Button(role: .cancel) {} label: { Text("Cancel") }
                Button(role: .destructive) {
                    matureConfirmed = true
                    matureRevealed = true
                } label: {
                    Text("I am 18 or older")
                }
            } message: {
                Text("This wallpaper is tagged Mature and may contain explicit adult content. By revealing it you confirm you are at least 18 years old, or of legal age in your region.")
            }
    }

    private func requestReveal() {
        if matureConfirmed {
            matureRevealed = true
        } else {
            showingAgeConfirm = true
        }
    }
    // MARK: - Actions

    private var actionsColumn: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            downloadControl
            secondaryActionButton("Copy link", systemImage: "link") {
                copy(item.steamCommunityURL.absoluteString)
            }
            secondaryActionButton("Copy ID", systemImage: "doc.on.doc") { copy(String(item.id)) }
            secondaryActionButton("Open in Steam", systemImage: "safari") { openURL(item.steamCommunityURL) }
        }
    }

    private func secondaryActionButton(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(titleKey))
        .accessibilityLabel(Text(titleKey))
    }

    @ViewBuilder
    private var downloadControl: some View {
        switch downloadPhase {
        case .downloading:
            downloadProgressControl
        case .importing:
            indeterminateDownloadControl("Importing…")
        default:
            if let installedEntry {
                applyControl(for: installedEntry)
            } else {
                downloadButton
            }
        }
    }

    private var downloadButton: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Button {
                downloadCoordinator.download(itemID: item.id, title: item.title, using: doctor)
            } label: {
                Label(downloadButtonTitle, systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!doctor.isDownloadReady || item.isBanned)

            if !item.isBanned, let reason = doctor.downloadBlockerMessage {
                Text(verbatim: reason)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func applyControl(for entry: WPEHistoryEntry) -> some View {
        let screens = screenManager.screens
        if screens.isEmpty {
            Button {} label: { applyLabel }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(true)
                .help(Text("Open a display first, then apply"))
        } else if screens.count == 1, let only = screens.first {
            Button { apply(entry, to: only) } label: {
                Label("Apply to \(only.name)", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        } else {
            Button { showingApplyPopover = true } label: { applyLabel }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .popover(isPresented: $showingApplyPopover, arrowEdge: .bottom) {
                    AppLanguageScope(defaults: .appScoped()) {
                        WorkshopApplyTargetPicker(
                            screens: screens,
                            activeScreenIDs: activeScreenIDs,
                            onPick: { apply(entry, to: $0); showingApplyPopover = false },
                            onAll: { for screen in screens { apply(entry, to: screen) }; showingApplyPopover = false }
                        )
                    }
                }
        }
    }

    private var applyLabel: some View {
        Label("Apply", systemImage: "play.fill").frame(maxWidth: .infinity)
    }

    /// Displays currently running this item — drives the active checkmark in the Apply popover.
    private var activeScreenIDs: Set<CGDirectDisplayID> {
        Set(screenManager.screens
            .filter { screenManager.getConfiguration(for: $0)?.wpeOrigin?.workshopID == String(item.id) }
            .map(\.id))
    }

    private func apply(_ entry: WPEHistoryEntry, to screen: Screen) {
        Task { await screenManager.activateWPEHistoryEntry(entry, for: screen) }
    }

    @ViewBuilder
    private var downloadProgressControl: some View {
        if let progress = downloadProgressFraction {
            downloadControlChrome {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    HStack(spacing: 6) {
                        Text(verbatim: progressDetailLabel(for: progress))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        cancelDownloadButton
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(Text("Download progress"))
                        .accessibilityValue(Text(verbatim: progressDetailLabel(for: progress)))
                }
            }
            .help(Text(verbatim: progressDetailLabel(for: progress)))
        } else {
            indeterminateDownloadControl("Downloading…")
        }
    }

    private func indeterminateDownloadControl(_ title: LocalizedStringKey) -> some View {
        downloadControlChrome {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    cancelDownloadButton
                }
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(Text(title))
            }
        }
    }

    private func downloadControlChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm))
    }

    private var cancelDownloadButton: some View {
        Button {
            downloadCoordinator.cancel(item.id)
        } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(Text("Cancel download"))
        .accessibilityLabel(Text("Cancel download"))
    }

    @ViewBuilder
    private var downloadStatusNote: some View {
        if case .failed(let message) = downloadPhase {
            actionNote(message, color: DesignTokens.Colors.Status.danger)
        } else if !doctor.isDownloadReady, downloadPhase == .idle {
            actionNote(
                String(localized: "Installed items remain available from your official Steam library. New SteamCMD downloads need Loomscreen's background Steam connector.", bundle: .appLanguage, comment: "Hint in the Workshop detail inspector when the Steam download connector is unavailable."),
                color: .secondary
            )
        }
    }

    private func actionNote(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var isRetry: Bool {
        if case .failed = downloadPhase { return true }
        return false
    }

    /// Typed `LocalizedStringKey` so the ternary literals localize (a bare
    /// `String` ternary would bind to `Label`'s non-localized initializer).
    private var downloadButtonTitle: LocalizedStringKey { isRetry ? "Retry" : "Download" }

    private func progressDetailLabel(for fraction: Double) -> String {
        let percent = Int((fraction * 100).rounded())
        guard let totalBytes = downloadProgressTotalBytes else { return "\(percent)%" }

        let estimatedDownloaded = UInt64((Double(Int64(clamping: totalBytes)) * fraction).rounded())
        let downloadedBytes = downloadProgressBytes?.downloaded ?? estimatedDownloaded
        let downloadedText = WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(clamping: downloadedBytes))
        let totalText = WorkshopByteFormatter.megabytesAndUp.string(fromByteCount: Int64(clamping: totalBytes))
        return "\(percent)% · \(downloadedText) / \(totalText)"
    }

    private var downloadProgressTotalBytes: UInt64? {
        if let total = downloadProgressBytes?.total, total > 0 {
            return total
        }
        if let fileSize = item.fileSizeBytes, fileSize > 0 {
            return fileSize
        }
        return nil
    }
    /// One row per facet group, in the page's order (Type, Age Rating, …).
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            ForEach(WorkshopTagTaxonomy.grouped(tags: item.tags), id: \.group) { grouped in
                // Wrapping, not a horizontal scroll: at the inspector's width
                // a scroll leaves most of a group's tags off-screen with
                // nothing to say they are there.
                HStack(alignment: .top, spacing: DesignTokens.Spacing.xs) {
                    Text(verbatim: grouped.group.displayName)
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    WorkshopChipFlow(spacing: 6, lineSpacing: 4) {
                        ForEach(grouped.tags, id: \.self) { tag in
                            tagChip(tag)
                        }
                    }
                }
            }
        }
    }

    /// What the page has and the query payload does not: change notes, the
    /// comment thread and the collections listing stay on Steam.
    private var communityLinksRow: some View {
        // Wrapping, not an HStack: three labelled links do not fit the narrow
        // inspector, and squeezed they hyphenate mid-word ("Com-ments").
        WorkshopChipFlow(spacing: DesignTokens.Spacing.md, lineSpacing: DesignTokens.Spacing.xs) {
            communityLink(commentsTitle, systemImage: "bubble.left", url: WorkshopCommunityURL.comments(itemID: item.id))
            communityLink(Text("Change Notes"), systemImage: "clock.arrow.circlepath", url: WorkshopCommunityURL.changeNotes(itemID: item.id))
            communityLink(Text("Collections"), systemImage: "square.stack", url: WorkshopCommunityURL.collections(itemID: item.id))
        }
        .font(DesignTokens.Typography.caption)
    }

    private var commentsTitle: Text {
        if let count = item.commentCount, count > 0 {
            return Text("\(count.formatted()) comments", comment: "Workshop detail link to the item's comment thread. Placeholder is a formatted count.")
        }
        return Text("Comments")
    }

    private func communityLink(_ title: Text, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label { title } icon: { Image(systemName: systemImage) }
        }
        .buttonStyle(.link)
        .fixedSize()
    }

    @ViewBuilder
    private func tagChip(_ tag: String) -> some View {
        // Raw tag on the wire — Steam matches the English form.
        let label = WorkshopTagLocalization.displayName(tag)
        if let onSelectTag {
            Button { onSelectTag(tag) } label: {
                StatusChip(verbatim: label, tint: .accentColor)
            }
            .buttonStyle(.plain)
            .help(Text("Browse items tagged \(label)"))
        } else {
            StatusChip(verbatim: label, tint: .secondary)
        }
    }

    private var descriptionSection: some View {
        let text = item.shortDescription
        let placeholder = String(localized: "No description provided.", bundle: .appLanguage, comment: "Placeholder when a Workshop item has no description.")
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Description")
                .font(.headline)
            CollapsibleDescription(
                text: text.isEmpty ? placeholder : text,
                isExpanded: $descriptionExpanded
            )
        }
    }

    // MARK: - Helpers

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// Shared display-target chooser for the Apply popover (online + installed inspectors).
/// The caller dismisses the popover after a row fires its callback.
struct WorkshopApplyTargetPicker: View {
    let screens: [Screen]
    let activeScreenIDs: Set<CGDirectDisplayID>
    let onPick: (Screen) -> Void
    let onAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apply to")
                .font(DesignTokens.Typography.captionEmphasized)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            row(Text("All Displays"), systemImage: "rectangle.on.rectangle", action: onAll)
            Divider().padding(.horizontal, 8).padding(.vertical, 2)
            ForEach(screens, id: \.id) { screen in
                row(Text(verbatim: screen.name),
                    systemImage: activeScreenIDs.contains(screen.id) ? "checkmark.circle.fill" : "display") {
                    onPick(screen)
                }
            }
        }
        .padding(.bottom, 6)
        .frame(minWidth: 220)
    }

    private func row(_ title: Text, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label { title } icon: { Image(systemName: systemImage) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Description block shared by the online + Installed inspectors.
struct CollapsibleDescription: View {
    let text: String
    @Binding var isExpanded: Bool

    /// ~6 lines of body copy before we crop + fade.
    private let collapsedHeight: CGFloat = 116

    /// Measured live; `max()` keeps it stable even while the visible frame is cropped
    /// (the crop never shrinks the intrinsic height).
    @State private var fullHeight: CGFloat = 0

    private var isExpandable: Bool { fullHeight > collapsedHeight + 1 }

    var body: some View {
        let collapsed = isExpandable && !isExpanded
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: text)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { fullHeight = max(fullHeight, geo.size.height) }
                            .onChange(of: geo.size.height) { _, height in
                                fullHeight = max(fullHeight, height)
                            }
                    }
                )
                .frame(height: fullHeight == 0 ? nil : (collapsed ? collapsedHeight : fullHeight),
                       alignment: .top)
                .clipped()
                .mask(collapsed ? AnyView(fadeMask) : AnyView(Rectangle()))

            if isExpandable {
                Button {
                    withAnimation(.easeInOut(duration: 0.28)) { isExpanded.toggle() }
                } label: {
                    Text(isExpanded ? "Show less" : "Show more")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(isExpanded ? "Show less" : "Show more"))
            }
        }
        .onChange(of: text) { _, _ in
            fullHeight = 0
            isExpanded = false
        }
    }

    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.72),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
#endif
