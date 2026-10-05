#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The applied scene and its renderer's state, read from the session's cached fields.
@MainActor
struct DetailSceneStatus {
    let origin: WPEOrigin
    let descriptor: SceneDescriptor
    let session: (any SceneWallpaperRuntime)?
    let state: SceneRenderState

    init?(screen: Screen, configuration: ScreenConfiguration?) {
        guard case let .scene(descriptor)? = configuration?.activeWallpaper,
              let origin = configuration?.wpeOrigin else { return nil }
        self.origin = origin
        self.descriptor = descriptor
        session = screen.runtimeSession as? any SceneWallpaperRuntime
        state = SceneRenderState.derivedState(session: session)
    }

    var renderFailure: FallbackReason? {
        if case let .error(reason) = state {
            reason
        } else {
            nil
        }
    }

    /// What the Workshop button searches for; nil unless the ID is a Steam one, all digits.
    static func workshopSearchQuery(for origin: WPEOrigin) -> String? {
        !origin.workshopID.isEmpty && origin.workshopID.allSatisfy(\.isNumber) ? origin.title : nil
    }

    func logSheet(onDismiss: @escaping () -> Void) -> DiagnosticLogSheet {
        DiagnosticLogSheet(
            title: origin.title,
            log: WPERenderDiagnosticReport.make(
                descriptor: descriptor, diagnostics: session?.rendererDiagnostics, errorCode: renderFailure?.code
            ),
            tint: renderFailure?.tint ?? .accentColor,
            onDismiss: onDismiss,
            batchLog: { WPESceneTestingReports.shared.make() }
        )
    }
}
#endif
