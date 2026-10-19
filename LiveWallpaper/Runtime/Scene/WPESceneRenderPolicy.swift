#if !LITE_BUILD
/// Scene pacing shared by interactive surfaces, headless recording and display actors.
enum WPESceneRenderPolicy {
    static let defaultPreferredFPS = 30
    static let adaptiveFrameRateFloor = 15
}
#endif
