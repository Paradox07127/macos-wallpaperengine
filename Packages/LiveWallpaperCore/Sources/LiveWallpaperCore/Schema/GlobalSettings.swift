import Foundation

/// Keys we only ever read, to carry a retired preference's intent forward.
/// Never used for encoding — the properties they fed no longer exist.
private enum RetiredKeys: String, CodingKey {
    case pauseInGameMode
}

public struct GlobalSettings: Codable, Sendable {
    public var globalPauseOnBattery: Bool
    public var preservePlaybackOnLock: Bool
    public var startOnLogin: Bool
    public var pauseOnFullScreen: Bool
    /// Pause when non-system windows cover ≥85% of a display.
    public var pauseOnWindowOcclusion: Bool
    /// Yield the GPU while macOS is in Low Power Mode, unless the user opts out.
    public var pauseInLowPowerMode: Bool
    /// Dock + Cmd+Tab (`.regular`) vs menu-bar-only (`.accessory`); live, no relaunch.
    public var showInDock: Bool
    public var weatherLocation: WeatherLocationPreference
    /// Hot keys on/off without discarding persisted per-action bindings.
    public var globalShortcutsEnabled: Bool = true

    /// `nil` value = unbound; missing key = platform default binding.
    public var globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?]
    /// LRU recent WPE imports (cap `SettingsManager.maxRecentWPEImports`); newest first.
    public var recentWPEImports: [WPEHistoryEntry] = []
    /// Workshop IDs excluded from auto re-import after explicit deletion.
    public var deletedWorkshopIDs: [String] = []
    /// Per-app pause-while-active rules (NSWorkspace events; no idle polling).
    public var applicationPerformanceRules: [ApplicationPerformanceRule] = []
    /// Per-screen resident video budget; zero disables caching.
    public var videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes

    /// Defaults for new/reset displays only — does not mutate live configs.
    public var displayDefaults: DisplayDefaults = DisplayDefaults()

    /// Monitor widget overlay per display, keyed by `NSScreen.displayFingerprint`.
    /// Not on `ScreenConfiguration`: clearing a wallpaper removes that whole entry,
    /// and the overlay has to outlive it (and exist on a display with no wallpaper).
    public var monitorOverlays: [String: MonitorOverlayConfiguration] = [:]

    /// User-assigned display names, keyed by `NSScreen.displayFingerprint`.
    /// Lives here for the same reason as `monitorOverlays`: clearing a wallpaper
    /// deletes that display's whole `ScreenConfiguration`, and the name has to
    /// survive it.
    public var screenNames: [String: String] = [:]

    /// Opt-in TCC system-audio capture for audio-reactive Pro wallpapers.
    public var audioResponseEnabled: Bool = false

    /// Lower frame rate when covered or on battery.
    public var adaptiveFrameRateEnabled: Bool = false

    /// Whether screenshots, screen recording, and meeting screen-share can read
    /// the wallpaper. Off substitutes the static macOS desktop picture in every
    /// capture, which also keeps a full-screen animation out of a shared stream.
    public var wallpaperVisibleInScreenCapture: Bool = true

    /// Preset library, keyed by `ScenePreset.id`. Global rather than per-screen
    /// so one saved look can be applied to any display showing that scene.
    public var scenePresets: [String: ScenePreset] = [:]

    public static let defaultVideoCacheBytes: Int = 150 * 1024 * 1024
    /// Settings slider ceiling (RAM / auto-policy guard).
    public static let maxVideoCacheBytes: Int = 1024 * 1024 * 1024

    /// Clamps budgets; zero remains the caching opt-out.
    public static func clampedVideoCacheBytes(_ value: Int) -> Int {
        if value < 0 { return defaultVideoCacheBytes }
        return min(value, maxVideoCacheBytes)
    }

    public init(
        globalPauseOnBattery: Bool = false,
        preservePlaybackOnLock: Bool = false,
        startOnLogin: Bool = false,
        pauseOnFullScreen: Bool = true,
        pauseOnWindowOcclusion: Bool = true,
        pauseInLowPowerMode: Bool = true,
        showInDock: Bool = false,
        weatherLocation: WeatherLocationPreference = .default,
        globalShortcutsEnabled: Bool = true,
        globalShortcuts: [GlobalShortcutAction.RawAction: GlobalShortcutBinding?] = [:],
        recentWPEImports: [WPEHistoryEntry] = [],
        deletedWorkshopIDs: [String] = [],
        applicationPerformanceRules: [ApplicationPerformanceRule] = [],
        videoCacheMaxBytesPerScreen: Int = GlobalSettings.defaultVideoCacheBytes,
        displayDefaults: DisplayDefaults = DisplayDefaults(),
        monitorOverlays: [String: MonitorOverlayConfiguration] = [:],
        screenNames: [String: String] = [:],
        audioResponseEnabled: Bool = false,
        adaptiveFrameRateEnabled: Bool = false,
        wallpaperVisibleInScreenCapture: Bool = true
    ) {
        self.globalPauseOnBattery = globalPauseOnBattery
        self.preservePlaybackOnLock = preservePlaybackOnLock
        self.startOnLogin = startOnLogin
        self.pauseOnFullScreen = pauseOnFullScreen
        self.pauseOnWindowOcclusion = pauseOnWindowOcclusion
        self.pauseInLowPowerMode = pauseInLowPowerMode
        self.showInDock = showInDock
        self.weatherLocation = weatherLocation
        self.globalShortcutsEnabled = globalShortcutsEnabled
        self.globalShortcuts = globalShortcuts
        self.recentWPEImports = recentWPEImports
        self.deletedWorkshopIDs = deletedWorkshopIDs
        self.applicationPerformanceRules = applicationPerformanceRules
        self.videoCacheMaxBytesPerScreen = Self.clampedVideoCacheBytes(videoCacheMaxBytesPerScreen)
        self.displayDefaults = displayDefaults
        self.monitorOverlays = monitorOverlays
        self.screenNames = screenNames
        self.audioResponseEnabled = audioResponseEnabled
        self.adaptiveFrameRateEnabled = adaptiveFrameRateEnabled
        self.wallpaperVisibleInScreenCapture = wallpaperVisibleInScreenCapture
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        globalPauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .globalPauseOnBattery) ?? false
        preservePlaybackOnLock = try c.decodeIfPresent(Bool.self, forKey: .preservePlaybackOnLock) ?? false
        startOnLogin = try c.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        pauseOnFullScreen = try c.decodeIfPresent(Bool.self, forKey: .pauseOnFullScreen) ?? true
        // Predates-key installs → true; explicit false still wins once encoded.
        pauseOnWindowOcclusion = (try? c.decodeIfPresent(Bool.self, forKey: .pauseOnWindowOcclusion)) ?? true
        // Predates-key installs → true, matching the shipping default of the
        // retired game/Low-Power-Mode toggle this replaces. When that retired key
        // is present, inherit it: its own subtitle read "…or macOS enters Low
        // Power Mode", so a user who switched it off was opting out of this too.
        // The key is read but never re-encoded, so it disappears on first save.
        if let stored = (try? c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode)) ?? nil {
            pauseInLowPowerMode = stored
        } else if let legacy = try? decoder.container(keyedBy: RetiredKeys.self),
                  let inherited = (try? legacy.decodeIfPresent(Bool.self, forKey: .pauseInGameMode)) ?? nil {
            pauseInLowPowerMode = inherited
        } else {
            pauseInLowPowerMode = true
        }
        showInDock = try c.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        weatherLocation = (try? c.decodeIfPresent(WeatherLocationPreference.self, forKey: .weatherLocation)) ?? .default
        globalShortcutsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .globalShortcutsEnabled)) ?? true
        globalShortcuts = (try? c.decodeIfPresent([GlobalShortcutAction.RawAction: GlobalShortcutBinding?].self, forKey: .globalShortcuts)) ?? [:]
        // Lossy: one bad history row must not drop the whole list.
        recentWPEImports = Self.decodeLossyArray(WPEHistoryEntry.self, from: c, forKey: .recentWPEImports)
        deletedWorkshopIDs = (try? c.decodeIfPresent([String].self, forKey: .deletedWorkshopIDs)) ?? []
        applicationPerformanceRules = (try? c.decodeIfPresent([ApplicationPerformanceRule].self, forKey: .applicationPerformanceRules)) ?? []
        let storedCache = (try? c.decodeIfPresent(Int.self, forKey: .videoCacheMaxBytesPerScreen)) ?? GlobalSettings.defaultVideoCacheBytes
        videoCacheMaxBytesPerScreen = GlobalSettings.clampedVideoCacheBytes(storedCache)
        displayDefaults = (try? c.decodeIfPresent(DisplayDefaults.self, forKey: .displayDefaults)) ?? DisplayDefaults()
        // Lossy: one unreadable display's overlay must not drop every other display's.
        monitorOverlays = c.decodeLossyStringDictionary(forKey: .monitorOverlays) ?? [:]
        screenNames = (try? c.decodeIfPresent([String: String].self, forKey: .screenNames)) ?? [:]
        audioResponseEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .audioResponseEnabled)) ?? false
        adaptiveFrameRateEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .adaptiveFrameRateEnabled)) ?? false
        // Installs that predate the key get the new default (visible), which is
        // the opposite of the hard-coded behaviour they shipped with — that was
        // the point of making it a setting.
        wallpaperVisibleInScreenCapture = (try? c.decodeIfPresent(Bool.self, forKey: .wallpaperVisibleInScreenCapture)) ?? true
        // Lossy: one unreadable preset must not drop the rest of the library.
        scenePresets = c.decodeLossyStringDictionary(forKey: .scenePresets) ?? [:]
    }

    /// Skip malformed elements; absent/non-array → empty.
    private static func decodeLossyArray<Element: Decodable, Key: CodingKey>(
        _ type: Element.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> [Element] {
        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [Element] = []
        if let count = unkeyed.count { result.reserveCapacity(count) }
        while !unkeyed.isAtEnd {
            let indexBefore = unkeyed.currentIndex
            if let element = try? unkeyed.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? unkeyed.decode(AnyDecodableSkip.self)
            }
            // Bail if the cursor did not advance (avoid infinite loop).
            if unkeyed.currentIndex == indexBefore { break }
        }
        return result
    }
}

/// Advances a lossy unkeyed decoder past one failed element.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

/// Arbitrary strings (display fingerprints, preset ids, property names) as
/// coding keys for dictionary-shaped JSON.
public struct StringDictionaryKey: CodingKey, Sendable {
    public let stringValue: String
    public var intValue: Int? { nil }
    public init?(stringValue: String) { self.stringValue = stringValue }
    public init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer {
    /// Lossy string-keyed dictionary decode: one unreadable value drops that
    /// entry, not the whole map. nil when the key is absent or not an object —
    /// callers that treat "present but empty" differently from "absent" (the
    /// preset map does) branch on that.
    public func decodeLossyStringDictionary<Value: Decodable>(
        forKey key: Key
    ) -> [String: Value]? {
        guard contains(key) else { return nil }
        guard let nested = try? nestedContainer(keyedBy: StringDictionaryKey.self, forKey: key) else {
            return nil
        }
        var result: [String: Value] = [:]
        for nestedKey in nested.allKeys {
            guard let value = try? nested.decode(Value.self, forKey: nestedKey) else { continue }
            result[nestedKey.stringValue] = value
        }
        return result
    }
}
