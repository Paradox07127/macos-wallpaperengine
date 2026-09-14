import Foundation
import LiveWallpaperCore

/// Single commit path for the General page's `GlobalSettings` writes: persistence plus
/// every model-side effect that has to run with it. Settings pages keep owning their
/// own `@State`; a non-SwiftUI writer that calls this reaches the same behavior a user
/// gets from the UI, instead of a disk value nothing reacted to.
@MainActor
enum GlobalSettingsCommit {
    /// The fields the General page owns. Everything else in `GlobalSettings` belongs to
    /// another page, so the commit stays read-modify-write.
    struct GeneralPageFields {
        var globalPauseOnBattery: Bool
        var preservePlaybackOnLock: Bool
        var startOnLogin: Bool
        var pauseOnFullScreen: Bool
        var pauseOnWindowOcclusion: Bool
        var pauseInLowPowerMode: Bool
        var applicationPerformanceRules: [ApplicationPerformanceRule]
        var showInDock: Bool
        var wallpaperVisibleInScreenCapture: Bool
        var videoCacheMaxBytesPerScreen: Int
        var audioResponseEnabled: Bool
        var adaptiveFrameRateEnabled: Bool
        var weatherLocation: WeatherLocationPreference
    }

    /// Which conditional effects fired, so a caller can refresh just the UI that needs it.
    struct Outcome {
        var dockVisibilityChanged = false
        var weatherLocationChanged = false
        var audioResponseChanged = false
    }

    @discardableResult
    static func apply(_ fields: GeneralPageFields, screenManager: ScreenManager) -> Outcome {
        var settings = SettingsManager.shared.loadGlobalSettings()

        var outcome = Outcome()
        outcome.dockVisibilityChanged = settings.showInDock != fields.showInDock
        outcome.weatherLocationChanged = settings.weatherLocation != fields.weatherLocation
        outcome.audioResponseChanged = settings.audioResponseEnabled != fields.audioResponseEnabled

        settings.globalPauseOnBattery = fields.globalPauseOnBattery
        settings.preservePlaybackOnLock = fields.preservePlaybackOnLock
        settings.startOnLogin = fields.startOnLogin
        settings.pauseOnFullScreen = fields.pauseOnFullScreen
        settings.pauseOnWindowOcclusion = fields.pauseOnWindowOcclusion
        settings.pauseInLowPowerMode = fields.pauseInLowPowerMode
        settings.applicationPerformanceRules = fields.applicationPerformanceRules
        settings.showInDock = fields.showInDock
        settings.wallpaperVisibleInScreenCapture = fields.wallpaperVisibleInScreenCapture
        settings.videoCacheMaxBytesPerScreen = fields.videoCacheMaxBytesPerScreen
        settings.audioResponseEnabled = fields.audioResponseEnabled
        settings.adaptiveFrameRateEnabled = fields.adaptiveFrameRateEnabled
        settings.weatherLocation = fields.weatherLocation

        SettingsManager.shared.saveGlobalSettings(settings)
        screenManager.handleGlobalSettingsChanged()

        if outcome.dockVisibilityChanged {
            postAsync(.dockVisibilityDidChange)
        }
        if outcome.weatherLocationChanged {
            postAsync(.weatherLocationPreferenceDidChange)
        }
        #if !LITE_BUILD
        // `setEnabled` early-returns on an unchanged value, so AudioSection's own call
        // after this one is a no-op rather than a second reconcile.
        if outcome.audioResponseChanged {
            SystemAudioCaptureManager.shared.setEnabled(fields.audioResponseEnabled)
        }
        #endif

        return outcome
    }

    /// The Shortcuts page owns the binding table and its master switch; both are
    /// written together because the hotkey manager reads them as one unit.
    struct ShortcutsPageFields {
        var globalShortcutsEnabled: Bool
        var globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?]
    }

    static func apply(_ fields: ShortcutsPageFields) {
        var settings = SettingsManager.shared.loadGlobalSettings()
        settings.globalShortcuts = fields.globalShortcuts
        settings.globalShortcutsEnabled = fields.globalShortcutsEnabled
        SettingsManager.shared.saveGlobalSettings(settings)
        postAsync(.globalShortcutsDidChange)
    }

    /// The Workshop page's browse preferences. Only preset visibility has a
    /// listener; sort and time frame are read fresh the next time Browse opens.
    struct WorkshopPageFields {
        var showsPresetsInBrowse: Bool
        var defaultSort: String
        var defaultTimeFrame: String
    }

    @discardableResult
    static func apply(_ fields: WorkshopPageFields) -> Bool {
        var settings = SettingsManager.shared.loadGlobalSettings()
        let presetVisibilityChanged =
            settings.showsWorkshopPresetsInBrowse != fields.showsPresetsInBrowse
        settings.showsWorkshopPresetsInBrowse = fields.showsPresetsInBrowse
        settings.workshopDefaultSort = fields.defaultSort
        settings.workshopDefaultTimeFrame = fields.defaultTimeFrame
        SettingsManager.shared.saveGlobalSettings(settings)
        if presetVisibilityChanged {
            postAsync(.workshopPresetVisibilityDidChange)
        }
        return presetVisibilityChanged
    }

    /// Deferred so the post lands outside the SwiftUI update that triggered the commit.
    private static func postAsync(_ name: Notification.Name) {
        Task { @MainActor in
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}
