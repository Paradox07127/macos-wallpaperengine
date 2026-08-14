import CoreGraphics
import Foundation

public struct ScreenConfiguration: Codable, Equatable, Sendable {
    /// `var` so apply-to-all can clone a template without recomposing fields.
    public var screenID: UInt32
    public var activeWallpaper: WallpaperContent
    public var savedVideoBookmarkData: Data?
    /// Packaged primary entry (`scene.pkg`); kept across type swap so restore stays windowed.
    public var savedVideoPackageEntryName: String?
    public var savedHTMLSource: HTMLSource?
    public var savedHTMLConfig: HTMLConfig?
    /// Restored on same-scene re-pick after a type switch (keeps propertyOverrides).
    public var savedSceneDescriptor: SceneDescriptor?
    public var playbackSpeed: Double
    public var fitMode: VideoFitMode
    public var videoDisplayMode: VideoDisplayMode = .perDisplay
    public var frameRateLimit: FrameRateLimit

    public var particleEffect: ParticleEffect
    public var effectConfig: VideoEffectConfig
    public var scheduleSlots: [ScheduleSlot]?
    public var playlistBookmarks: [Data]?
    public var shufflePlaylist: Bool
    public var playlistRotationMinutes: Int?
    public var playlistCursorIndex: Int?
    /// Starred primary index in the visible list; nil = legacy pin at 0.
    public var playlistPrimaryIndex: Int?
    public var setAsLockScreen: Bool
    public var wallpaperMode: WallpaperMode = .playlist
    public var muted: Bool = true
    /// Volume separate from `muted` so unmute restores the prior level.
    public var videoVolume: Double = 1.0
    public var videoColorSpace: VideoColorSpace = .auto
    /// Scene cursor-follow (parallax / pointer shaders). Default on (historical always-on).
    public var sceneMouseInteractionEnabled: Bool = true
    /// Scene click capture (steals desktop clicks); orthogonal to cursor-follow. Default off.
    public var sceneClickCaptureEnabled: Bool = false
    /// Workshop provenance; cleared when pickers replace with non-WPE content.
    public var wpeOrigin: WPEOrigin?

    /// EDID fingerprint fallback when `screenID` churns.
    public var displayFingerprint: String?

    private enum CodingKeys: String, CodingKey {
        case screenID
        case activeWallpaper
        case savedVideoBookmarkData
        case savedVideoPackageEntryName
        case savedHTMLSource
        case savedHTMLConfig
        case savedSceneDescriptor
        case playbackSpeed
        case fitMode
        case videoDisplayMode
        case frameRateLimit
        case particleEffect
        case effectConfig
        case scheduleSlots
        case playlistBookmarks
        case shufflePlaylist
        case playlistRotationMinutes
        case playlistCursorIndex
        case playlistPrimaryIndex
        case setAsLockScreen
        case wallpaperMode
        case muted
        case videoVolume
        case videoColorSpace
        case sceneMouseInteractionEnabled
        case sceneClickCaptureEnabled
        case wpeOrigin
        case displayFingerprint
    }

    public init(
        screenID: CGDirectDisplayID,
        wallpaper: WallpaperContent,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        videoDisplayMode: VideoDisplayMode = .perDisplay,
        // nil → `FrameRateLimit.naturalDefault(for:)` (scene 30 / video 60).
        frameRateLimit: FrameRateLimit? = nil,
        particleEffect: ParticleEffect = .none,
        effectConfig: VideoEffectConfig = .default,
        scheduleSlots: [ScheduleSlot]? = nil,
        playlistBookmarks: [Data]? = nil,
        shufflePlaylist: Bool = false,
        playlistRotationMinutes: Int? = nil,
        playlistCursorIndex: Int? = nil,
        setAsLockScreen: Bool = false,
        savedVideoBookmarkData: Data? = nil,
        savedVideoPackageEntryName: String? = nil
    ) {
        self.screenID = screenID
        self.activeWallpaper = wallpaper
        self.savedVideoBookmarkData = savedVideoBookmarkData ?? wallpaper.activeVideoBookmarkData
        self.savedVideoPackageEntryName = savedVideoPackageEntryName ?? wallpaper.packageVideoEntryName
        if case .html(let source, let config) = wallpaper {
            self.savedHTMLSource = source
            self.savedHTMLConfig = config
        }
        self.playbackSpeed = playbackSpeed
        self.fitMode = fitMode
        self.videoDisplayMode = videoDisplayMode
        self.frameRateLimit = frameRateLimit
            ?? FrameRateLimit.naturalDefault(for: wallpaper.wallpaperType)
        self.particleEffect = particleEffect
        self.effectConfig = effectConfig
        self.scheduleSlots = scheduleSlots
        self.playlistBookmarks = playlistBookmarks
        self.shufflePlaylist = shufflePlaylist
        self.playlistRotationMinutes = playlistRotationMinutes
        self.playlistCursorIndex = playlistCursorIndex
        self.setAsLockScreen = setAsLockScreen
    }

