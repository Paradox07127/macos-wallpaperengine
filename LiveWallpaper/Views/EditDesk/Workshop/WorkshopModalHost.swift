#if !LITE_BUILD
import AppKit
import CoreGraphics
import LiveWallpaperCore
import SwiftUI

/// What the wiring needs from `ScreenManager`: the live panels, and the right to stamp a selection
/// generation on one of them. `DeferredApplyScreenResolving` covers the coordinator's half.
@MainActor
protocol WorkshopApplyTargetSelecting {
    var screens: [Screen] { get }
    @discardableResult
    func beginExplicitWallpaperSelection(for screen: Screen) -> Int
}

extension ScreenManager: WorkshopApplyTargetSelecting {}

/// The modal's download → deferred-apply wiring, kept out of the view so its transitions can be
/// driven without a window.
@MainActor
struct WorkshopModalWiring {
    /// The download coordinator as this wiring uses it.
    struct Downloads {
        var start: @MainActor (UInt64) -> WorkshopDownloadAttempt?
        var active: @MainActor (UInt64) -> WorkshopDownloadAttempt?
        var cancel: @MainActor (UInt64) -> Void
    }

    let downloads: Downloads
    let deferredApply: DeferredApplyCoordinator
    let screens: any WorkshopApplyTargetSelecting

    func ticket(for itemID: UInt64) -> DeferredApplyCoordinator.Ticket? {
        deferredApply.ticket(for: itemID)
    }

    /// Downloads the item if it is not already coming, and queues the apply against the generation
    /// this press stamps on the chosen display: anything the user applies there afterwards wins.
    @discardableResult
    func applyWhenDownloaded(itemID: UInt64, to screenID: CGDirectDisplayID) -> DeferredApplyCoordinator.Ticket? {
        guard let screen = screens.screens.first(where: { $0.id == screenID }),
              let attempt = downloads.active(itemID) ?? downloads.start(itemID) else { return nil }
        let generation = screens.beginExplicitWallpaperSelection(for: screen)
        return deferredApply.submit(
            attempt: attempt, target: .init(screen: screen, selectionGeneration: generation)
        )
    }

    /// Moves a queued apply to another display. Refused once the apply is running — the wallpaper is
    /// already going somewhere and re-pointing it would leave the first display half-changed.
    @discardableResult
    func retarget(itemID: UInt64, to screenID: CGDirectDisplayID) -> Bool {
        guard let ticket = deferredApply.ticket(for: itemID), ticket.state == .waiting,
              let screen = screens.screens.first(where: { $0.id == screenID }) else { return false }
        let generation = screens.beginExplicitWallpaperSelection(for: screen)
        return deferredApply.updateTarget(
            .init(screen: screen, selectionGeneration: generation), for: ticket
        )
    }

    /// Keeps the download and drops the apply: the wallpaper lands in the library and nowhere else.
    func saveOnly(itemID: UInt64) {
        dropQueuedApply(itemID: itemID)
        _ = downloads.active(itemID) ?? downloads.start(itemID)
    }

    func cancelDownload(itemID: UInt64) {
        dropQueuedApply(itemID: itemID)
        downloads.cancel(itemID)
    }

    private func dropQueuedApply(itemID: UInt64) {
        guard let ticket = deferredApply.ticket(for: itemID), !ticket.state.isSettled else { return }
        deferredApply.cancel(ticket)
    }
}

/// SCREENS.md S8b over the Workshop grid: resolves the opened item, owns the float strip's single
/// target selection and hands `WorkshopModal` everything it draws. The modal, the strip and the
/// grid share `EditDeskCoordinateSpace`, which this view's root defines.
struct WorkshopModalHost: View {
    @Binding var presentedItemID: UInt64?
    /// The current browse page; the opened item is read from here first so a refreshed persona or
    /// rating shows up without a second fetch.
    let items: [WorkshopQueryItem]
    let session: WorkshopSession
    let toasts: EditDeskToastCenter
    let windowSize: CGSize

