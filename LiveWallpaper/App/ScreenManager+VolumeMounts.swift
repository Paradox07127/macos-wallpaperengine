import AppKit
import Combine
import Foundation
import LiveWallpaperCore

extension ScreenManager {
    func observeVolumeMounts() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.reloadScreensAfterVolumeMount()
            }
            .store(in: &cleanupTasks)
    }

    func reloadScreensAfterVolumeMount() {
        guard !isTerminating else { return }
        for screen in screens {
            let hasHealthySession = screen.runtimeSession != nil && runtimeError(for: screen) == nil
            guard Self.needsReloadAfterVolumeMount(
                configuration: configurationStore.get(for: screen.id, fingerprint: screen.displayFingerprint),
                hasHealthySession: hasHealthySession,
                volumeIsUnavailable: SettingsManager.isBookmarkVolumeUnavailable
            ) else { continue }
            Logger.info("Volume mounted; reloading wallpaper for screen \(screen.id)", category: .screenManager)
            reloadWallpaperForScreen(screen)
        }
    }

    /// Only bookmark-backed video and local HTML can be stranded by an unmounted volume.
    nonisolated static func needsReloadAfterVolumeMount(
        configuration: ScreenConfiguration?,
        hasHealthySession: Bool,
        volumeIsUnavailable: (Data) -> Bool
    ) -> Bool {
        guard !hasHealthySession,
              let configuration,
              let definition = WallpaperSessionDefinition(configuration: configuration) else { return false }
        let bookmarkData: Data
        switch definition {
        case let .video(data, _),
             let .html(.file(data), _),
             let .html(.folder(data, _), _):
            bookmarkData = data
        case .html(.inline, _), .html(.url, _), .scene:
            return false
        }
        return !volumeIsUnavailable(bookmarkData)
    }
}
