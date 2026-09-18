#if !LITE_BUILD
import AppKit
@testable import LiveWallpaper
import LiveWallpaperCore
import SwiftUI
import Testing

/// Scratch renderer: writes PNGs of each popup template so they can be reviewed
/// without launching the app. Not an assertion suite.
@Suite("Popup template renders", .serialized)
@MainActor
struct PopupTemplateRenderTests {
    private func render(_ name: String, width: CGFloat, height: CGFloat, @ViewBuilder _ view: () -> some View) throws {
        let root = view()
        for (label, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let host = NSHostingView(rootView: AppLanguageScope(defaults: .appScoped()) {
                root.frame(width: width, height: height)
            })
            host.appearance = NSAppearance(named: appearance)
            host.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("popup-\(name)-\(label).png")
            try png.write(to: out)
            print("POPUP-RENDER \(out.path)")
        }
    }

    private var snapshot: WallpaperFailureSnapshot {
        WallpaperFailureSnapshot(
            id: UUID(),
            title: "Painting the Sharks 4K",
            workshopID: "2468489223",
            displayName: "MPG321CX OLED",
            stage: "loading",
            cause: WallpaperFailureCause(
                code: "scene.metal_unsupported",
                reason: "this wallpaper uses the legacy MDLV0013 puppet format, which this renderer cannot assemble correctly",
                canRetry: false
            ),
            previousWallpaper: nil,
            timestamp: Date(),
            diagnostics: "Failed wallpaper: Painting the Sharks 4K\nWorkshop ID: 2468489223\nStage: loading\nCode: scene.metal_unsupported",
            wallpaperType: .scene
        )
    }

    /// Template 1 — read-only detail in the InfoOverlay container, over a stand-in page.
    @Test("1 info overlay")
    func infoOverlayTemplate() throws {
        let snap = snapshot
        try render("1-info-overlay", width: 900, height: 640) {
            Color.gray.opacity(0.25)
                .infoOverlay(item: .constant(snap)) { failure, dismiss in
                    VStack(spacing: 0) {
                        WallpaperFailureView(failure: failure, isCurrentAttempt: false)
                        SheetFooterBar(primaryTitle: "Done", primaryAction: dismiss)
                    }
                    .frame(width: 600, height: 400)
                }
        }
    }

    /// Template 2 — the shared sheet skeleton: SteamSheetHeader + body + SheetFooterBar.
    @Test("2 standard sheet skeleton")
    func standardSheetTemplate() throws {
        try render("2-standard-sheet", width: SteamSheetWidth.form, height: 320) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    SteamSheetHeader(
                        icon: "tray.and.arrow.down.fill",
                        title: "Add from Steam Workshop",
                        iconTint: .accentColor,
                        subtitle: "Paste one or more Workshop links."
                    )
                    Text(verbatim: "steamcommunity.com/sharedfiles/filedetails/?id=2468489223")
                        .font(DesignTokens.Typography.code)
                        .padding(DesignTokens.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignTokens.Colors.surfaceRaised)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
                .padding(.top, DesignTokens.Settings.formVerticalMargin)
                .padding(.bottom, DesignTokens.Spacing.md)
                SheetFooterBar(
                    primaryTitle: "Done",
                    primaryAction: {},
                    cancelTitle: "Cancel",
                    cancelAction: {}
                )
            }
            .background(DesignTokens.Colors.pageBackground)
        }
    }

    /// Template 3 — the failure-details panel, the second popup in the report.
    @Test("3 failure details")
    func failureDetailsTemplate() throws {
        let snap = snapshot
        try render("3-failure-details", width: 900, height: 640) {
            Color.gray.opacity(0.25)
                .infoOverlay(item: .constant(snap)) { failure, dismiss in
                    WallpaperFailureDetails(failure: failure, onDismiss: dismiss)
                }
        }
    }

    /// Template 4 — the whole-page form of the same view, for contrast with template 1.
    @Test("4 failure page")
    func failurePageTemplate() throws {
        let snap = snapshot
        try render("4-failure-page", width: 700, height: 520) {
            WallpaperFailureView(failure: snap, onRetry: {}, onViewDesktop: {}, onShowDetails: {})
        }
    }

    /// Template 5 — popover chrome.
    @Test("5 popover chrome")
    func popoverTemplate() throws {
        try render("5-popover", width: 300, height: 160) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Frame rate").font(DesignTokens.Typography.captionEmphasized)
                Text(verbatim: "30 fps").font(DesignTokens.Typography.body)
                Slider(value: .constant(0.5))
            }
            .settingsPopoverChrome(width: 260)
            .background(DesignTokens.Colors.pageBackground)
        }
    }
}
#endif
