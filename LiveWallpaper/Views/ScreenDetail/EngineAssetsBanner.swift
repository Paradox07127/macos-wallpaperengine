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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.title3)
                    .foregroundStyle(DesignTokens.Colors.Status.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wallpaper Engine assets aren't set up")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Missing shared assets may leave parts of a scene invisible.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 8)
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
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint(Text("Opens the Workshop settings page to download or link Wallpaper Engine assets"))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.md), tint: DesignTokens.Colors.Status.warning)
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Corner.md, style: .continuous)
                    .strokeBorder(DesignTokens.Colors.Status.warning.opacity(0.30), lineWidth: 1)
            }
            .transition(.opacity)
            // Inset lives inside the `if`: applied by the caller it would reserve
            // space around an empty view whenever the assets are set up.
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .task {
                engineInstaller.refreshManagedInstallState()
            }
        }
    }
}
#endif
