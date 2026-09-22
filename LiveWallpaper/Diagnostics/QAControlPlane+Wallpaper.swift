#if DEBUG
import CoreGraphics
import Foundation
import LiveWallpaperCore

@MainActor
extension QAControlPlane {
    // MARK: - Wallpapers

    /// Identity only — applying a bookmark is done by id.
    func wallpaperList() throws -> Any {
        let bookmarks = SettingsManager.shared.loadWallpaperBookmarks().map { bookmark -> [String: Any] in
            [
                "id": bookmark.id.uuidString,
                "label": bookmark.label,
                "type": bookmark.wallpaperType.rawValue,
                "sourceDisplayName": bookmark.sourceDisplayName ?? NSNull(),
                "createdAt": ISO8601DateFormatter().string(from: bookmark.createdAt),
            ]
        }
        return ["bookmarks": bookmarks, "count": bookmarks.count]
    }

    func wallpaperApply(_ arguments: [String: Any]) throws -> Any {
        let screen = try resolveScreen(arguments)
        guard let rawID = arguments["bookmarkID"] as? String, let id = UUID(uuidString: rawID) else {
            throw QAError.message("Missing or malformed bookmarkID")
        }
        guard let bookmark = SettingsManager.shared.loadWallpaperBookmarks().first(where: { $0.id == id }) else {
            throw QAError.message("No bookmark with id \(rawID); call wallpaper.list")
        }
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        // A bookmark is content only — per-screen volume, fit mode and effects are left
        // alone (the whole-screen counterpart is a Scheme).
        manager.applyBookmark(bookmark, to: screen)
        return [
            "status": "accepted",
            "bookmarkID": rawID,
            "screenID": screen.id,
            "type": bookmark.wallpaperType.rawValue,
            "note": "Loading is asynchronous — poll state.dump for wallpaperType and activity.",
        ]
    }

    func wallpaperClear(_ arguments: [String: Any]) throws -> Any {
        let screen = try resolveScreen(arguments)
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        manager.clearWallpaperForScreen(screen)
        return ["status": "cleared", "screenID": screen.id]
    }

    func wallpaperTogglePlayback(_ arguments: [String: Any]) throws -> Any {
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        if arguments["screenID"] == nil {
            manager.togglePlayback()
            return ["status": "accepted", "scope": "all"]
        }
        let screen = try resolveScreen(arguments)
        manager.togglePlayback(for: screen)
        return ["status": "accepted", "scope": "screen", "screenID": screen.id]
    }

    // MARK: - Per-screen configuration

    func screenGet(_ arguments: [String: Any]) throws -> Any {
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        let screens = try arguments["screenID"] == nil ? manager.screens : [resolveScreen(arguments)]
        let entries = screens.map { screen -> [String: Any] in
            guard let config = configuration(for: screen) else {
                return ["screenID": screen.id, "name": screen.name, "configured": false]
            }
            return [
                "screenID": screen.id,
                "name": screen.name,
                "configured": true,
                "wallpaperType": config.wallpaperType.rawValue,
                "playbackSpeed": config.playbackSpeed,
                "muted": config.muted,
                "videoVolume": config.videoVolume,
                "videoColorSpace": config.videoColorSpace.rawValue,
                "videoDisplayMode": config.videoDisplayMode.rawValue,
                "fitMode": config.fitMode.rawValue,
                "frameRateLimit": config.frameRateLimit.rawValue,
                "sceneMouseInteractionEnabled": config.sceneMouseInteractionEnabled,
                "sceneClickCaptureEnabled": config.sceneClickCaptureEnabled,
                "setAsLockScreen": config.setAsLockScreen,
                "wallpaperMode": config.wallpaperMode.rawValue,
                "shufflePlaylist": config.shufflePlaylist,
                "queueCursor": config.playlistCursorIndex ?? 0,
                "queue": config.effectiveWallpaperQueue.map { ["id": $0.id, "title": $0.title, "type": $0.content.wallpaperType.rawValue] },
                "schedule": (config.scheduleSlots ?? []).map { slot -> [String: Any] in
                    ["start": slot.startHour, "end": slot.endHour, "title": slot.wallpaper?.title ?? slot.label,
                     "type": slot.wallpaper?.content.wallpaperType.rawValue ?? "video"]
                },
            ]
        }
        return ["screens": entries, "writableKeys": Self.screenWritableKeys.sorted()]
    }

    func runtimeState(_ arguments: [String: Any]) throws -> Any {
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        let screens = try arguments["screenID"] == nil ? manager.screens : [resolveScreen(arguments)]
        let entries = screens.map { screen -> [String: Any] in
            var entry: [String: Any] = ["screenID": screen.id, "name": screen.name]
            guard let session = screen.runtimeSession else {
                entry["hasSession"] = false
                return entry
            }
            entry["hasSession"] = true
            entry["sessionType"] = session.wallpaperType.rawValue
            if let playback = screen.playbackController {
                entry["isPlaying"] = playback.isPlaying
                entry["userIntendsToPlay"] = playback.userIntendsToPlay
            }
            #if !LITE_BUILD
            if let scene = session as? SceneWallpaperSession {
                if let activity = scene.rendererRuntimeActivity {
                    entry["producesFrames"] = activity.producesFrames
                    entry["audible"] = activity.audible
                }
                if let diagnostics = scene.rendererDiagnostics {
                    entry["shaderErrorCount"] = diagnostics.shaderErrors.count
                    entry["gpuErrorCount"] = diagnostics.gpuErrors.count
                    entry["lastGPUError"] = diagnostics.gpuErrors.last ?? NSNull()
                }
            }
            #endif
            return entry
        }
        return [
            "screens": entries,
            "note": "Runtime getters exist only for playback and renderer activity. "
                + "Volume, frame-rate ceiling and fit mode are push-only — verify those by observation, not by reading back.",
        ]
    }

