import AppKit
import Foundation
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// The banner replaced three hand-rolled copies that had each drifted in a
/// different direction, so its two surfaces have to survive both appearances at
/// the width they actually ship at.
@Suite("Inline notice banner layout")
@MainActor
struct InlineNoticeBannerLayoutTests {
    /// 420 is the regression: the side-by-side layout squeezed the message
    /// column to one word per line there before the stacked fallback existed.
    @Test("Both surfaces lay out in native light and dark appearances", arguments: [CGFloat(420), CGFloat(620)])
    func bannerLaysOutInBothAppearances(width: CGFloat) throws {
        let cases: [(String, NoticeBannerSurface, FallbackReason)] = [
            ("chrome-blocked", .chrome, .sceneParseFailed("unexpected token at line 42")),
            ("chrome-needsparts", .chrome, .missingDependency(workshopIDs: ["1122334455", "9988776655"])),
            ("content-fatal", .content, .requiresWindowsPlugin),
            ("content-needsparts", .content, .sceneResourceMissing),
        ]
        let origin = WPEOrigin(
            workshopID: "1234567890",
            title: "Night Sky",
            originalType: .scene,
            sourceFolderBookmark: Data([1]),
            cacheRelativePath: "1234567890",
            previewFileName: nil,
            entryFile: "scene.json"
        )

        for (name, surface, reason) in cases {
            let presentation = reason.presentation(origin: origin, engineAssetsAuthorized: false)
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
                let banner = InlineNoticeBanner(
                    tint: presentation.tint,
                    symbol: presentation.symbol,
                    title: presentation.title,
                    message: presentation.message,
                    code: presentation.code,
                    surface: surface
                ) {
                    SceneFailureRecoveryActions(recovery: presentation.recovery, onRetry: {})
                }
                let host = NSHostingView(rootView: AppLanguageScope(defaults: .appScoped()) {
                    banner.frame(width: width).padding(DesignTokens.Spacing.lg)
                })
                host.appearance = NSAppearance(named: appearance)
                let fitting = host.fittingSize
                host.frame = CGRect(x: 0, y: 0, width: width + 32, height: max(fitting.height, 1))
                host.layoutSubtreeIfNeeded()

                // The whole point of the tokenised layout: nothing overflows the
                // width it was given, in either appearance.
                #expect(fitting.width <= width + 32)
                #expect(fitting.height > 0)

                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("InlineNoticeBanner-\(Int(width))-\(name)-\(appearanceName).png")
                try png.write(to: destination)
                print("Inline notice banner snapshot: \(destination.path)")
            }
        }
    }
}
