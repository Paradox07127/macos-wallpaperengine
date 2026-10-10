import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Settings segmented picker width")
struct SettingsSegmentedPickerWidthTests {
    /// Segment titles of every settings picker that takes the shared width, keyed by the file that draws it.
    private static let pickers: [(file: String, keys: [String])] = [
        ("LiveWallpaper/Views/Settings/AppearanceSettingsView.swift", ["System", "Light", "Dark"]),
        ("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/LibraryTileSize.swift", ["Small", "Medium", "Large"]),
        ("LiveWallpaper/Views/Settings/ShelfSettingsRows.swift", ["Solid", "Frosted"]),
        ("LiveWallpaper/Views/Settings/SystemWallpaperSettingsView.swift", ["Always", "Lock screen only"]),
        ("LiveWallpaper/Views/Settings/WeatherSection.swift", ["Off", "System", "Manual"]),
        ("LiveWallpaper/Views/Settings/OverlaysSettingsView.swift", ["°C", "°F"]),
    ]

    /// The `.flat` shell is 2pt of padding round equal segments with no gap, so a picker fits when
    /// each segment holds its widest title in the selected (semibold) weight.
    @MainActor
    @Test("The shared width fits every title of every picker in all five languages")
    func sharedWidthFitsEveryTitle() throws {
        var needed: (width: CGFloat, title: String) = (0, "")
        for picker in Self.pickers {
            for language in ["en", "zh-Hans", "zh-Hant", "ja", "es"] {
                let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
                let bundle = try #require(Bundle(path: path))
                for key in picker.keys {
                    let title = NSLocalizedString(key, bundle: bundle, comment: "")
                    let text = Text(verbatim: title).font(DesignTokens.Typography.bodyEmphasized).fixedSize()
                    let width = NSHostingView(rootView: text).fittingSize.width
                    let pickerWidth = CGFloat(picker.keys.count) * width + 4
                    if pickerWidth > needed.width {
                        needed = (pickerWidth, "\(language) “\(title)”")
                    }
                }
            }
        }
        #expect(
            needed.width <= DesignTokens.Settings.segmentedPickerWidth,
            Comment(rawValue: "\(needed.title) needs a \(needed.width)pt picker")
        )
    }
}
