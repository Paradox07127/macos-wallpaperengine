#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI


// MARK: - Step state

enum WorkshopStepState: Equatable {
    case notStarted
    case working
    case attention
    case ready

    var tint: Color {
        switch self {
        case .notStarted: return DesignTokens.Colors.textTertiary
        case .working: return DesignTokens.Colors.textSecondary
        case .attention: return DesignTokens.Colors.Status.warning
        case .ready: return DesignTokens.Colors.Status.active
        }
    }

    var statusText: LocalizedStringKey {
        switch self {
        case .notStarted: "Not set"
        case .working: "Checking…"
        case .attention: "Action needed"
        case .ready: "Ready"
        }
    }
}

extension WorkshopStepState {
    @MainActor
    static func engineAssets(
        library: WPEEngineAssetsLibrary,
        installer: WPEEngineAssetsInstaller
    ) -> WorkshopStepState {
        if installer.isBusy { return .working }
        if installer.updateAvailable { return .attention }
        if installer.hasManagedInstall || library.isAuthorized { return .ready }
        return .notStarted
    }

    /// Whether the shared `assets/` are actually reachable right now. Narrower
    /// than `== .ready`: an install with an update pending still renders.
    @MainActor
    static func hasEngineAssets(
        library: WPEEngineAssetsLibrary,
        installer: WPEEngineAssetsInstaller
    ) -> Bool {
        installer.hasManagedInstall || library.isAuthorized
    }
}
#endif
