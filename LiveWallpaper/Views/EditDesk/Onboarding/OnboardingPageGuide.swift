import LiveWallpaperCore
import SwiftUI

@MainActor @Observable
final class PageGuideSession {
    private(set) var context: PageGuideContext?
    private(set) var index = 0
    private(set) var tourPage: OnboardingProgress.Page?
    private(set) var tourPages: [OnboardingProgress.Page] = []
    @ObservationIgnored private var progress: OnboardingProgress?
    @ObservationIgnored private var router: EditDeskRouter?
    @ObservationIgnored private var displayID: CGDirectDisplayID = 0

    var isTour: Bool {
        tourPage != nil
    }

    var steps: [PageGuideStep] {
        context?.steps ?? []
    }

    var currentStep: PageGuideStep? {
        let steps = steps
        guard steps.indices.contains(index) else { return nil }
        return steps[index]
    }

    var stepNumber: Int {
        guard let tourPage, let position = tourPages.firstIndex(of: tourPage) else { return index + 1 }
        return tourPages.prefix(position).reduce(0) { $0 + PageGuideContext.onboarding($1).steps.count } + index + 1
    }

    var stepCount: Int {
        isTour ? tourPages.reduce(0) { $0 + PageGuideContext.onboarding($1).steps.count } : steps.count
    }

    var canGoBack: Bool {
        index > 0 || (tourPage != nil && tourPage != tourPages.first)
    }

    var isLastStep: Bool {
        index + 1 == steps.count && (!isTour || tourPage == tourPages.last)
    }

    func start(_ context: PageGuideContext) {
        close()
        index = 0
        self.context = context
    }

    func startTour(progress: OnboardingProgress, router: EditDeskRouter, from page: OnboardingProgress.Page? = nil) {
        close()
        self.progress = progress
        progress.markTourPresented()
        self.router = router
        displayID = router.detailDisplayID ?? CGMainDisplayID()
        tourPages = progress.visiblePages
        guard let first = page ?? progress.currentPage, tourPages.contains(first) else { close(); return }
        show(first)
    }

    func close() {
        index = 0
        context = nil
        tourPage = nil
        tourPages = []
        progress = nil
        router = nil
    }

    /// Menu commands and external navigation can leave the guide's page while its scrim is up.
    func closeIfOutsideRoute(_ router: EditDeskRouter) {
        guard let tourPage else { close(); return }
        let expectedPage: EditDeskRouter.Page = switch tourPage {
        case .home, .configuration, .overlay: .home
        case .library: .library
        case .workshop: .workshop
        case .settings: .settings
        }
        let expectedDisplay: CGDirectDisplayID? = switch tourPage {
        case .configuration, .overlay: displayID
        default: nil
        }
        if router.page != expectedPage || router.detailDisplayID != expectedDisplay {
            close()
        }
    }

    private func show(_ page: OnboardingProgress.Page) {
        tourPage = page
        context = .onboarding(page)
        index = 0
        router?.showOnboardingStep(page, displayID: displayID)
    }

    func back() {
        if index > 0 {
            index -= 1
        } else if let tourPage, let position = tourPages.firstIndex(of: tourPage), position > 0 {
            show(tourPages[position - 1])
            index = steps.count - 1
        }
    }

    func next() {
        guard context != nil else { return }
        if index + 1 < steps.count {
            index += 1
        } else if let tourPage, let position = tourPages.firstIndex(of: tourPage) {
            progress?.record(tourPage)
            if position + 1 < tourPages.count {
                show(tourPages[position + 1])
            } else {
                close()
            }
        } else {
            close()
        }
    }
}

enum PageGuideTarget: Hashable {
    case navigation, page, status, inspector, playback, overlayCanvas, overlayAdd, settingsSidebar, display, shelfHandle, libraryTools, steamMenu, detailLayers, detailActions, detailShared
}

enum PageGuideContext: CaseIterable {
    case overview, library, saved, systemWallpaper, workshop, settings, configuration, overlays

    static func page(_ page: EditDeskRouter.Page) -> Self {
        switch page {
        case .home: .overview
        case .library: .library
        case .schemes: .saved
        case .systemWallpaper: .systemWallpaper
        case .workshop: .workshop
        case .settings: .settings
        }
    }

    static func onboarding(_ page: OnboardingProgress.Page) -> Self {
        switch page {
        case .home: .overview
        case .library: .library
        case .workshop: .workshop
        case .configuration: .configuration
        case .overlay: .overlays
        case .settings: .settings
        }
    }

    private static var importHint: LocalizedStringKey {
        #if LITE_BUILD
        "Drag a video or a web folder onto a display, or set up Apple Aerials"
        #else
        "Drag a video, a web folder or a Wallpaper Engine project onto a display, or set up Apple Aerials"
        #endif
    }

