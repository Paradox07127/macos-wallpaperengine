import Foundation
import IOSurface

/// Vended by the out-of-process scene renderer.
///
/// The app target declares this protocol separately for now (`SceneRunnerProbe`
/// in the test bundle): sharing one file needs a target-membership change to
/// `project.pbxproj`, which is a manual step. `@objc` protocols are matched by
/// selector at runtime, so the two declarations must stay selector-identical.
@objc protocol SceneRunnerProtocol {

    /// Renders a solid colour into an `IOSurface`-backed Metal texture and hands
    /// the surface back.
    ///
    /// This exists to answer the one question the whole out-of-process design
    /// rests on: can a texture drawn by this unsandboxed service be mapped and
    /// sampled by the sandboxed app? Colour components are 0...255 so the caller
    /// can assert on exact bytes — "it didn't crash" is not an answer.
    func renderProbeSurface(
        width: Int,
        height: Int,
        red: Int,
        green: Int,
        blue: Int,
        with reply: @escaping (IOSurface?, String?) -> Void
    )
}
