import AppKit
import LiveWallpaperCore
import SwiftUI

enum OnboardingImportCopy {
    enum UnsupportedFileTypeVariant: Equatable {
        case videoAndWeb
        case videoWebAndScene
    }

    static func unsupportedFileTypeVariant(sceneCapable: Bool) -> UnsupportedFileTypeVariant {
        sceneCapable ? .videoWebAndScene : .videoAndWeb
    }

    /// Same capability gate for recovery copy and import routing (testable without rendering).
    static func sceneCapable(in catalog: FeatureCatalog) -> Bool {
        catalog.isEnabled(.scene)
    }

    static func unsupportedFileTypeMessage(sceneCapable: Bool) -> LocalizedStringResource {
        switch unsupportedFileTypeVariant(sceneCapable: sceneCapable) {
        case .videoAndWeb:
            return "That file type isn't supported. Pick a video or web page."
        case .videoWebAndScene:
            return "That file type isn't supported. Pick a video, web page, or scene."
        }
    }
}

/// Onboarding source step.
struct PickerView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let galleryActions: [OnboardingSourceAction]
    let didConfigure: (CGDirectDisplayID?) -> Void
    /// Finishes onboarding without picking a source and opens the app.
    let start: () -> Void
    let chooseAppleAerials: () -> Void
    let chooseSteamWorkshop: () -> Void

    @State private var inlineError: LocalizedStringResource?
    @State private var isDropTargeted = false
    @State private var isImportingScene = false
    /// Which display an imported file lands on. Only this page needs it — the
    /// other two cards open a library rather than applying anything.
    @State private var selectedScreenID: CGDirectDisplayID?

    private var sceneCapable: Bool {
        OnboardingImportCopy.sceneCapable(in: featureCatalog)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xl) {
            header

            VStack(spacing: DesignTokens.Spacing.md) {
                ForEach(galleryActions.indices, id: \.self) { idx in
                    galleryRow(for: galleryActions[idx])
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return handleImportedURL(url)
            } isTargeted: { isDropTargeted = $0 }

            displayPicker

            Spacer(minLength: 0)

            if let inlineError {
                inlineErrorBanner(inlineError)
            }

            if isImportingScene {
                ProgressView("Importing…")
                    .font(DesignTokens.Typography.body)
            }

            Button(action: start) {
                Text("Start")
                    .frame(minWidth: 140)
            }
            .buttonStyle(CapsuleButtonStyle(preset: .large))
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text("Close setup and open the app"))
        }
        .padding(.horizontal, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .overlay(dropHighlight)
        .disabled(isImportingScene)
    }

    // MARK: - Subviews

    /// Last step, so the copy says where each card lands rather than promising a
    /// wallpaper: only Import applies one here, the other two open the library
    /// you asked for.
    private var header: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Text("You're All Set")
                .font(DesignTokens.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Pick where to start. This closes setup and takes you there.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func galleryRow(for action: OnboardingSourceAction) -> some View {
        switch action {
        case .steamWorkshop:
            ActionRowCard(
                icon: "cube.transparent",
                tint: DesignTokens.Colors.accent,
                title: "Steam Workshop",
                subtitle: "Browse Wallpaper Engine from Steam",
                action: chooseSteamWorkshop
            )
        case .importFile:
            ActionRowCard(
                icon: "square.and.arrow.down",
                tint: .blue,
                title: "Import a File",
                subtitle: sceneCapable
                    ? "Video, web page, or Wallpaper Engine scene"
                    : "Video or web page",
                action: openImportPanel
            )
        case .appleAerials:
            ActionRowCard(
                icon: "sparkles.tv",
                tint: .teal,
                title: "Apple Aerials",
                subtitle: "Apple TV's aerial screensavers",
                action: chooseAppleAerials
            )
        }
    }

    /// Shown only with more than one display: with one there is nothing to
    /// choose, and a picker with a single entry reads as a decision the reader
    /// has to make.
    @ViewBuilder
    private var displayPicker: some View {
        if screenManager.screens.count > 1 {
            Picker(selection: $selectedScreenID) {
                ForEach(screenManager.screens) { screen in
                    Text(verbatim: screen.name).tag(Optional(screen.id))
                }
            } label: {
                Text("Import to")
            }
            .pickerStyle(.menu)
            .fixedSize()
            .onAppear {
                if selectedScreenID == nil { selectedScreenID = screenManager.screens.first?.id }
            }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Corner.xl, style: .continuous)
            .strokeBorder(DesignTokens.Colors.accent.opacity(isDropTargeted ? 0.6 : 0), lineWidth: 2)
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .animation(DesignTokens.motion(reduceMotion, .easeInOut(duration: 0.15)), value: isDropTargeted)
            .allowsHitTesting(false)
    }

    private func inlineErrorBanner(_ message: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.Status.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DesignTokens.Spacing.sm)
        .background(
            DesignTokens.Colors.Status.warning.opacity(0.1),
            in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sm)
        )
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    // MARK: - Import routing

    private func openImportPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsManager.shared.getLastUsedDirectory()
        panel.prompt = L10n.Panel.useAsWallpaper
        guard panel.runModal() == .OK, let url = panel.url else { return }
        SettingsManager.shared.saveLastUsedDirectory(url.deletingLastPathComponent())
        _ = handleImportedURL(url)
    }

    /// Apply a dropped/picked URL to all displays; returns whether accepted.
    @discardableResult
    private func handleImportedURL(_ url: URL) -> Bool {
        clearError()
        let targets = targetScreens
        guard !targets.isEmpty else { return fail("No displays detected") }

        // Scene folders are rejected before routing in Lite so the user gets the
        // "needs Pro" reason instead of the generic unsupported-type message.
        if !sceneCapable, WallpaperImportRouter.isWallpaperEngineProjectFolder(url) {
            return fail("Wallpaper Engine scenes need Loomscreen Pro, a separate free download.")
        }

        switch WallpaperImportRouter.route(url, sceneCapable: sceneCapable) {
        case .video(let videoURL):
            let bookmark: Data
            switch ResourceUtilities.videoBookmark(for: videoURL) {
            case let .success(data):
                bookmark = data
            case .failure(.couldNotCopy):
                // "Couldn't read that file" covered both, and was wrong for the
                // one where the file read fine and the disk refused the copy.
                return fail("Couldn't copy that video into Loomscreen's storage. Check that the file is readable and that there is free space.")
            case .failure(.couldNotBookmarkCopy):
                return fail("Copied that video, but macOS wouldn't grant lasting access to it.")
            }
            for screen in targets {
                screenManager.setVideo(url: videoURL, bookmarkData: bookmark, for: screen)
            }
            didConfigure(targets.first?.id)
            return true

        case .html(let source):
            applyHTML(source, to: targets)
            didConfigure(targets.first?.id)
            return true

        case .sceneProject(let folderURL):
            #if !LITE_BUILD
            applyScene(folderURL, to: targets)
            return true
            #else
            return fail("Wallpaper Engine scenes need Loomscreen Pro, a separate free download.")
            #endif

        case .sceneLibrary:
            // First run applies one wallpaper; a whole library belongs in the
            // Workshop pane, reachable after onboarding.
            return fail(OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: sceneCapable))

        case .unsupported:
            return fail(OnboardingImportCopy.unsupportedFileTypeMessage(sceneCapable: sceneCapable))
        }
    }

    private func applyHTML(_ source: HTMLSource, to targets: [Screen]) {
        for screen in targets {
            screenManager.setHTMLWallpaperPreservingConfig(source: source, for: screen)
        }
    }

    #if !LITE_BUILD
    /// Finishing onboarding is a claim that a wallpaper is now on screen, so it
    /// waits for an outcome that put one there. A Workshop *preset* folder is
    /// the case that used to slip through: it joins the preset menu of a
    /// wallpaper the user may not even own yet, and nothing gets displayed.
    private func applyScene(_ folderURL: URL, to targets: [Screen]) {
        let didStartScope = folderURL.startAccessingSecurityScopedResource()
        isImportingScene = true
        Task { @MainActor in
            defer { if didStartScope { folderURL.stopAccessingSecurityScopedResource() } }
            var didConfigureAny = false
            var presetName: String?
            // The import service states why it refused, in a sentence it has
            // already localized. Dropping it left every refusal — a missing
            // entry file, an unreadable package, a bookmark macOS would not
            // grant — reading as "try another folder".
            var rejection: String?
            for screen in targets {
                switch await screenManager.importWallpaperEngineProject(at: folderURL, for: screen) {
                case .applied, .unsupported:
                    didConfigureAny = true
                case .registeredPreset(let name):
                    presetName = name
                case let .rejected(reason):
                    // First refusal wins: with several displays selected the
                    // rest are the same project failing the same way.
                    if rejection == nil, !reason.isEmpty {
                        rejection = reason
                    }
                }
            }
            isImportingScene = false
            guard didConfigureAny else {
                if let presetName {
                    fail("“\(presetName)” is a preset, not a wallpaper. It was added to your presets — choose a wallpaper to continue.")
                } else if let rejection {
                    fail("Couldn't set up that Wallpaper Engine project — \(rejection)")
                } else {
                    fail("Couldn't set up that Wallpaper Engine project. Try another folder.")
                }
                return
            }
            didConfigure(targets.first?.id)
        }
    }
    #endif

    // MARK: - Helpers

    @discardableResult
    private func fail(_ message: LocalizedStringResource) -> Bool {
        withAnimation(.easeOut(duration: 0.18)) { inlineError = message }
        return false
    }

    private func clearError() {
        if inlineError != nil { inlineError = nil }
    }

    /// The display the picker names, or the primary one when there is only a
    /// single display and no picker is shown. Importing writes a wallpaper to a
    /// specific screen, so the reader has to be able to say which.
    private var targetScreens: [Screen] {
        if let selectedScreenID,
           let chosen = screenManager.screens.first(where: { $0.id == selectedScreenID }) {
            return [chosen]
        }
        return screenManager.screens.first.map { [$0] } ?? []
    }
}

/// Full-width row card (bigger tap target than a grid).
private struct ActionRowCard: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let action: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isActive: Bool { isHovering || isFocused }

    private enum Metrics {
        /// Tighter than the gallery default: three stacked cards on a 520pt
        /// sheet sit close enough that a 12pt blur from each one pools in the
        /// gaps and reads as a grey band rather than as depth.
        static let cardShadowRadius: CGFloat = 6
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignTokens.Typography.sectionTitle)
                    Text(subtitle)
                        .font(DesignTokens.Typography.body)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(DesignTokens.Typography.captionEmphasized)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, DesignTokens.Spacing.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .galleryTileChrome(
                isHovering: isActive,
                shadowRadius: Metrics.cardShadowRadius,
                reduceMotion: reduceMotion
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }
}
