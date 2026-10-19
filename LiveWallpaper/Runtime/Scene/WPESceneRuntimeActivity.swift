#if !LITE_BUILD
struct WPESceneRuntimeActivity: Equatable, Sendable {
    /// False while the scene is static, hibernated or unloaded.
    let producesFrames: Bool
    /// A scene sound runtime exists, including while its output is muted.
    let audible: Bool
}
#endif
