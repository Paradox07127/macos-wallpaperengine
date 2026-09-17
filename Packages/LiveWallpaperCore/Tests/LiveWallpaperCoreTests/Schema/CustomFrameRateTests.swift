import Foundation
@testable import LiveWallpaperCore
import Testing

@Suite("Custom content frame rates")
struct CustomFrameRateTests {
    @Test("Fractional cadences keep their rate across displays",
          arguments: [60, 75, 120, 144, 240], [1, 15, 24, 30, 37, 45, 60, 120])
    func cadence(refresh: Int, target: Int) {
        var cadence = FrameRateCadence()
        let driver = FrameRateCadence.driverFramesPerSecond(target: target, display: refresh)
        let seconds = 30
        let rendered = (0 ..< driver * seconds).filter {
            cadence.shouldRender(at: 100 + Double($0) / Double(driver), framesPerSecond: target)
        }
        #expect(rendered.count == min(refresh, target) * seconds)
    }

    @Test("24 and 45 on 60 Hz distribute frames instead of collapsing to a divisor")
    func fractionalIntervals() {
        for (fps, expected) in [(24, Set([2, 3])), (45, Set([1, 2]))] {
            var cadence = FrameRateCadence()
            let ticks = (0 ..< 600).filter {
                cadence.shouldRender(at: Double($0) / 60, framesPerSecond: fps)
            }
            #expect(Set(zip(ticks.dropFirst(), ticks).map(-)) == expected)
        }
    }

    @Test("Stalls do not queue catch-up frames; rate changes and resets draw immediately")
    func transitions() {
        var cadence = FrameRateCadence()
        let first = cadence.shouldRender(at: 10, framesPerSecond: 24)
        let duplicate = cadence.shouldRender(at: 10, framesPerSecond: 24)
        let afterStall = cadence.shouldRender(at: 100, framesPerSecond: 24)
        let catchUp = cadence.shouldRender(at: 100.001, framesPerSecond: 24)
        let changed = cadence.shouldRender(at: 100.002, framesPerSecond: 45)
        cadence.reset()
        let resumed = cadence.shouldRender(at: 100.003, framesPerSecond: 45)
        let invalid = cadence.shouldRender(at: .nan, framesPerSecond: 45)
        let reversed = cadence.shouldRender(at: 0, framesPerSecond: 45)
        #expect(first && afterStall && changed && resumed && reversed)
        #expect(!duplicate && !catchUp && !invalid)
    }

    @Test("Preset divisors avoid unnecessary high-frequency callbacks")
    func driverRate() {
        #expect(FrameRateCadence.driverFramesPerSecond(target: 30, display: 60) == 30)
        #expect(FrameRateCadence.driverFramesPerSecond(target: 24, display: 240) == 24)
        #expect(FrameRateCadence.driverFramesPerSecond(target: 45, display: 60) == 60)
        #expect(FrameRateCadence.driverFramesPerSecond(target: 60, display: 144) == 144)
    }

    @Test("Every allowed integer survives slider mapping; other targets fit the display", arguments: [1, 24, 60, 144, 240])
    func sliderMapping(display: Int) throws {
        let scale = FrameRateSliderScale(displayFramesPerSecond: display)
        for fps in 1 ... display {
            let value = try #require(FrameRateLimit(rawValue: fps))
            #expect(scale.value(at: scale.position(for: value), snapping: false) == value)
        }
        #expect(scale.value(at: scale.maximumPosition) == .matchDisplay)
        let higher = try #require(FrameRateLimit(rawValue: display + 1))
        #expect(scale.value(at: scale.position(for: higher), snapping: false).rawValue == display)
        #expect(scale.presets.allSatisfy { $0 == .matchDisplay || $0.rawValue <= display })
        if display >= 24 {
            #expect(scale.value(at: scale.position(for: .fps24) + 0.05) == .fps24)
        }
        let top = try #require(FrameRateLimit(rawValue: display))
        #expect(scale.position(for: top) != scale.position(for: .matchDisplay))
    }

    /// A saved 120 on a 60 Hz display reads "60"; committing that text on blur would clamp the
    /// saved target for every display the user never touched this control on.
    @Test("Enter or losing focus without editing never writes the display-clamped value back")
    func blurKeepsUnclampedSavedRate() throws {
        let shown = FrameRateTextEntry.text(for: .fps120, upperBound: 60)
        #expect(shown == "60")
        #expect(FrameRateTextEntry.commitDecision(text: shown, value: .fps120, upperBound: 60) == .unchanged)
        #expect(FrameRateTextEntry.commitDecision(text: " 60 ", value: .fps120, upperBound: 60) == .unchanged)
        #expect(FrameRateTextEntry.commitDecision(text: "Max", value: .matchDisplay, upperBound: 60) == .unchanged)
        let custom = try #require(FrameRateLimit(rawValue: 48))
        #expect(FrameRateTextEntry.commitDecision(text: "48", value: .fps120, upperBound: 60) == .commit(custom))
        #expect(FrameRateTextEntry.commitDecision(text: " max ", value: .fps30, upperBound: 60) == .commit(.matchDisplay))
        #expect(FrameRateTextEntry.commitDecision(text: "600", value: .fps120, upperBound: 60) == .invalid)
        #expect(FrameRateTextEntry.commitDecision(text: "0", value: .fps30, upperBound: 60) == .invalid)
        #expect(FrameRateTextEntry.commitDecision(text: "", value: .fps30, upperBound: 60) == .invalid)
    }

    @Test("Custom rates retain their meaning in defaults and bookmarks")
    func settingsRoundTrip() throws {
        for fps in [1, 4, 24, 37, 45, 120, 1000] {
            let rate = try #require(FrameRateLimit(rawValue: fps))
            let defaults = DisplayPlaybackDefaults(frameRateLimit: rate)
            let restored = try JSONDecoder().decode(DisplayPlaybackDefaults.self, from: JSONEncoder().encode(defaults))
            #expect(restored.frameRateLimit == rate)
            let bookmark = BookmarkPlaybackSettings(frameRateLimit: rate)
            let restoredBookmark = try JSONDecoder().decode(BookmarkPlaybackSettings.self, from: JSONEncoder().encode(bookmark))
            #expect(restoredBookmark.frameRateLimit == rate)
        }
        #expect(FrameRateLimit(rawValue: -1) == nil)
        #expect(FrameRateLimit(rawValue: Int(Int32.max) + 1) == nil)
    }
}