    public init(
        screenID: CGDirectDisplayID,
        videoBookmarkData: Data,
        playbackSpeed: Double = 1.0,
        fitMode: VideoFitMode = .aspectFill,
        // Explicit `.fps60` default keeps native pass-through even when callers
        // pass nothing (matches `FrameRateLimit.naturalDefault(for: .video)`).
        frameRateLimit: FrameRateLimit = .fps60,
        particleEffect: ParticleEffect = .none,
        effectConfig: VideoEffectConfig = .default,
        scheduleSlots: [ScheduleSlot]? = nil,
        playlistBookmarks: [Data]? = nil,
        shufflePlaylist: Bool = false,
        playlistRotationMinutes: Int? = nil,
        playlistCursorIndex: Int? = nil,
        setAsLockScreen: Bool = false
    ) {
        self.init(
            screenID: screenID,
            wallpaper: .video(bookmarkData: videoBookmarkData),
            playbackSpeed: playbackSpeed,
            fitMode: fitMode,
            frameRateLimit: frameRateLimit,
            particleEffect: particleEffect,
            effectConfig: effectConfig,
            scheduleSlots: scheduleSlots,
            playlistBookmarks: playlistBookmarks,
            shufflePlaylist: shufflePlaylist,
            playlistRotationMinutes: playlistRotationMinutes,
            playlistCursorIndex: playlistCursorIndex,
            setAsLockScreen: setAsLockScreen,
            savedVideoBookmarkData: videoBookmarkData
        )
    }

    public var wallpaperType: WallpaperType {
        activeWallpaper.wallpaperType
    }

    public var videoBookmarkData: Data? {
        activeWallpaper.activeVideoBookmarkData ?? savedVideoBookmarkData
    }

    /// Primary spliced at `playlistPrimaryIndex`; nil/OOB → legacy `[primary]+extras`.
    public var combinedPlaylist: [Data] {
        guard let primary = savedVideoBookmarkData else { return [] }
        let extras = playlistBookmarks ?? []
        let total = extras.count + 1
        let target = max(0, min(playlistPrimaryIndex ?? 0, total - 1))
        if target <= 0 { return [primary] + extras }
        if target >= extras.count { return extras + [primary] }
        return Array(extras[0..<target]) + [primary] + Array(extras[target...])
    }

    public var hasConfiguredVideoSource: Bool {
        if let bookmarkData = activeWallpaper.activeVideoBookmarkData, !bookmarkData.isEmpty {
            return true
        }
        if let savedVideoBookmarkData, !savedVideoBookmarkData.isEmpty {
            return true
        }
        return false
    }

    public var htmlSource: HTMLSource? {
        activeWallpaper.htmlSource
    }

    public var htmlConfig: HTMLConfig? {
        activeWallpaper.htmlConfig
    }

