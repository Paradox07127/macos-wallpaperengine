import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import Testing

@MainActor
@Suite("Scheme detail modal — sections and rows")
struct SchemeDetailRowsTests {
    private typealias Rows = SchemeDetailRows

    private static let locale = Locale(identifier: "en_US")
    private static let saved = Date(timeIntervalSince1970: 1_700_000_000)

    private static func scheme(
        _ configuration: ScreenConfiguration, overlay: MonitorOverlayConfiguration = .default, updated: Date? = nil
    ) -> ScreenScheme {
        ScreenScheme(
            name: "Evening", configuration: configuration, overlay: overlay,
            createdAt: saved, updatedAt: updated ?? saved, sourceDisplayName: "Studio Display"
        )
    }

    private static func keys(_ sections: [Rows.Section], _ kind: Rows.Section.Kind) -> [Rows.Row.Key]? {
        sections.first { $0.kind == kind }?.rows.map(\.key)
    }

    private static func value(_ sections: [Rows.Section], _ key: Rows.Row.Key) -> String? {
        sections.flatMap(\.rows).first { $0.key == key }?.value
    }

    @Test("A video scheme names its file and lists fit, speed, volume and colour space")
    func videoScheme() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Evening Loop.mp4")
        try Data([0]).write(to: file)
        var configuration = try ScreenConfiguration(screenID: 1, videoBookmarkData: file.bookmarkData(), playbackSpeed: 1.5, fitMode: .aspectFit)
        configuration.muted = false
        configuration.videoVolume = 0.8
        configuration.videoColorSpace = .displayP3

        let sections = Rows.make(for: Self.scheme(configuration), locale: Self.locale)
        #expect(Self.keys(sections, .wallpaper) == [.name, .type])
        #expect(Self.value(sections, .name) == "Evening Loop.mp4")
        #expect(Self.keys(sections, .playback) == [.scaling, .playbackSpeed, .volume, .colorSpace])
        #expect(Self.value(sections, .playbackSpeed) == "1.5×")
        #expect(Self.value(sections, .volume) == "80%")
        #expect(Self.keys(sections, .automation) == [.mode], "a single wallpaper has nothing automated to list")
    }

    @Test("A muted video says so instead of its level")
    func mutedVideo() {
        let configuration = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]))
        let sections = Rows.make(for: Self.scheme(configuration), locale: Self.locale)
        #expect(Self.value(sections, .volume) == String(localized: "Muted", bundle: .appLanguage))
    }

    @Test("A scene scheme lists fit, frame rate, its customised properties and mouse interaction")
    func sceneScheme() {
        let descriptor = SceneDescriptor(
            workshopID: "123", cacheRelativePath: "123", entryFile: "scene.json", capabilityTier: .imageOnly,
            propertyOverrides: ["speed": .number(2), "tint": .string("1 0 0")]
        )
        var configuration = ScreenConfiguration(screenID: 1, wallpaper: .scene(descriptor))
        configuration.sceneMouseInteractionEnabled = false
        configuration.sceneClickCaptureEnabled = true

        let sections = Rows.make(for: Self.scheme(configuration), locale: Self.locale)
        #expect(Self.keys(sections, .wallpaper) == [.type])
        #expect(Self.keys(sections, .playback) == [.scaling, .frameRate, .sceneSettings, .mouseInteraction])
        #expect(Self.value(sections, .frameRate) == FrameRateLimit.fps30.title)
        #expect(Self.value(sections, .sceneSettings)?.contains("2") == true)
        #expect(Self.value(sections, .mouseInteraction) == String(localized: "Off", bundle: .appLanguage))
        #expect(Self.keys(sections, .other) == [.clickCapture])
    }

    @Test("A scheduled scheme with widgets lists its slots, fallback, layers and lock-screen capture")
    func scheduleAndWidgets() {
        var configuration = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]))
        configuration.wallpaperMode = .schedule
        configuration.scheduleSlots = [
            ScheduleSlot(startHour: 6, endHour: 18, label: "Morning"),
            ScheduleSlot(startHour: 18, endHour: 6, label: "Night"),
        ]
        configuration.scheduleFallback = WallpaperQueueEntry(title: "Night Sky", content: .video(bookmarkData: Data([2])))
        configuration.setAsLockScreen = true
        let overlay = MonitorOverlayConfiguration(
            enabled: true, level: .front, clock: ClockOverlayConfiguration(enabled: true, level: .desktop)
        )

        let sections = Rows.make(for: Self.scheme(configuration, overlay: overlay), locale: Self.locale)
        #expect(Self.keys(sections, .automation) == [.mode, .timeSlots, .fallback])
        #expect(Self.value(sections, .timeSlots) == "2")
        #expect(Self.value(sections, .fallback) == "Night Sky")
        #expect(Self.keys(sections, .widgets) == [.clock, .board])
        #expect(Self.value(sections, .board) == String(localized: "On Top", bundle: .appLanguage))
        #expect(Self.keys(sections, .other) == [.lockScreen])
    }

    @Test("A playlist lists its length, shuffle and rotation")
    func playlist() {
        var configuration = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]))
        configuration.wallpaperQueue = (1 ... 3).map { WallpaperQueueEntry(title: "Clip \($0)", content: .video(bookmarkData: Data([UInt8($0)]))) }
        configuration.shufflePlaylist = true
        configuration.playlistRotationMinutes = 15

        let sections = Rows.make(for: Self.scheme(configuration), locale: Self.locale)
        #expect(Self.keys(sections, .automation) == [.mode, .playlist, .shuffle, .rotation])
    }

    @Test("Sections with nothing to say are left out")
    func emptySectionsAreLeftOut() {
        let configuration = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]))
        let sections = Rows.make(for: Self.scheme(configuration), locale: Self.locale)
        #expect(sections.map(\.kind) == [.wallpaper, .playback, .automation])
        #expect(sections.allSatisfy { !$0.rows.isEmpty })
    }

    @Test("The facts name the source display and the save date, and the update only on another day")
    func facts() {
        let configuration = ScreenConfiguration(screenID: 1, videoBookmarkData: Data([1]))
        let sameDay = Rows.facts(for: Self.scheme(configuration, updated: Self.saved.addingTimeInterval(5)), now: Self.saved, locale: Self.locale)
        #expect(sameDay.map(\.kind) == [.type, .capturedFrom, .saved])
        #expect(sameDay.first { $0.kind == .capturedFrom }?.value == "Studio Display")
        let later = Rows.facts(for: Self.scheme(configuration, updated: Self.saved.addingTimeInterval(86400 * 3)), now: Self.saved, locale: Self.locale)
        #expect(later.map(\.kind) == [.type, .capturedFrom, .saved, .updated])
    }
}
