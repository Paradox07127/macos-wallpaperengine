import AppKit
@testable import LiveWallpaper
import Testing

@MainActor
@Suite("Switched-off display placeholder")
struct SwitchedOffDisplayPlaceholderTests {
    private static func online(_ id: CGDirectDisplayID, _ frame: CGRect) -> StageDisplay {
        StageDisplay(
            id: id, fingerprint: "online-\(id)", frame: frame, isBuiltin: false, name: "Online \(id)",
            badgeText: "", statusText: "", cover: nil, state: .ok
        )
    }

    #if !MAS_BUILD
    private static func record(_ id: CGDirectDisplayID, _ frame: CGRect) -> DisabledDisplay {
        DisabledDisplay(fingerprint: "off-\(id)", lastDisplayID: id, name: "Off \(id)", frame: frame, isBuiltin: false)
    }

    @Test("One placeholder sits right of the online union with its recorded size, bottoms aligned")
    func singlePlaceholder() {
        let displays = [
            Self.online(1, CGRect(x: 0, y: 0, width: 1512, height: 982)),
            Self.online(2, CGRect(x: 1512, y: 200, width: 2560, height: 1440)),
        ]
        // Recorded where display 2 now sits, as after the system rearranged the rest.
        let placeholders = HomePage.switchedOffPlaceholders(
            for: [Self.record(9, CGRect(x: 1512, y: 200, width: 1920, height: 1080))], besides: displays
        )
        #expect(placeholders.map(\.frame) == [CGRect(x: 4072, y: 0, width: 1920, height: 1080)])
        #expect(placeholders.map(\.id) == [9])
        #expect(placeholders.map(\.fingerprint) == ["off-9"])
        #expect(placeholders.map(\.name) == ["Off 9"])
        #expect(placeholders.allSatisfy { $0.state == .switchedOff })
    }

    @Test("Several placeholders line up one after another, in record order")
    func severalPlaceholders() {
        let placeholders = HomePage.switchedOffPlaceholders(
            for: [
                Self.record(8, CGRect(x: -900, y: 50, width: 1920, height: 1080)),
                Self.record(9, CGRect(x: 3000, y: 0, width: 1280, height: 1024)),
            ],
            besides: [Self.online(1, CGRect(x: 0, y: 0, width: 1512, height: 982))]
        )
        #expect(placeholders.map(\.frame) == [
            CGRect(x: 1512, y: 0, width: 1920, height: 1080),
            CGRect(x: 3432, y: 0, width: 1280, height: 1024),
        ])
    }

    @Test("Online displays left of and below the origin set the union the placeholders follow")
    func negativeOnlineCoordinates() {
        let displays = [
            Self.online(1, CGRect(x: 0, y: 0, width: 1512, height: 982)),
            Self.online(2, CGRect(x: -2560, y: -1440, width: 2560, height: 1440)),
        ]
        let placeholders = HomePage.switchedOffPlaceholders(
            for: [Self.record(9, CGRect(x: 0, y: 0, width: 1920, height: 1080))], besides: displays
        )
        #expect(placeholders.map(\.frame) == [CGRect(x: 1512, y: -1440, width: 1920, height: 1080)])
    }

    @Test("A record whose display ID an online display now uses gets no placeholder, and takes no room")
    func reusedIDIsSkipped() {
        let placeholders = HomePage.switchedOffPlaceholders(
            for: [
                Self.record(1, CGRect(x: 0, y: 0, width: 1920, height: 1080)),
                Self.record(9, CGRect(x: 0, y: 0, width: 1280, height: 1024)),
            ],
            besides: [Self.online(1, CGRect(x: 0, y: 0, width: 1512, height: 982))]
        )
        #expect(placeholders.map(\.id) == [9])
        #expect(placeholders.map(\.frame) == [CGRect(x: 1512, y: 0, width: 1280, height: 1024)])
    }
    #endif

    @Test("The placeholder's symbol exists on this system")
    func symbolExists() {
        #expect(NSImage(systemSymbolName: StageDisplay.switchedOffSymbol, accessibilityDescription: nil) != nil)
    }

    @Test("VoiceOver reads the placeholder as switched off, without a wallpaper name")
    func accessibilityValue() {
        var display = Self.online(9, CGRect(x: 0, y: 0, width: 1920, height: 1080))
        display.state = .switchedOff
        display.wallpaperTitle = "Leftover"
        #expect(display.accessibilityValue == StageDisplay.switchedOffText)
        #expect(!display.accessibilityValue.isEmpty)
    }
}
