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
    @State private var installedEntry: WPEHistoryEntry?

    /// Named constants, not literals: the grid card reads the same two keys through
    /// `MatureContentSettings`, and a typo would give this view its own setting.
    @AppStorage(MatureContentSettings.blursThumbnails, store: .appScoped()) private var blurMatureThumbnails = true
    @AppStorage(MatureContentSettings.confirmed, store: .appScoped()) private var matureConfirmed = false
    @State private var matureRevealed = false
    @State private var showingAgeConfirm = false
    @State private var showingApplyPopover = false

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                hero

                WorkshopDetailsContent(
                    item: item,
                    doctor: doctor,
                    onBrowseCreator: onBrowseCreator,
                    onSelectTag: onSelectTag,
                    onOpenItem: onOpenItem
                ) {
                    actionsGroup
                }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.bottom, DesignTokens.Spacing.lg)
            }
        }
        .background(DesignTokens.Colors.pageBackground)
        .onAppear { refreshInstalledEntry() }
        .onChange(of: item.id) { _, _ in refreshInstalledEntry() }
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
        // A Button keeps one stable view identity across the reveal (branching on
        // `shouldBlurHero` would rebuild the thumbnail and lose its unblur animation);
        // hit-testing gates instead of `.disabled`, and keyboard activation bypasses it.
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
    // MARK: - Helpers

    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

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

struct CollapsibleDescription: View {
    let text: String
    @Binding var isExpanded: Bool
    /// nil crops the collapsed text to `collapsedHeight` and fades the cut; a value truncates it to
    /// that many lines instead, for columns too narrow to spend 116pt on a description.
    var collapsedLineLimit: Int?
    /// nil lets the expanded text take whatever height it needs; a value scrolls it inside that box.
    var expandedMaxHeight: CGFloat?

    /// ~6 lines of body copy before we crop + fade.
    private let collapsedHeight: CGFloat = 116

    /// The text's height with no crop of any kind.
    @State private var fullHeight: CGFloat = 0
    /// The height `collapsedLineLimit` leaves; equal to `fullHeight` when there is no limit.
    @State private var limitedHeight: CGFloat = 0

    /// A height crop can only be told from the box it fills; a line crop shows up as the two
    /// measurements disagreeing, which holds whether or not the text is expanded right now.
    static func isExpandable(
        fullHeight: CGFloat, limitedHeight: CGFloat, collapsedHeight: CGFloat, lineLimit: Int?
    ) -> Bool {
        guard lineLimit != nil else { return fullHeight > collapsedHeight + 1 }
        return fullHeight > limitedHeight + 1
    }

    /// nil means the text keeps its intrinsic height: expanded, or cropped by lines rather than points.
    static func cropHeight(
        fullHeight: CGFloat, collapsedHeight: CGFloat, collapsed: Bool, lineLimit: Int?
    ) -> CGFloat? {
        guard fullHeight > 0, lineLimit == nil else { return nil }
        return collapsed ? collapsedHeight : fullHeight
    }

    private var isExpandable: Bool {
        Self.isExpandable(
            fullHeight: fullHeight, limitedHeight: limitedHeight,
            collapsedHeight: collapsedHeight, lineLimit: collapsedLineLimit
        )
    }

    var body: some View {
        let collapsed = isExpandable && !isExpanded
        VStack(alignment: .leading, spacing: 4) {
            description(collapsed: collapsed)
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
            limitedHeight = 0
            isExpanded = false
        }
    }

    @ViewBuilder
    private func description(collapsed: Bool) -> some View {
        let cropped = Text(verbatim: text)
            .font(.body)
            .foregroundStyle(.secondary)
            .lineLimit(collapsed ? collapsedLineLimit : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .topLeading) { rulers }
            .frame(
                height: Self.cropHeight(
                    fullHeight: fullHeight, collapsedHeight: collapsedHeight,
                    collapsed: collapsed, lineLimit: collapsedLineLimit
                ),
                alignment: .top
            )
            .clipped()
            .mask(collapsed && collapsedLineLimit == nil ? AnyView(fadeMask) : AnyView(Rectangle()))

        if let expandedMaxHeight, isExpanded {
            ScrollView { cropped }
                .frame(maxHeight: expandedMaxHeight)
        } else {
            cropped
        }
    }

    /// Hidden copies rather than a reader on the visible text: `lineLimit` shortens what the
    /// visible text reports, which is the very difference the toggle is looking for.
    private var rulers: some View {
        ZStack(alignment: .topLeading) {
            ruler(lineLimit: nil) { fullHeight = $0 }
            if collapsedLineLimit != nil {
                ruler(lineLimit: collapsedLineLimit) { limitedHeight = $0 }
            }
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private func ruler(lineLimit: Int?, report: @escaping (CGFloat) -> Void) -> some View {
        Text(verbatim: text)
            .font(.body)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { report($0) }
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
