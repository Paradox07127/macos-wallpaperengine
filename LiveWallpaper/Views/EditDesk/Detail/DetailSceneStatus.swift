#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The applied scene and its renderer's state, read the way the old scene page reads them.
@MainActor
struct DetailSceneStatus {
    let origin: WPEOrigin
    let descriptor: SceneDescriptor
    let session: SceneWallpaperSession?
    let state: SceneRenderState

    init?(screen: Screen, configuration: ScreenConfiguration?) {
        guard case let .scene(descriptor)? = configuration?.activeWallpaper,
              let origin = configuration?.wpeOrigin else { return nil }
        self.origin = origin
        self.descriptor = descriptor
        session = screen.runtimeSession as? SceneWallpaperSession
        state = SceneDetailView.derivedState(session: session)
    }

    var renderFailure: FallbackReason? {
        if case let .error(reason) = state {
            reason
        } else {
            nil
        }
    }

    func logSheet(onDismiss: @escaping () -> Void) -> DiagnosticLogSheet {
        DiagnosticLogSheet(
            title: origin.title,
            log: WPERenderDiagnosticReport.make(
                descriptor: descriptor, diagnostics: session?.rendererDiagnostics, errorCode: renderFailure?.code
            ),
            tint: renderFailure?.tint ?? .accentColor,
            onDismiss: onDismiss
        )
    }
}
#endif