    @Environment(ScreenManager.self) private var screenManager
    @Environment(WorkshopServices.self) private var services
    @Environment(SteamCMDDoctorService.self) private var doctor
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The opened item when it is not on the current page, fetched once.
    @State private var detachedItem: WorkshopQueryItem?
    @State private var selectedTargetID: CGDirectDisplayID?
    @State private var installedEntry: WPEHistoryEntry?
    @State private var covers: [CGDirectDisplayID: CGImage] = [:]
    @State private var rateMeter = WorkshopDownloadRateMeter()

    /// SCREENS S5: the strip enters from −130 above its resting top.
    private static let floatHiddenTop: CGFloat = -130

    private var downloads: WorkshopDownloadCoordinator {
        .shared
    }

    private var item: WorkshopQueryItem? {
        guard let presentedItemID else { return nil }
        return items.first { $0.id == presentedItemID } ?? detachedItem.flatMap { $0.id == presentedItemID ? $0 : nil }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let item {
                let targets = targets(for: item)
                WorkshopModal(
                    content: content(for: item),
                    doctor: doctor,
                    targets: targets,
                    download: presentation(for: item),
                    primaryTitle: primaryTitle(for: item, targets: targets),
                    isPrimaryEnabled: isPrimaryEnabled(for: item, targets: targets),
                    isRevealed: session.matureReveal.isRevealed(item.id),
                    matureReveal: session.matureReveal,
                    windowSize: windowSize,
                    // The whole top bar stays clickable: traffic lights and the window drag region live there.
                    titlebarInset: DesignTokens.EditDesk.Spacing.topBar,
                    onDismiss: { presentedItemID = nil },
                    actions: actions(for: item)
                )
                DisplayFloatLayer(
                    targets: targets,
                    mode: .selectTarget,
                    highlighted: resolvedTargetID(in: targets),
                    windowWidth: windowSize.width,
                    onSelect: { select($0, for: item) },
                    onApplyAll: {},
                    onTargetFrame: { _ in },
                    onRunFrame: { _ in }
                )
                .padding(.top, FloatLayerGeometry.panelTop)
                .transition(.offset(y: Self.floatHiddenTop - FloatLayerGeometry.panelTop).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: EditDeskCoordinateSpace.name)
        .animation(DesignTokens.motion(reduceMotion, .spring(response: 0.45, dampingFraction: 0.82)), value: presentedItemID != nil)
        .task(id: presentedItemID) { await open() }
        // Its own task: capturing a still per display takes longer than resolving the item, and the
        // modal must not wait on the strip's thumbnails to draw.
        .task(id: presentedItemID) { await loadCovers() }
        .onChange(of: downloadSample) { _, _ in recordRate() }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            refreshInstalledEntry()
        }
    }

    // MARK: Opening

    private func open() async {
        guard let presentedItemID else {
            detachedItem = nil
            selectedTargetID = nil
            installedEntry = nil
            rateMeter = WorkshopDownloadRateMeter()
            return
        }
        refreshInstalledEntry()
        guard !items.contains(where: { $0.id == presentedItemID }), detachedItem?.id != presentedItemID else { return }
        let outcome = await services.itemDetails.load(ids: [presentedItemID])
        guard self.presentedItemID == presentedItemID else { return }
        detachedItem = outcome.items.first
    }

    private func refreshInstalledEntry() {
        guard let presentedItemID else { return }
        let workshopID = String(presentedItemID)
        installedEntry = SettingsManager.shared.loadGlobalSettings().recentWPEImports
            .first { $0.origin.workshopID == workshopID }
    }

    /// Stills of the app's own rendering, the same source the stage uses for its display shells.
    private func loadCovers() async {
        guard presentedItemID != nil else { return }
        for screen in screenManager.screens {
            guard covers[screen.id] == nil, let configuration = screenManager.getConfiguration(for: screen) else { continue }
            let image = await WallpaperCoverCapture.captureWallpaper(screen: screen, configuration: configuration)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
            guard let image else { continue }
            covers[screen.id] = image
        }
    }

    // MARK: Content

    private func content(for item: WorkshopQueryItem) -> WorkshopModalContent {
        WorkshopModalContent(item: item, installed: installedExtras(for: item))
    }

