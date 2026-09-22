import Combine
import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation

@MainActor
final class OnboardingSignals {
    struct Inputs {
        var wallpapers: @MainActor () -> [CGDirectDisplayID: WallpaperContent] = { [:] }
        var bookmarks: @MainActor () -> [WallpaperBookmark] = { [] }
        var historyIDs: @MainActor () -> Set<String> = { [] }
        var installWorkshopHooks: @MainActor (
            @escaping @MainActor () -> Void, @escaping @MainActor (Int) -> Void
        ) -> Void = { _, _ in }

        @MainActor
        static func live(screenManager: ScreenManager) -> Inputs {
            var inputs = Inputs()
            inputs.wallpapers = {
                Dictionary(uniqueKeysWithValues: screenManager.screens.compactMap { screen in
                    screenManager.getConfiguration(for: screen).map { (screen.id, $0.activeWallpaper) }
                })
            }
            inputs.bookmarks = { BookmarkStore.shared.bookmarks }
            #if !LITE_BUILD
            inputs.historyIDs = { Set(SettingsManager.shared.loadGlobalSettings().recentWPEImports.map(\.id)) }
            #endif
            return inputs
        }
    }

    private let progress: OnboardingProgress
    private let inputs: Inputs
    private var baselineWallpapers: [CGDirectDisplayID: WallpaperContent] = [:]
    private var baselineLibrary: Set<String> = []
    private var subscriptions: Set<AnyCancellable> = []

    init(progress: OnboardingProgress, inputs: Inputs, notificationCenter: NotificationCenter = .default) {
        self.progress = progress
        self.inputs = inputs
        rebaseline()
        notificationCenter.publisher(for: .wallpaperConfigurationDidChange)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor @Sendable [weak self] in self?.recordWallpaperChange() }
            }
            .store(in: &subscriptions)
        #if !LITE_BUILD
        notificationCenter.publisher(for: .wpeHistoryDidChange)
            .sink { @Sendable [weak self] _ in
                Task { @MainActor @Sendable [weak self] in self?.recordLibraryGrowth() }
            }
            .store(in: &subscriptions)
        #endif
        observeBookmarks()
        inputs.installWorkshopHooks(
            { [weak self] in self?.progress.record(.workshop) },
            { [weak self] count in
                if count > 0 {
                    self?.progress.record(.workshop)
                }
            }
        )
    }

    func rebaseline() {
        baselineWallpapers = inputs.wallpapers()
        baselineLibrary = libraryIdentities()
    }

    private func recordWallpaperChange() {
        // Match the apply router's source identity: resolved video URL/entry, HTML source,
        // or scene Workshop/preset ID. Playback and HTML rendering settings are not identity.
        if inputs.wallpapers().contains(where: { id, content in
            !ApplyRouter.contentMatches(baselineWallpapers[id], content)
        }) {
            progress.record(.home)
        }
    }

    private func libraryIdentities() -> Set<String> {
        Set(inputs.bookmarks().map { "bookmark:\($0.id)" })
            .union(inputs.historyIDs().map { "workshop:\($0)" })
    }

    private func recordLibraryGrowth() {
        if !libraryIdentities().subtracting(baselineLibrary).isEmpty {
            progress.record(.library)
        }
    }

    private func observeBookmarks() {
        withObservationTracking {
            _ = inputs.bookmarks()
        } onChange: { @Sendable [weak self] in
            Task { @MainActor @Sendable [weak self] in
                self?.recordLibraryGrowth()
                self?.observeBookmarks()
            }
        }
    }
}
