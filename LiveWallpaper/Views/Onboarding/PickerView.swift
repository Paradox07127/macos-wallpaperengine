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

/// Keeps the multi-display choice deterministic and testable without UI.
enum OnboardingDisplayTargetPolicy {
    static func defaultTargetID(from availableIDs: [CGDirectDisplayID]) -> CGDirectDisplayID? {
        availableIDs.first
    }

    /// A nil selection explicitly means every display. A stale selection falls
    /// back to the first available display instead of unexpectedly applying to all.
    static func selectedIDs(
        targetID: CGDirectDisplayID?,
        availableIDs: [CGDirectDisplayID]
    ) -> [CGDirectDisplayID] {
        guard let targetID else { return availableIDs }
        if availableIDs.contains(targetID) { return [targetID] }
        return availableIDs.first.map { [$0] } ?? []
    }
}

/// Onboarding source step.
struct OnboardingPickerView: View {
    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let galleryActions: [OnboardingSourceAction]
    let didConfigure: (CGDirectDisplayID?) -> Void
    let skip: () -> Void
    let chooseAppleAerials: () -> Void
    let chooseSteamWorkshop: () -> Void

    @State private var inlineError: LocalizedStringResource?
    @State private var isDropTargeted = false
    @State private var selectedTargetID: CGDirectDisplayID?
    @State private var didInitializeTarget = false
    @State private var isImportingScene = false

    private var sceneCapable: Bool {
        OnboardingImportCopy.sceneCapable(in: featureCatalog)
    }

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.lg) {
            header
            destinationPicker

            VStack(spacing: DesignTokens.Spacing.md) {
                ForEach(galleryActions.indices, id: \.self) { idx in
                    galleryRow(for: galleryActions[idx])
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return handleImportedURL(url)
            } isTargeted: { isDropTargeted = $0 }

            Spacer(minLength: 0)

            if let inlineError {
                inlineErrorBanner(inlineError)
            }

            if isImportingScene {
                ProgressView("Importing…")
                    .font(DesignTokens.Typography.body)
            }

            skipFooter
        }
        .padding(.horizontal, DesignTokens.Spacing.xl + DesignTokens.Spacing.sm)
        .padding(.bottom, DesignTokens.Spacing.lg)
        .overlay(dropHighlight)
        .onAppear(perform: synchronizeTargetSelection)
        .onChange(of: availableScreenIDs) { _, _ in synchronizeTargetSelection() }
        .disabled(isImportingScene)
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("Pick Your First Wallpaper")
                .font(DesignTokens.Typography.pageTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Choose how to bring your desktop to life.")
                .font(DesignTokens.Typography.body)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var destinationPicker: some View {
        let screens = screenManager.screens
        if let onlyScreen = screens.first, screens.count == 1 {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "display")
                    .foregroundStyle(DesignTokens.Colors.accent)
                    .accessibilityHidden(true)
                Text("Apply to")
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Text(verbatim: onlyScreen.name)
                    .font(DesignTokens.Typography.bodyEmphasized)
                    .lineLimit(1)
            }
            .font(DesignTokens.Typography.body)
        } else if screens.count > 1 {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("Apply to")
                    .font(DesignTokens.Typography.body)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)
                Picker("Apply to", selection: $selectedTargetID) {
                    ForEach(screens, id: \.id) { screen in
                        Text(verbatim: screen.name)
                            .tag(Optional(screen.id))
                    }
                    Divider()
                    Text("All Displays")
                        .tag(CGDirectDisplayID?.none)
                }
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            )
        }
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

    @ViewBuilder
    private var skipFooter: some View {
        Button(action: skip) {
            Text("Skip for Now", comment: "Secondary onboarding action that defers wallpaper setup.")
                .font(DesignTokens.Typography.body)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
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
            return fail("Wallpaper Engine scenes need the Pro edition.")
        }

        switch WallpaperImportRouter.route(url, sceneCapable: sceneCapable) {
        case .video(let videoURL):
            guard let bookmark = ResourceUtilities.createVideoBookmark(for: videoURL) else {
                return fail("Couldn't read that file. Try a different one.")
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
            return fail("Wallpaper Engine scenes need the Pro edition.")
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
            for screen in targets {
                switch await screenManager.importWallpaperEngineProject(at: folderURL, for: screen) {
                case .applied, .unsupported:
                    didConfigureAny = true
                case .registeredPreset(let name):
                    presetName = name
                case .rejected:
                    break
                }
            }
            isImportingScene = false
            guard didConfigureAny else {
                if let presetName {
                    fail("“\(presetName)” is a preset, not a wallpaper. It was added to your presets — choose a wallpaper to continue.")
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

    private var availableScreenIDs: [CGDirectDisplayID] {
        screenManager.screens.map(\.id)
    }

    private var targetScreens: [Screen] {
        let selectedIDs = Set(
            OnboardingDisplayTargetPolicy.selectedIDs(
                targetID: selectedTargetID,
                availableIDs: availableScreenIDs
            )
        )
        return screenManager.screens.filter { selectedIDs.contains($0.id) }
    }

    private func synchronizeTargetSelection() {
        if !didInitializeTarget {
            didInitializeTarget = true
            selectedTargetID = OnboardingDisplayTargetPolicy.defaultTargetID(from: availableScreenIDs)
            return
        }
        if let selectedTargetID, !availableScreenIDs.contains(selectedTargetID) {
            self.selectedTargetID = OnboardingDisplayTargetPolicy.defaultTargetID(from: availableScreenIDs)
        }
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
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, DesignTokens.Spacing.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous)
                    .fill(DesignTokens.Colors.surfaceRaised)
            )
            .galleryTileChrome(isHovering: isActive, reduceMotion: reduceMotion)
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Corner.lg, style: .continuous))
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(subtitle))
    }
}