    var steps: [PageGuideStep] {
        switch self {
        case .overview:
            [
                .init(.navigation, "Find your way around", "Overview shows your displays. Wallpaper Library holds your sources; its Bookmarks filter shows the ones you marked. Schemes holds saved display setups. Settings contains app-wide preferences."),
                .init(.display, "Choose a display", "Click a display to open its configuration and overlay layers. Drop a file onto a display to apply it only there; use its context menu to pause or change its wallpaper.", footnote: Self.importHint),
                .init(.shelfHandle, "Open the wallpaper shelf", "Click Wallpaper Library at the bottom, or scroll upward, to reveal the shelf. Continue upward for the full library. You can also use the top navigation."),
                .init(.status, "Understand playback", "The status capsule describes system load. If a wallpaper stops, check its display status and Settings › Performance for automatic pause rules. Closing this window keeps wallpapers running; the menu bar opens it again."),
            ]
        case .library:
            [
                .init(.libraryTools, "Import, filter and sort", "Add to Library imports files without changing a display. Filter by source, search by name or tag, and choose a sort order. Local files stay in their original location; keep them available."),
                .init(.page, "Apply a wallpaper", "Click a wallpaper to see its details and choose a target display, or drag it onto a display. Bookmark keeps the source; a scheme also keeps a display's settings and overlays."),
                .init(.libraryTools, "Apple Aerials", "Choose Aerials to connect the local aerial folder. Download videos first in macOS System Settings › Wallpaper if the list is empty."),
            ]
        case .saved:
            [
                .init(.page, "Display setups you saved", "A scheme recalls one display's wallpaper, playback settings and overlays. Choose a display on a scheme's card to apply it there. Bookmarked wallpapers are in Wallpaper Library under the Bookmarks filter."),
                .init(.navigation, "Return to your displays", "Return to Overview to adjust the result. Use the display's Scheme button to save its current configuration for later."),
            ]
        case .systemWallpaper:
            [
                .init(.page, "Let macOS play a video", "Add Video saves a separate copy for macOS. Open Wallpaper Settings to select it. This path can play with Loomscreen closed and is separate from the live wallpapers in Overview."),
                .init(.page, "Manage system copies", "The item menu reveals or removes the macOS copy. Removing a system copy is different from clearing a display's live wallpaper; review the confirmation before removing it."),
            ]
        case .workshop:
            [
                .init(.page, "Browse before connecting", "Use search, filters, sort and time range to find wallpapers. Click a result for details. A Steam Web API key is optional; its settings explain the extra information it enables."),
                .init(.steamMenu, "Connect or import locally", "Use the Steam menu to connect your account, sync subscriptions or add a link. Downloads need SteamCMD and ownership of Wallpaper Engine. Import a Local Folder works without signing in."),
                .init(.steamMenu, "Install the download component", "Open Settings › Workshop › Steam connection. Set up SteamCMD offers Install with Loomscreen, with download size and location shown before installing. Already installed it? Use Locate automatically or Choose SteamCMD.", settingsAnchor: .workshopConnection),
                .init(.steamMenu, "Authorize your Steam library", "In Steam connection, choose or authorize your Steam library folder. This grants Loomscreen access to local Workshop files; it does not sign you in. Follow the folder picker's instructions, then check the library status.", settingsAnchor: .workshopConnection),
                .init(.steamMenu, "Sign in and confirm Steam Guard", "Use the Steam account that owns Wallpaper Engine. Enter its account name and password, then approve Steam Guard on your phone or enter the requested email or authenticator code. Signing into the Steam app alone does not connect Loomscreen.", settingsAnchor: .workshopConnection),
                .init(.steamMenu, "API key is optional", "You can continue without a Steam Web API key. To add one, open Get a key in Workshop settings, sign in on Steam's official website, then paste your own key back here and wait for validation before saving. A key adds metadata and faster search; it does not replace SteamCMD sign-in.", settingsAnchor: .workshopSetup),
                .init(.steamMenu, "Prepare scene resources", "Before using scene wallpapers, set up shared Wallpaper Engine assets in Settings › Workshop › Scene resources. Download them with your connected Steam account or choose an existing assets folder. Missing assets can leave textures and effects absent even when a scene plays. Video wallpapers do not need these assets.", settingsAnchor: .workshopAssets),
                .init(.page, "Download and apply", "The detail panel lets you download and choose a display. Watch the download status and any setup or compatibility message; downloaded items appear in Wallpaper Library."),
            ]
        case .settings:
            [
                .init(.settingsSidebar, "Search for a setting", "The sidebar groups settings by task. Search finds both pages and individual settings; the information buttons explain their scope and effects."),
                .init(.page, "Startup and display defaults", "General controls language, appearance, login startup and the Dock. Display Defaults seed a display's first wallpaper; adjust an existing wallpaper in that display's configuration layer."),
                .init(.page, "Performance and permissions", "Performance controls automatic pausing. Integrations controls weather location and supported audio response. Shortcuts configures keyboard actions; Overlays changes shared widget appearance."),
                .init(.page, "Keep and recover your setup", "Backup & Restore saves settings without wallpaper files. Advanced provides diagnostics and reset. About contains Welcome Tour. Review each confirmation before replacing settings or deleting content."),
            ]
        case .configuration:
            [
                .init(.detailLayers, "Configuration and overlay layers", "The wallpaper button opens this display's configuration layer. The stacked-layers button opens its overlay editor. Display tabs switch the target; the back arrow returns to Overview."),
                .init(.playback, "Audio, scaling and frame rate", "Move over the wallpaper preview to reveal its controls. Audio adjusts mute and volume; scaling fills, fits or stretches the image. Frame rate limits animation. Interaction sends desktop clicks to the wallpaper; turn it off to use desktop icons again. Available controls depend on the wallpaper type."),
                .init(.inspector, "Wallpaper properties", "The Settings button opens the right panel with this wallpaper's properties. Changes affect the selected display."),
                .init(.detailActions, "Change, reload or clear", "Change Wallpaper selects another source. Reload restarts this display's content. Clear removes its wallpaper configuration without deleting the source file."),
                .init(.detailShared, "Save, automate or share", "Playlist & Schedule controls automatic changes. Bookmark saves the source; Scheme saves the full display setup. Apply to All Displays affects every connected display—check the target before using it."),
            ]
        case .overlays:
            [
                .init(.detailLayers, "Your overlay layer", "Overlays add independent clocks, weather, music and widgets above the wallpaper. Switch back with the wallpaper button; the display tabs choose which screen you are editing."),
                .init(.overlayAdd, "Add a widget", "Choose an item in Add Widget below. Click to add it, or drag it onto the canvas; select it to edit its appearance."),
                .init(.overlayCanvas, "Arrange and configure", "Drag an object to move it. Select it and open Settings to adjust its appearance. The layer list shows or hides individual objects; Alignment Snapping helps position them."),
                .init(.overlayCanvas, "Preview and desktop", "The preview selector can show sample data. Check the actual desktop for live values. Weather needs a location in Settings › Integrations; music needs a supported player."),
                .init(.detailShared, "Copy or remove overlays", "Copy to Other Displays opens a target chooser. Remove affects the selected overlay; Remove All affects this display's overlay objects. These controls are separate from Clear Wallpaper."),
            ]
        }
    }
}