    /// Windows-only takes both readings: the origin's own flag, and an import that produced nothing
    /// this renderer can show.
    private func installedExtras(for item: WorkshopQueryItem) -> InstalledItemExtras? {
        guard let entry = installedEntry, entry.origin.workshopID == String(item.id) else { return nil }
        let runningOn = screenManager.screens.filter {
            screenManager.getConfiguration(for: $0)?.wpeOrigin?.workshopID == entry.origin.workshopID
        }
        return InstalledItemExtras(
            updateState: .unknown,
            isWindowsOnly: entry.origin.requiresWindowsPlugin
                || entry.origin.originalType == .application || entry.origin.originalType == .unknown,
            inUseOnDisplayNames: runningOn.map(\.name),
            deletesFiles: false,
            localDescription: nil
        )
    }

    private func targets(for item: WorkshopQueryItem) -> [ModalDisplayTarget] {
        let displays = screenManager.screens.map {
            ModalActions.Display(id: $0.id, name: $0.name, frame: $0.frame)
        }
        let activeOn = Set(screenManager.screens
            .filter { screenManager.getConfiguration(for: $0)?.wpeOrigin?.workshopID == String(item.id) }
            .map(\.id))
        return WorkshopModalTargets.make(displays: displays, activeOn: activeOn, covers: covers)
    }

    /// The chosen display, or the default one when nothing is chosen yet or the choice was unplugged.
    private func resolvedTargetID(in targets: [ModalDisplayTarget]) -> CGDirectDisplayID? {
        if let selectedTargetID, targets.contains(where: { $0.id == selectedTargetID }) {
            return selectedTargetID
        }
        return targets.first(where: \.isPrimary)?.id ?? targets.first?.id
    }

    private func targetName(in targets: [ModalDisplayTarget]) -> String {
        targets.first { $0.id == resolvedTargetID(in: targets) }?.name ?? ""
    }

    private func primaryTitle(for item: WorkshopQueryItem, targets: [ModalDisplayTarget]) -> String {
        WorkshopModalContent.primaryActionTitle(
            installed: installedExtras(for: item) != nil,
            ticketState: wiring.ticket(for: item.id)?.state,
            screenName: targetName(in: targets)
        )
    }

    private func isPrimaryEnabled(for item: WorkshopQueryItem, targets: [ModalDisplayTarget]) -> Bool {
        guard resolvedTargetID(in: targets) != nil, !item.isBanned else { return false }
        if wiring.ticket(for: item.id)?.state == .applying {
            return false
        }
        return installedExtras(for: item) != nil || doctor.isDownloadReady
    }

    // MARK: Bottom bar

    private func presentation(for item: WorkshopQueryItem) -> WorkshopDownloadPresentation {
        var presentation = WorkshopDownloadPresentation()
        // A settled ticket is the outcome of record; the download phase only describes the transfer.
        switch wiring.ticket(for: item.id)?.state {
        case .applying:
            presentation.progress = .indeterminate
            presentation.status = WorkshopModalContent.applyingText
            return presentation
        case let .finished(report):
            presentation.status = DeferredApplyToasts.appliedText(report, screenName: settledScreenName(for: item))
            presentation.isFailure = report.outcome != .applied
            return presentation
        case let .downloadOnly(.failed(reason)):
            presentation.status = reason
            presentation.isFailure = true
            return presentation
        case .downloadOnly, .invalidated, .waiting, nil:
            break
        }
        switch downloads.phase(for: item.id) {
        case .downloading:
            let fraction = downloads.progress[item.id]
            presentation.progress = fraction.map { .fraction($0) } ?? .indeterminate
            presentation.status = String(
                localized: "Downloading…", bundle: .appLanguage,
                comment: "Workshop download in progress."
            )
            presentation.detail = WorkshopDownloadPresentation.detailText(
                downloaded: downloads.progressBytes[item.id]?.downloaded,
                total: downloads.progressBytes[item.id]?.total ?? item.fileSizeBytes,
                bytesPerSecond: rateMeter.bytesPerSecond,
                fraction: fraction
            )
        case .importing:
            presentation.progress = .indeterminate
            presentation.status = String(
                localized: "Importing…", bundle: .appLanguage,
                comment: "Workshop item is being imported after download."
            )
        case let .failed(message):
            presentation.status = message
            presentation.isFailure = true
        case .idle, .succeeded, .succeededAsPreset:
            break
        }
        return presentation
    }