    public var htmlContent: String? {
        guard let source = activeWallpaper.htmlSource else { return nil }
        switch source {
        case .url(let url): return url.absoluteString
        case .inline(let raw): return raw
        case .file, .folder: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        screenID = try c.decode(UInt32.self, forKey: .screenID)
        playbackSpeed = try c.decodeIfPresent(Double.self, forKey: .playbackSpeed) ?? 1.0
        fitMode = try c.decodeIfPresent(VideoFitMode.self, forKey: .fitMode) ?? .aspectFill
        videoDisplayMode = try c.decodeIfPresent(VideoDisplayMode.self, forKey: .videoDisplayMode) ?? .perDisplay
        frameRateLimit = try c.decodeIfPresent(FrameRateLimit.self, forKey: .frameRateLimit) ?? .fps60
        particleEffect = try c.decodeIfPresent(ParticleEffect.self, forKey: .particleEffect) ?? .none
        effectConfig = try c.decodeIfPresent(VideoEffectConfig.self, forKey: .effectConfig) ?? .default
        scheduleSlots = try c.decodeIfPresent([ScheduleSlot].self, forKey: .scheduleSlots)
        playlistBookmarks = try c.decodeIfPresent([Data].self, forKey: .playlistBookmarks)
        shufflePlaylist = try c.decodeIfPresent(Bool.self, forKey: .shufflePlaylist) ?? false
        playlistRotationMinutes = try c.decodeIfPresent(Int.self, forKey: .playlistRotationMinutes)
        playlistCursorIndex = try c.decodeIfPresent(Int.self, forKey: .playlistCursorIndex)
        playlistPrimaryIndex = try c.decodeIfPresent(Int.self, forKey: .playlistPrimaryIndex)
        setAsLockScreen = try c.decodeIfPresent(Bool.self, forKey: .setAsLockScreen) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        videoVolume = Self.clampedVideoVolume(
            try c.decodeIfPresent(Double.self, forKey: .videoVolume) ?? 1.0
        )
        videoColorSpace = (try? c.decodeIfPresent(VideoColorSpace.self, forKey: .videoColorSpace)) ?? .auto
        sceneMouseInteractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .sceneMouseInteractionEnabled) ?? true
        sceneClickCaptureEnabled = try c.decodeIfPresent(Bool.self, forKey: .sceneClickCaptureEnabled) ?? false

        wallpaperMode = try c.decodeIfPresent(WallpaperMode.self, forKey: .wallpaperMode) ?? .playlist

        savedHTMLSource = try c.decodeIfPresent(HTMLSource.self, forKey: .savedHTMLSource)
        savedHTMLConfig = try c.decodeIfPresent(HTMLConfig.self, forKey: .savedHTMLConfig)
        savedSceneDescriptor = try c.decodeIfPresent(SceneDescriptor.self, forKey: .savedSceneDescriptor)
        wpeOrigin = (try? c.decodeIfPresent(WPEOrigin.self, forKey: .wpeOrigin)) ?? nil
        displayFingerprint = try c.decodeIfPresent(String.self, forKey: .displayFingerprint)
        // Loose video → nil; refined below when active is packaged.
        savedVideoPackageEntryName = try c.decodeIfPresent(String.self, forKey: .savedVideoPackageEntryName)

        let decodedWallpaper = try c.decode(WallpaperContent.self, forKey: .activeWallpaper)
        activeWallpaper = decodedWallpaper
        savedVideoBookmarkData = try c.decodeIfPresent(Data.self, forKey: .savedVideoBookmarkData)
            ?? decodedWallpaper.activeVideoBookmarkData
        if savedVideoPackageEntryName == nil {
            savedVideoPackageEntryName = decodedWallpaper.packageVideoEntryName
        }
        if savedHTMLSource == nil, case .html(let source, let config) = decodedWallpaper {
            savedHTMLSource = source
            savedHTMLConfig = config
        }
        if savedSceneDescriptor == nil, case .scene(let descriptor) = decodedWallpaper {
            savedSceneDescriptor = descriptor
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screenID, forKey: .screenID)
        try c.encode(activeWallpaper, forKey: .activeWallpaper)
        try c.encodeIfPresent(savedVideoBookmarkData, forKey: .savedVideoBookmarkData)
        try c.encodeIfPresent(savedVideoPackageEntryName, forKey: .savedVideoPackageEntryName)
        try c.encodeIfPresent(savedHTMLSource, forKey: .savedHTMLSource)
        try c.encodeIfPresent(savedHTMLConfig, forKey: .savedHTMLConfig)
        try c.encodeIfPresent(savedSceneDescriptor, forKey: .savedSceneDescriptor)
        try c.encode(playbackSpeed, forKey: .playbackSpeed)
        try c.encode(fitMode, forKey: .fitMode)
        try c.encode(videoDisplayMode, forKey: .videoDisplayMode)
        try c.encode(frameRateLimit, forKey: .frameRateLimit)
        try c.encode(particleEffect, forKey: .particleEffect)
        try c.encode(effectConfig, forKey: .effectConfig)
        try c.encodeIfPresent(scheduleSlots, forKey: .scheduleSlots)
        try c.encodeIfPresent(playlistBookmarks, forKey: .playlistBookmarks)
        try c.encode(shufflePlaylist, forKey: .shufflePlaylist)
        try c.encodeIfPresent(playlistRotationMinutes, forKey: .playlistRotationMinutes)
        try c.encodeIfPresent(playlistCursorIndex, forKey: .playlistCursorIndex)
        try c.encodeIfPresent(playlistPrimaryIndex, forKey: .playlistPrimaryIndex)
        try c.encode(setAsLockScreen, forKey: .setAsLockScreen)
        try c.encode(wallpaperMode, forKey: .wallpaperMode)
        try c.encode(muted, forKey: .muted)
        try c.encode(videoVolume, forKey: .videoVolume)
        try c.encode(videoColorSpace, forKey: .videoColorSpace)
        try c.encode(sceneMouseInteractionEnabled, forKey: .sceneMouseInteractionEnabled)
        try c.encode(sceneClickCaptureEnabled, forKey: .sceneClickCaptureEnabled)
        try c.encodeIfPresent(wpeOrigin, forKey: .wpeOrigin)
        try c.encodeIfPresent(displayFingerprint, forKey: .displayFingerprint)
    }

