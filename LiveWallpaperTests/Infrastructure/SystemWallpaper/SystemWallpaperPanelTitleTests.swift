import Foundation
@testable import LiveWallpaper
import Testing

@Suite("System wallpaper panel group title")
struct SystemWallpaperPanelTitleTests {
    private let title = "Loomscreen Pro Video Wallpapers"

    @Test("The current, declared copy shows the plain title")
    func currentCopyKeepsTitle() {
        for language in ["en-US", "zh-Hans-CN", "zh-Hant-TW", "ja-JP", "es-ES"] {
            #expect(
                SystemWallpaperProviderStaleness.panelGroupTitle(title, verdict: .current, preferredLanguage: language)
                    == title,
                "\(language) decorated the title of a current copy"
            )
        }
    }

    @Test("Every stale verdict marks the title, including a copy the app does not declare")
    func staleCopiesAreMarked() {
        let stale: [SystemWallpaperProviderStaleness.Verdict] = [
            .bundleGone,
            .buildChanged(loaded: "9", onDisk: "10"),
            .supersededByDeclared(declaredPath: "/Applications/Loomscreen.app/Contents/Extensions/P.appex"),
        ]
        for verdict in stale {
            #expect(
                SystemWallpaperProviderStaleness.panelGroupTitle(title, verdict: verdict, preferredLanguage: "en-US")
                    == "\(title) (outdated copy)",
                "\(verdict) left the title unmarked"
            )
        }
    }

    @Test("The marker follows the preferred language, English otherwise")
    func markerIsLocalized() {
        let expected = [
            "zh-Hans-CN": "\(title)（旧版本）",
            "zh-Hant-TW": "\(title)（舊版本）",
            "ja-JP": "\(title)（旧バージョン）",
            "es-ES": "\(title) (copia obsoleta)",
            "fr-FR": "\(title) (outdated copy)",
        ]
        for (language, marked) in expected {
            #expect(
                SystemWallpaperProviderStaleness.panelGroupTitle(title, verdict: .bundleGone, preferredLanguage: language)
                    == marked
            )
        }
    }
}