    private func settledScreenName(for item: WorkshopQueryItem) -> String {
        guard let ticket = wiring.ticket(for: item.id) else { return "" }
        return screenManager.screens.first { $0.id == ticket.target.screenID }?.name ?? ""
    }

    /// One value so `onChange` fires on every published byte count, including a stall at the same
    /// fraction: the speed has to fall to zero rather than freeze at its last reading.
    private var downloadSample: String {
        guard let presentedItemID else { return "" }
        let bytes = downloads.progressBytes[presentedItemID]?.downloaded ?? 0
        return "\(downloads.activeAttempt(for: presentedItemID)?.id.uuidString ?? "") \(bytes)"
    }

    private func recordRate() {
        guard let presentedItemID else { return }
        rateMeter.record(
            attemptID: downloads.activeAttempt(for: presentedItemID)?.id,
            downloadedBytes: downloads.progressBytes[presentedItemID]?.downloaded,
            at: Date()
        )
    }

    // MARK: Actions

    private var wiring: WorkshopModalWiring {
        WorkshopModalWiring(
            downloads: .init(
                start: { [doctor, items, detachedItem] itemID in
                    let title = (items.first { $0.id == itemID } ?? detachedItem)?.title ?? String(itemID)
                    return WorkshopDownloadCoordinator.shared.download(itemID: itemID, title: title, using: doctor)
                },
                active: { WorkshopDownloadCoordinator.shared.activeAttempt(for: $0) },
                cancel: { WorkshopDownloadCoordinator.shared.cancel($0) }
            ),
            deferredApply: session.deferredApply,
            screens: screenManager
        )
    }

    private func actions(for item: WorkshopQueryItem) -> WorkshopModalActions {
        var cancelDownload: (@MainActor () -> Void)?
        if downloads.isBusy(item.id) {
            cancelDownload = { wiring.cancelDownload(itemID: item.id) }
        }
        return WorkshopModalActions(
            selectTarget: { select($0, for: item) },
            primary: { runPrimary(for: item) },
            saveOnly: { wiring.saveOnly(itemID: item.id) },
            cancelDownload: cancelDownload,
            openInSteam: { openURL(item.steamCommunityURL) },
            reveal: { session.matureReveal.reveal(item.id) },
            openItem: { presentedItemID = $0 },
            selectTag: { tag in
                presentedItemID = nil
                Task { await session.browse.browseTag(tag) }
            },
            browseCreator: { steamID, name in
                presentedItemID = nil
                Task { await session.browse.browseCreator(steamID: steamID, name: name) }
            }
        )
    }

    private func select(_ screenID: CGDirectDisplayID, for item: WorkshopQueryItem) {
        guard wiring.ticket(for: item.id)?.state != .applying else { return }
        selectedTargetID = screenID
        wiring.retarget(itemID: item.id, to: screenID)
    }

    private func runPrimary(for item: WorkshopQueryItem) {
        let targets = targets(for: item)
        guard let screenID = resolvedTargetID(in: targets) else { return }
        if let entry = installedEntry, entry.origin.workshopID == String(item.id) {
            applyNow(entry, to: screenID)
            return
        }
        wiring.applyWhenDownloaded(itemID: item.id, to: screenID)
    }

    /// Already in the library: the same route the library modal takes, with no download in between.
    private func applyNow(_ entry: WPEHistoryEntry, to screenID: CGDirectDisplayID) {
        guard let screen = screenManager.screens.first(where: { $0.id == screenID }) else { return }
        let router = ApplyRouter(
            manager: screenManager, bookmarks: BookmarkStore.shared,
            sceneCapable: featureCatalog.isEnabled(.scene)
        )
        Task { @MainActor in
            let report = await router.apply(.installedWorkshop(entry), to: screen)
            for message in DeferredApplyToasts.messages(for: .finished(report), screenName: screen.name) ?? [] {
                toasts.post(message.text, style: message.style)
            }
        }
    }
}
#endif
