import CoreGraphics
import CryptoKit
import Foundation
import LiveWallpaperCore
import Observation

extension Notification.Name {
    /// Only an explicit per-display clear posts this; turning wallpapers off or unplugging a display must not.
    static let wallpaperSelectionCleared = Notification.Name("WallpaperSelectionCleared")
}

extension Notification {
    /// `UInt32` display ID carried by `wallpaperSelectionCleared`.
    static let clearedDisplayIDKey = "displayID"
}

#if !MAS_BUILD
/// Serial preparation with the latest selection winning on each display. Never starts web capture.
@MainActor
@Observable
final class SystemWallpaperSelectionCoordinator {
    private struct Selection {
        let configuration: ScreenConfiguration
        let title: String
        let key: String
        let clearGeneration: Int
        let displayClearGeneration: Int
        let options: SystemWallpaperPreparationOptions
        let copyID: String

        var token: String {
            "\(clearGeneration)-\(displayClearGeneration)-\(copyID)"
        }
    }

    private(set) var followState = SystemWallpaperFollowState()
    @ObservationIgnored private let service: WallpaperExportService
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let displaySize: (UInt32) -> CGSize
    @ObservationIgnored private var selections: [UInt32: Selection] = [:]
    @ObservationIgnored private var pending: [UInt32: Selection] = [:]
    @ObservationIgnored private var attempted: [UInt32: String] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var preparingDisplay: UInt32?
    @ObservationIgnored private var preparingToken: String?

    @ObservationIgnored private var displayClearGenerations: [UInt32: Int] = [:]
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var clearObserver: (any NSObjectProtocol)?

    init(service: WallpaperExportService, defaults: UserDefaults = .appScoped(),
         notificationCenter: NotificationCenter = .default,
         displaySize: @escaping (UInt32) -> CGSize = { display in
             guard let mode = CGDisplayCopyDisplayMode(display) else { return .zero }
             return CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
         }) {
        self.service = service
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.displaySize = displaySize
        // Posted from the main actor; a nil queue runs the block on the posting thread.
        clearObserver = notificationCenter.addObserver(forName: .wallpaperSelectionCleared, object: nil, queue: nil) { [weak self] note in
            guard let displayID = note.userInfo?[Notification.clearedDisplayIDKey] as? UInt32 else { return }
            MainActor.assumeIsolated { self?.clear(displayID: displayID) }
        }
        service.onItemPublished = { [weak self] key in
            guard let self else { return }
            for (display, selection) in selections where selection.key == key {
                if case .html = selection.configuration.activeWallpaper {
                    attempted[display] = nil
                    enqueue(selection, display: display)
                }
            }
            startWorker()
        }
        service.onHeartbeatRefreshed = { [weak self] in
            guard let self else { return }
            for (display, selection) in selections {
                if selection.clearGeneration != service.clearGeneration {
                    followState.displays[display] = nil
                } else {
                    follow(selection.configuration, title: selection.title)
                }
            }
            startWorker()
        }
        service.followCoordinator = self
    }

    /// A failed or cancelled display stays so until `retry(displayID:)` or a different selection; session changes re-follow every display.
    func follow(_ configuration: ScreenConfiguration, title: String) {
        do {
            let content = configuration.activeWallpaper
            let key = try WallpaperExportService.sourceKey(for: content)
            let options = SystemWallpaperFollowPreferences.options(defaults: defaults, displaySize: displaySize(configuration.screenID))
            var copyID = WallpaperExportService.selectionCopyIDPrefix + key
            if case .scene = content {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                try copyID += "-" + SHA256.hash(data: encoder.encode(options)).map { String(format: "%02x", $0) }.joined()
            }
            let display = configuration.screenID
            let selection = Selection(configuration: configuration, title: title, key: key,
                                      clearGeneration: service.clearGeneration,
                                      displayClearGeneration: displayClearGenerations[display, default: 0],
                                      options: options, copyID: copyID)
            if selections[display]?.token != selection.token, preparingDisplay == display,
               followState.displays[display]?.phase == .preparing {
                service.cancelPreparation()
                worker?.cancel()
            }
            selections[display] = selection
            if let state = followState.displays[display], attempted[display] == selection.token {
                setPhase(state.phase, for: selection, display: display)
            }
            enqueue(selection, display: display)
            startWorker()
        } catch {
            service.reportPublishFailures([error.localizedDescription])
        }
    }

