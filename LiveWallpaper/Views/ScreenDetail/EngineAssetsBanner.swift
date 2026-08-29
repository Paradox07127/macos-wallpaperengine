#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Page-level warning that Wallpaper Engine's shared `assets/` are not set up.
///
/// It used to hang off the applied scene's detail card and fire only after a
/// load failure or unresolved refs. Both halves of that were wrong: the missing
/// assets do not fail a scene — measured on 3558034522, an unlinked install
/// leaves 144 references unresolved and the scene still renders, four passes
/// short and with no error to report — and a reader with no scene applied never
/// saw the card at all. Missing assets are a setup state, so the banner reads
/// the setup state.
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
                    Text("Scenes reference textures, shaders and models that ship with Wallpaper Engine. Without them those layers are skipped and the scene still renders, so nothing reports an error.")
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
