import Foundation
import LiveWallpaperCore

/// Serial preparation with the latest selection winning on each display. Never starts web capture.
@MainActor
final class SystemWallpaperSelectionCoordinator {
    private struct Selection {
        let configuration: ScreenConfiguration
        let title: String
        let key: String
        let clearGeneration: Int
    }

    private let service: WallpaperExportService
    private var selections: [UInt32: Selection] = [:]
    private var pending: [UInt32: Selection] = [:]
    private var worker: Task<Void, Never>?
    private var preparingDisplay: UInt32?

    init(service: WallpaperExportService) {
        self.service = service
        service.onItemPublished = { [weak self] key in
            guard let self else { return }
            for (display, selection) in selections where selection.key == key {
                if case .html = selection.configuration.activeWallpaper {
                    pending[display] = selection
                }
            }
            startWorker()
        }
    }

    func follow(_ configuration: ScreenConfiguration, title: String) {
        if let previous = selections[configuration.screenID],
           previous.configuration.activeWallpaper == configuration.activeWallpaper,
           previous.clearGeneration == service.clearGeneration {
            return
        }
        do {
            let key = try WallpaperExportService.sourceKey(for: configuration.activeWallpaper)
            let selection = Selection(configuration: configuration, title: title, key: key, clearGeneration: service.clearGeneration)
            selections[configuration.screenID] = selection
            pending[configuration.screenID] = selection
            if preparingDisplay == configuration.screenID {
                service.cancelPreparation()
            }
            startWorker()
        } catch {
            service.reportPublishFailures([error.localizedDescription])
        }
    }

    func stop() {
        worker?.cancel()
        pending.removeAll()
    }

    private func startWorker() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { worker = nil }
            while !pending.isEmpty, !Task.isCancelled {
                guard let display = pending.keys.min(), let selection = pending.removeValue(forKey: display) else { break }
                do {
                    while service.preparationProgress != nil {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard isCurrent(selection, display: display) else { continue }
                    let itemID: String
                    if let prepared = service.items.first(where: { $0.sourceKey == selection.key }) {
                        itemID = prepared.id
                    } else {
                        guard #available(macOS 26.0, *) else { continue }
                        if case .html = selection.configuration.activeWallpaper {
                            service.reportPublishFailures([
                                String(localized: "Prepare this web wallpaper in System Wallpaper › Add Wallpaper first. The selected tile will follow it when the video copy is ready.", bundle: .appLanguage),
                            ])
                            continue
                        }
                        itemID = "selected-" + selection.key
                        preparingDisplay = display
                        defer { preparingDisplay = nil }
                        try await service.prepareAndPublish(
                            content: selection.configuration.activeWallpaper, title: selection.title, id: itemID,
                            options: .init(), origin: selection.configuration.wpeOrigin
                        )
                    }
                    try Task.checkCancellation()
                    guard isCurrent(selection, display: display) else { continue }
                    try service.selectItem(itemID, for: display)
                } catch is CancellationError {
                    // Clearing/removing the library and stopping the app are intentional cancellation.
                } catch {
                    if isCurrent(selection, display: display) {
                        service.reportPublishFailures([selection.title + ": " + error.localizedDescription])
                    }
                }
            }
        }
    }

    private func isCurrent(_ selection: Selection, display: UInt32) -> Bool {
        selections[display]?.key == selection.key && service.clearGeneration == selection.clearGeneration
    }
}
