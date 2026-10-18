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

        var token: String {
            "\(clearGeneration)-\(key)"
        }
    }

    private let service: WallpaperExportService
    private var selections: [UInt32: Selection] = [:]
    private var pending: [UInt32: Selection] = [:]
    /// Selection token last acted on per display, so heartbeat refreshes do not retry a finished or failed attempt.
    private var attempted: [UInt32: String] = [:]
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
        service.onHeartbeatRefreshed = { [weak self] in
            guard let self else { return }
            for (display, selection) in selections where attempted[display] != selection.token {
                pending[display] = selection
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
                    guard isCurrent(selection, display: display), service.showsSelectedTile(on: display) else { continue }
                    attempted[display] = selection.token
                    let itemID: String
                    if let prepared = service.items.first(where: { $0.sourceKey == selection.key }) {
                        itemID = prepared.id
                    } else {
                        guard #available(macOS 26.0, *) else { continue }
                        // Web capture is never started here; `onItemPublished` follows a copy prepared by hand.
                        if case .html = selection.configuration.activeWallpaper {
                            continue
                        }
                        itemID = WallpaperExportService.selectionCopyIDPrefix + selection.key
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