    static let screenWritableKeys: Set<String> = [
        "playbackSpeed", "muted", "videoVolume", "videoColorSpace", "videoDisplayMode",
        "fitMode", "frameRateLimit", "sceneMouseInteractionEnabled", "sceneClickCaptureEnabled",
    ]

    /// Parse every value before any setter runs so a bad field cannot leave a half-applied patch. Build enums from RawValue — tolerant decoders would silently accept a typo.
    func screenPatch(_ arguments: [String: Any]) throws -> Any {
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        let screen = try resolveScreen(arguments)
        var patch = arguments
        patch.removeValue(forKey: "screenID")
        guard !patch.isEmpty else { throw QAError.message("Empty patch") }

        let unknown = patch.keys.filter { !Self.screenWritableKeys.contains($0) }
        guard unknown.isEmpty else {
            throw QAError.message("Not writable: \(unknown.sorted().joined(separator: ", "))")
        }
        guard configuration(for: screen) != nil else {
            throw QAError.message("Screen \(screen.id) has no configuration yet; apply a wallpaper first")
        }

        var pending: [(String, @MainActor () -> Void)] = []
        for (key, value) in patch {
            switch key {
            case "playbackSpeed":
                let speed = try Self.number(value, key)
                pending.append((key, { manager.updatePlaybackSpeed(speed, for: screen) }))
            case "muted":
                let muted = try Self.boolean(value, key)
                pending.append((key, { manager.updateMuted(muted, for: screen) }))
            case "videoVolume":
                let volume = try Self.number(value, key)
                pending.append((key, { manager.updateVideoVolume(volume, for: screen) }))
            case "videoColorSpace":
                let space: VideoColorSpace = try Self.rawRepresentable(value, key)
                pending.append((key, { manager.updateVideoColorSpace(space, for: screen) }))
            case "videoDisplayMode":
                let mode: VideoDisplayMode = try Self.rawRepresentable(value, key)
                pending.append((key, { manager.updateVideoDisplayMode(mode, for: screen) }))
            case "fitMode":
                let fit: VideoFitMode = try Self.rawRepresentable(value, key)
                pending.append((key, { manager.updateFitMode(fit, for: screen) }))
            case "frameRateLimit":
                let requested = try Self.number(value, key)
                let maximum = manager.getScreenRefreshRate(for: screen.id)
                guard requested.isFinite, requested == requested.rounded(),
                      requested >= 0, requested <= Double(maximum),
                      let limit = FrameRateLimit(rawValue: Int(requested)) else {
                    throw QAError.message(
                        "Rejected frameRateLimit: use 0 for Max or a whole FPS value from 1 through \(maximum)"
                    )
                }
                pending.append((key, { manager.updateFrameRateLimit(limit, for: screen) }))
            case "sceneMouseInteractionEnabled":
                let enabled = try Self.boolean(value, key)
                pending.append((key, { manager.updateSceneMouseInteraction(enabled, for: screen) }))
            case "sceneClickCaptureEnabled":
                let enabled = try Self.boolean(value, key)
                pending.append((key, { manager.updateSceneClickCapture(enabled, for: screen) }))
            default:
                throw QAError.message("Not writable: \(key)")
            }
        }

        for (_, apply) in pending {
            apply()
        }
        // Read back through the store: several setters short-circuit on an unchanged value.
        return try [
            "status": "applied",
            "screenID": screen.id,
            "applied": pending.map(\.0).sorted(),
            "screen": screenGet(["screenID": screen.id]),
        ]
    }

    // MARK: - Parsing

    private func resolveScreen(_ arguments: [String: Any]) throws -> Screen {
        guard let manager = screenManager else { throw QAError.message("ScreenManager unavailable") }
        guard let raw = arguments["screenID"] as? NSNumber else {
            throw QAError.message("Missing screenID; call state.dump for the list")
        }
        let id = CGDirectDisplayID(truncating: raw)
        guard let screen = manager.screens.first(where: { $0.id == id }) else {
            throw QAError.message("No screen with id \(id); call state.dump for the list")
        }
        return screen
    }

    private func configuration(for screen: Screen) -> ScreenConfiguration? {
        SettingsManager.shared.getConfiguration(for: screen.id)
    }

    private static func boolean(_ value: Any, _ key: String) throws -> Bool {
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let flag = value as? Bool else {
            throw QAError.message("Rejected \(key): expected a boolean")
        }
        return flag
    }

    private static func number(_ value: Any, _ key: String) throws -> Double {
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID(),
              let number = value as? NSNumber else {
            throw QAError.message("Rejected \(key): expected a number")
        }
        return number.doubleValue
    }

    private static func rawRepresentable<T: RawRepresentable & CaseIterable>(
        _ value: Any,
        _ key: String
    ) throws -> T where T.RawValue == String {
        guard let raw = value as? String else {
            throw QAError.message("Rejected \(key): expected a string")
        }
        guard let parsed = T(rawValue: raw) else {
            let allowed = T.allCases.map(\.rawValue).joined(separator: ", ")
            throw QAError.message("Rejected \(key): \"\(raw)\" is not one of \(allowed)")
        }
        return parsed
    }
}
#endif