    private static func clampedVideoVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }

    public mutating func setHTMLWallpaper(source: HTMLSource, config: HTMLConfig = .default) {
        preserveCurrentVideoBookmarkIfNeeded()
        savedHTMLSource = source
        savedHTMLConfig = config
        activeWallpaper = .html(source: source, config: config)
    }

    /// Re-syncs any carried preset values against the library, and drops the
    /// layer when the preset is gone.
    ///
    /// `presetSnapshot` is a cache that rides along with the descriptor because
    /// the renderer never sees `GlobalSettings`. Without a call to this on the
    /// load path, editing or deleting a preset would leave every screen still
    /// rendering the values it captured.
    public func refreshingScenePresets(in library: [String: ScenePreset]) -> ScreenConfiguration {
        var refreshed = self
        if case .scene(let descriptor) = activeWallpaper {
            refreshed.activeWallpaper = .scene(descriptor.refreshingPresetSnapshot(in: library))
        }
        if let saved = savedSceneDescriptor {
            refreshed.savedSceneDescriptor = saved.refreshingPresetSnapshot(in: library)
        }
        return refreshed
    }

    public mutating func setSceneWallpaper(_ descriptor: SceneDescriptor, origin: WPEOrigin?) {
        preserveCurrentVideoBookmarkIfNeeded()
        preserveCurrentHTMLIfNeeded()
        // Same-scene re-pick after type switch restores the last look. Both
        // layers travel together — restoring the increment without the preset
        // it was authored against would apply the edits to bare scene defaults.
        var resolved = descriptor
        if descriptor.propertyOverrides.isEmpty,
           descriptor.presetID == nil,
           let saved = savedSceneDescriptor,
           saved.isSameScene(as: descriptor),
           !saved.propertyOverrides.isEmpty || saved.presetID != nil {
            resolved = descriptor
                .withPresetLayer(id: saved.presetID, snapshot: saved.presetSnapshot)
                .withPropertyOverrides(saved.propertyOverrides)
        }
        activeWallpaper = .scene(resolved)
        wpeOrigin = origin
        savedSceneDescriptor = resolved
    }

    @discardableResult
    public mutating func activateSavedVideoWallpaper() -> Bool {
        // Keep package entry with bookmark so restore stays windowed, not raw pkg.
        let bookmarkData: Data
        let packageEntryName: String?
        if let saved = savedVideoBookmarkData {
            bookmarkData = saved
            packageEntryName = savedVideoPackageEntryName
        } else if let active = activeWallpaper.activeVideoBookmarkData {
            bookmarkData = active
            packageEntryName = activeWallpaper.packageVideoEntryName
        } else {
            return false
        }
        preserveCurrentHTMLIfNeeded()
        activeWallpaper = .video(bookmarkData: bookmarkData, packageEntryName: packageEntryName)
        savedVideoBookmarkData = bookmarkData
        savedVideoPackageEntryName = packageEntryName
        playlistCursorIndex = 0
        return true
    }

    @discardableResult
    public mutating func activateSavedHTMLWallpaper() -> Bool {
        guard let source = savedHTMLSource else { return false }
        let config = savedHTMLConfig ?? .default
        preserveCurrentVideoBookmarkIfNeeded()
        activeWallpaper = .html(source: source, config: config)
        return true
    }

    /// Packaged entry name when bookmark → `scene.pkg`; nil for a loose file.
    public mutating func replacePrimaryVideo(bookmarkData: Data, packageEntryName: String? = nil) {
        preserveCurrentHTMLIfNeeded()
        savedVideoBookmarkData = bookmarkData
        savedVideoPackageEntryName = packageEntryName
        activeWallpaper = .video(bookmarkData: bookmarkData, packageEntryName: packageEntryName)
        playlistCursorIndex = 0
        playlistPrimaryIndex = nil
    }

    /// Apply a schedule slot without replacing the saved primary.
    /// Slots are bare bookmarks (loose video only; packaged cannot round-trip).
    public mutating func applyScheduledBookmark(_ bookmarkData: Data) {
        activeWallpaper = .video(bookmarkData: bookmarkData)
    }

    private mutating func preserveCurrentVideoBookmarkIfNeeded() {
        if savedVideoBookmarkData == nil {
            savedVideoBookmarkData = activeWallpaper.activeVideoBookmarkData
            savedVideoPackageEntryName = activeWallpaper.packageVideoEntryName
        }
    }

    private mutating func preserveCurrentHTMLIfNeeded() {
        if case .html(let source, let config) = activeWallpaper {
            savedHTMLSource = source
            savedHTMLConfig = config
        }
    }

    public func withUpdatedActiveBookmark(_ bookmarkData: Data) -> ScreenConfiguration {
        var copy = self
        let oldActive = copy.activeWallpaper.activeVideoBookmarkData

        if case .video(_, let packageEntryName) = copy.activeWallpaper {
            // Same logical video: keep package entry (avoid raw-pkg downgrade).
            copy.activeWallpaper = .video(bookmarkData: bookmarkData, packageEntryName: packageEntryName)
        }

        guard let oldActive else { return copy }

        if oldActive == copy.savedVideoBookmarkData {
            copy.savedVideoBookmarkData = bookmarkData
            return copy
        }

        if var additional = copy.playlistBookmarks,
           let index = additional.firstIndex(of: oldActive) {
            additional[index] = bookmarkData
            copy.playlistBookmarks = additional
            return copy
        }

        if var slots = copy.scheduleSlots {
            for index in slots.indices where slots[index].videoBookmarkData == oldActive {
                slots[index].videoBookmarkData = bookmarkData
                copy.scheduleSlots = slots
                return copy
            }
        }

        return copy
    }

    /// CAS local-HTML grant on active + saved sources. `nil` if user re-granted
    /// after resolve started — callers must not overwrite that newer choice.
    public func replacingHTMLBookmark(
        matching original: Data,
        with refreshed: Data
    ) -> ScreenConfiguration? {
        var copy = self
        var didReplace = false

        if let savedHTMLSource = copy.savedHTMLSource,
           let updated = savedHTMLSource.replacingLocalBookmark(
            matching: original,
            with: refreshed
           ) {
            copy.savedHTMLSource = updated
            didReplace = true
        }
        if case .html(let source, let config) = copy.activeWallpaper,
           let updated = source.replacingLocalBookmark(
            matching: original,
            with: refreshed
           ) {
            copy.activeWallpaper = .html(source: updated, config: config)
            didReplace = true
        }

        return didReplace ? copy : nil
    }

    /// CAS WPE source-folder grant; advances matching HTML copies in the same mutation.
    public func replacingWPEOriginBookmark(
        workshopID: String,
        matching original: Data,
        with refreshed: Data
    ) -> ScreenConfiguration? {
        guard let origin = wpeOrigin,
              origin.workshopID == workshopID,
              let updatedOrigin = origin.replacingSourceFolderBookmark(
                matching: original,
                with: refreshed
              ) else { return nil }

        var copy = self
        copy.wpeOrigin = updatedOrigin
        if let updatedHTML = copy.replacingHTMLBookmark(
            matching: original,
            with: refreshed
        ) {
            copy = updatedHTML
        }
        return copy
    }
}