    func retry(displayID: UInt32) {
        guard let phase = followState.displays[displayID]?.phase, let selection = selections[displayID] else { return }
        switch phase {
        case .failed, .cancelled: break
        default: return
        }
        attempted[displayID] = nil
        follow(selection.configuration, title: selection.title)
    }

    /// The bumped generation keeps a late result of the old token from passing `isCurrent`, and lets the same content be followed again.
    func clear(displayID: UInt32) {
        let generation = displayClearGenerations[displayID, default: 0] + 1
        do {
            try service.clearSelection(for: displayID, generation: generation)
        } catch {
            service.reportPublishFailures([error.localizedDescription])
            return
        }
        displayClearGenerations[displayID] = generation
        if preparingDisplay == displayID, followState.displays[displayID]?.phase == .preparing {
            service.cancelPreparation()
            // A video copy publishes directly on the worker, outside the preparation task.
            worker?.cancel()
        }
        selections[displayID] = nil
        pending[displayID] = nil
        attempted[displayID] = nil
        followState.displays[displayID] = nil
    }

    func stop() {
        if let clearObserver {
            notificationCenter.removeObserver(clearObserver)
            self.clearObserver = nil
        }
        worker?.cancel()
        pending.removeAll()
        selections.removeAll()
        attempted.removeAll()
        followState = .init()
    }

    private func enqueue(_ selection: Selection, display: UInt32) {
        guard isCurrent(selection, display: display), attempted[display] != selection.token,
              !(preparingDisplay == display && preparingToken == selection.token), pending[display]?.token != selection.token else { return }
        pending[display] = selection
        setPhase(.queued, for: selection, display: display)
    }

    private func setPhase(_ phase: SystemWallpaperFollowState.Phase, for selection: Selection, display: UInt32) {
        followState.displays[display] = .init(displayID: display, title: selection.title, sourceKey: selection.key, phase: phase)
    }

    private func startWorker() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                worker = nil
                startWorker()
            }
            while !pending.isEmpty, !Task.isCancelled {
                guard let display = pending.keys.min(), let selection = pending.removeValue(forKey: display) else { break }
                preparingDisplay = display
                preparingToken = selection.token
                defer { preparingDisplay = nil; preparingToken = nil }
                do {
                    while service.preparationProgress != nil {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try Task.checkCancellation()
                    guard isCurrent(selection, display: display), service.showsSelectedTile(on: display) else { continue }
                    let itemID: String
                    // Publishes append, so the last match is the newest copy.
                    if let prepared = service.items.last(where: {
                        guard $0.sourceKey == selection.key else { return false }
                        if case .scene = selection.configuration.activeWallpaper {
                            return $0.preparationOptions == selection.options
                        }
                        return true
                    }) {
                        itemID = prepared.id
                    } else {
                        guard #available(macOS 26.0, *) else { continue }
                        // Web capture requires an explicit recording; publication wakes this selection.
                        if case .html = selection.configuration.activeWallpaper {
                            attempted[display] = selection.token
                            setPhase(.needsRecording, for: selection, display: display)
                            continue
                        }
                        itemID = selection.copyID
                        setPhase(.preparing, for: selection, display: display)
                        try await service.prepareAndPublish(
                            content: selection.configuration.activeWallpaper, title: selection.title, id: itemID,
                            options: selection.options, origin: selection.configuration.wpeOrigin
                        )
                    }
                    try Task.checkCancellation()
                    guard isCurrent(selection, display: display) else { continue }
                    try service.selectItem(itemID, for: display)
                    attempted[display] = selection.token
                    setPhase(.ready(itemID: itemID), for: selection, display: display)
                } catch is CancellationError {
                    if isCurrent(selection, display: display) {
                        attempted[display] = selection.token
                        setPhase(.cancelled, for: selection, display: display)
                    }
                } catch {
                    if isCurrent(selection, display: display) {
                        attempted[display] = selection.token
                        setPhase(.failed(message: error.localizedDescription), for: selection, display: display)
                        service.reportPublishFailures([selection.title + ": " + error.localizedDescription])
                    }
                }
            }
        }
    }

    private func isCurrent(_ selection: Selection, display: UInt32) -> Bool {
        selections[display]?.token == selection.token && service.clearGeneration == selection.clearGeneration
    }
}
#endif
