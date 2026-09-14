#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

struct EngineAssetsBanner: View {
    @Environment(\.featureCatalog) private var featureCatalog
    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared

    static func shouldShow(isFeatureEnabled: Bool, hasEngineAssets: Bool) -> Bool {
        isFeatureEnabled && !hasEngineAssets
    }

    private var shouldShow: Bool {
        Self.shouldShow(
            isFeatureEnabled: featureCatalog.isEnabled(.wpeImport),
            hasEngineAssets: WorkshopStepState.hasEngineAssets(
                library: engineAssets,
                installer: engineInstaller
            )
        )
    }

    var body: some View {
        if shouldShow {
            InlineNoticeBanner(
                tint: DesignTokens.Colors.Status.warning,
                symbol: "shippingbox.and.arrow.backward",
                title: Text("Wallpaper Engine assets aren't set up"),
                message: Text("Missing shared assets may leave parts of a scene invisible."),
                surface: .content
            ) {
                Button {
                    NotificationCenter.default.post(
                        name: .openSettingsSection,
                        object: nil,
                        userInfo: [
                            "destination": SettingsNavigation.workshopSetup.rawValue,
                            "anchor": SettingsSearchAnchor.workshopAssets.rawValue
                        ]
                    )
                } label: {
                    Label("Get Assets", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint(Text("Opens the Workshop settings page to download or link Wallpaper Engine assets"))
            }
            .transition(.opacity)
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.lg)
            .task {
                engineInstaller.refreshManagedInstallState()
            }
        }
    }
}
#endif
