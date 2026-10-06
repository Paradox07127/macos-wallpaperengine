import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

@Suite("Settings segmented picker width")
struct SettingsSegmentedPickerWidthTests {
    private static let sharedWidth = "DesignTokens.Settings.segmentedPickerWidth)"

    /// Segment titles of every settings picker that takes the shared width, keyed by the file that draws it.
    private static let pickers: [(file: String, keys: [String])] = [
        ("LiveWallpaper/Views/Settings/AppearanceSettingsView.swift", ["System", "Light", "Dark"]),
        ("Packages/LiveWallpaperCore/Sources/LiveWallpaperCore/UI/Components/LibraryTileSize.swift", ["Small", "Medium", "Large"]),
        ("LiveWallpaper/Views/Settings/ShelfSettingsRows.swift", ["Solid", "Frosted"]),
        ("LiveWallpaper/Views/Settings/SystemWallpaperSettingsView.swift", ["Always", "Lock screen only"]),
        ("LiveWallpaper/Views/Settings/WeatherSection.swift", ["Off", "System", "Manual"]),
        ("LiveWallpaper/Views/Settings/OverlaysSettingsView.swift", ["°C", "°F"]),
    ]

    @Test("Every settings segmented picker but the shelf style takes the shared width token")
    func everyPickerUsesTheSharedWidth() throws {
        var widths: [String] = []
        for file in RepositoryRoot.swiftFiles(under: "LiveWallpaper/Views/Settings") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            for chunk in source.components(separatedBy: "GlassSegmentedPicker(").dropFirst() {
                guard let frame = chunk.range(of: ".frame(width: ") else {
                    widths.append("\(name): no width")
                    continue
                }
                let width = chunk[frame.upperBound...].prefix { $0 != "\n" }
                widths.append("\(name): \(width)")
            }
        }
        #expect(widths.count == 7, "the scan found \(widths.count) settings segmented pickers: \(widths)")
        let offenders = widths.filter {
            !$0.hasSuffix(Self.sharedWidth) && $0 != "ShelfSettingsRows.swift: Self.shelfStylePickerWidth)"
        }
        #expect(offenders.isEmpty, "settings pickers sized apart from the shared token: \(offenders)")
    }

    /// The `.flat` shell is 2pt of padding round equal segments with no gap, so a picker fits when
    /// each segment holds its widest title in the selected (semibold) weight.
    @MainActor
    @Test("The shared width fits every title of every picker in all five languages")
    func sharedWidthFitsEveryTitle() throws {
        var needed: (width: CGFloat, title: String) = (0, "")
        for picker in Self.pickers {
            let source = try RepositoryRoot.source(picker.file)
            for key in picker.keys {
                #expect(source.contains("\"\(key)\""), "\(picker.file) no longer titles a segment \(key)")
            }
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
