#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Shows missing shared-asset setup even when a scene loads without an error.
struct EngineAssetsBanner: View {
    @Environment(\.featureCatalog) private var featureCatalog
    /// Observed for the published flags only, not a bookmark resolve per layout pass.
    @State private var engineAssets = WPEEngineAssetsLibrary.shared
    @State private var engineInstaller = WPEEngineAssetsInstaller.shared

    /// Pure so the trigger can be tested without a renderer or a view host.
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
            // Inset lives inside the `if`: applied by the caller it would reserve
            // space around an empty view whenever the assets are set up.
            .padding(.horizontal, DesignTokens.Spacing.xl)
            .padding(.top, DesignTokens.Spacing.lg)
            .task {
                engineInstaller.refreshManagedInstallState()
            }
        }
    }
}
#endif