struct PageGuideStep {
    let target: PageGuideTarget
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let footnote: LocalizedStringKey?
    let settingsAnchor: SettingsSearchAnchor?

    init(_ target: PageGuideTarget, _ title: LocalizedStringKey, _ message: LocalizedStringKey, footnote: LocalizedStringKey? = nil, settingsAnchor: SettingsSearchAnchor? = nil) {
        self.target = target
        self.title = title
        self.message = message
        self.footnote = footnote
        self.settingsAnchor = settingsAnchor
    }
}

struct PageGuideAnchorKey: PreferenceKey {
    static let defaultValue: [PageGuideTarget: Anchor<CGRect>] = [:]
    static func reduce(value: inout [PageGuideTarget: Anchor<CGRect>], nextValue: () -> [PageGuideTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func pageGuideTarget(_ target: PageGuideTarget) -> some View {
        transformAnchorPreference(key: PageGuideAnchorKey.self, value: .bounds) { anchors, anchor in
            anchors[target] = anchor
        }
    }
}

struct PageGuideButton: View {
    let context: PageGuideContext
    @Environment(PageGuideSession.self) private var session: PageGuideSession?

    var body: some View {
        GlassIconButton("questionmark", size: .regular) { session?.start(context) }
            .help(Text("Explain This Page"))
            .accessibilityLabel(Text("Explain This Page"))
            .accessibilityIdentifier("pageGuide.open")
    }
}

/// Panel geometry is independent of the underlying page layout and recomputed on every resize.
enum PageGuideLayout {
    static let margin: CGFloat = 24
    static let topClearance: CGFloat = 72
    static let preferredWidth: CGFloat = 380

    static func frame(in size: CGSize, panel: CGSize, target: CGRect?) -> CGRect {
        let bounds = CGRect(x: margin, y: topClearance,
                            width: max(0, size.width - margin * 2),
                            height: max(0, size.height - topClearance - margin))
        let width = min(panel.width, bounds.width)
        let height = min(panel.height, bounds.height)
        func clamped(_ origin: CGPoint) -> CGRect {
            CGRect(x: min(max(origin.x, bounds.minX), bounds.maxX - width),
                   y: min(max(origin.y, bounds.minY), bounds.maxY - height), width: width, height: height)
        }
        guard let target, !target.isEmpty else {
            return clamped(CGPoint(x: bounds.maxX - width, y: bounds.maxY - height))
        }
        let gap: CGFloat = 12
        let candidates = [
            CGPoint(x: target.midX - width / 2, y: target.maxY + gap),
            CGPoint(x: target.midX - width / 2, y: target.minY - height - gap),
            CGPoint(x: target.minX - width - gap, y: target.midY - height / 2),
            CGPoint(x: target.maxX + gap, y: target.midY - height / 2),
        ].map(clamped)
        func score(_ rect: CGRect) -> CGFloat {
            let overlap = rect.intersection(target)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            return area * 10000 + pow(rect.midX - target.midX, 2) + pow(rect.midY - target.midY, 2)
        }
        return candidates.min { score($0) < score($1) } ?? bounds
    }
}

struct PageGuideHost: View {
    let session: PageGuideSession
    let anchors: [PageGuideTarget: Anchor<CGRect>]
    var onOpenWorkshopSettings: ((SettingsSearchAnchor) -> Void)?
    @FocusState private var guideFocused: Bool
    @State private var measuredPanel = CGSize(width: PageGuideLayout.preferredWidth, height: 280)

    var body: some View {
        if session.context != nil {
            GeometryReader { geometry in
                // GeometryReader can update after close() clears the session, before this host unmounts.
                if let step = session.currentStep {
                    let rect = step.target == .page ? nil : anchors[step.target].map { geometry[$0] }
                    ZStack {
                        GuideScrim(hole: rect)
                            .fill(.black.opacity(0.22), style: FillStyle(eoFill: true))
                            .contentShape(Rectangle())
                            .onTapGesture { session.close() }
                            .accessibilityHidden(true)
                        if let rect {
                            RoundedRectangle(cornerRadius: DesignTokens.Corner.md)
                                .strokeBorder(DesignTokens.Colors.accent, lineWidth: 3)
                                .frame(width: max(0, rect.width), height: max(0, rect.height))
                                .position(x: rect.midX, y: rect.midY)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        let panelFrame = PageGuideLayout.frame(in: geometry.size, panel: measuredPanel, target: rect)
                        ViewThatFits(in: .vertical) {
                            panel(step)
                            ScrollView { panel(step) }
                        }
                        .frame(width: min(PageGuideLayout.preferredWidth, max(0, geometry.size.width - PageGuideLayout.margin * 2)))
                        .frame(maxHeight: max(0, geometry.size.height - PageGuideLayout.topClearance - PageGuideLayout.margin))
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGSize.self, of: \.size) { measuredPanel = $0 }
                        .position(x: panelFrame.midX, y: panelFrame.midY)
                    }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($guideFocused)
            .onAppear { guideFocused = true }
            .onKeyPress(.escape) { session.close(); return .handled }
            .accessibilityIdentifier("pageGuide.overlay")
        }
    }

    private func panel(_ step: PageGuideStep) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            HStack {
                Text(session.isTour ? "Welcome Tour" : "Explain This Page")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                GlassIconButton("xmark", size: .regular) { session.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Text("Close"))
                    .help(Text("Close"))
            }
            Text(step.title)
                .font(DesignTokens.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Text(step.message)
                .font(DesignTokens.Typography.body)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote = step.footnote {
                Text(footnote)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let anchor = step.settingsAnchor, let onOpenWorkshopSettings {
                Button("Open Workshop Settings") { onOpenWorkshopSettings(anchor) }
                    .buttonStyle(.bordered)
            }
            HStack {
                Button("Back") { session.back() }
                    .disabled(!session.canGoBack)
                    .buttonStyle(.bordered)
                Spacer(minLength: DesignTokens.Spacing.sm)
                Text("Step \(session.stepNumber) of \(session.stepCount)")
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: DesignTokens.Spacing.sm)
                Button(session.isLastStep ? (session.isTour ? "Finish Tour" : "Done") : "Next Step") { session.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("pageGuide.next")
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .background(DesignTokens.Colors.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.Corner.sheet))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
    }
}

private struct GuideScrim: Shape {
    var hole: CGRect?
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if let hole, !hole.isEmpty {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: DesignTokens.Corner.md, height: DesignTokens.Corner.md))
        }
        return path
    }
}
