#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE

/// Shared scene capabilities consumed by UI/policy, independent of whether the
/// session owns a renderer or presents one slice of a group-owned renderer.
@MainActor
protocol SceneWallpaperRuntime: WallpaperPlaybackControllable, WallpaperIntentMachineAdopting,
    WallpaperCriticalMemoryPressureResponding {
    var loadFailureCause: WallpaperFailureCause? { get }
    var loadError: SceneRenderingError? { get }
    var loadProgress: String? { get }
    var hasPresentedFrame: Bool? { get }
    var rendererDiagnostics: SceneRendererDiagnostics? { get }
    var rendererRuntimeActivity: WPESceneRuntimeActivity? { get }
    var mayPerformRuntimeWork: Bool { get }
    var isHibernated: Bool { get }
    var onRuntimeErrorChange: (@MainActor () -> Void)? { get set }
    var onRuntimeActivityChange: (@MainActor () -> Void)? { get set }
    var frameRateController: (any WallpaperFrameRateConfigurable)? { get }
    var audioController: (any WallpaperAudioConfigurable)? { get }
    func pollRendererState() async
    func captureLivePosterFromNextFrame() async -> NSImage?
    func applyPreviewPerformanceProfile(_ profile: WallpaperPerformanceProfile)
    func clearPreviewPerformanceOverride()
    func setHibernationEligible(_ eligible: Bool)
    func setMouseInteractionEnabled(_ enabled: Bool)
    func setClickCaptureEnabled(_ enabled: Bool)
    func setSceneFitMode(_ mode: VideoFitMode)
    func scenePropertyBindings() async -> [String: [WPEScenePropertyBinding]]
    @discardableResult func advanceScenePropertyMutationIntent() -> ScenePropertyMutationToken
    func currentScenePropertyMutationToken() -> ScenePropertyMutationToken
    func isCurrentScenePropertyMutationIntent(_ token: ScenePropertyMutationToken) -> Bool
    func prepareScenePropertyPatch(_ patch: WPEScenePropertyPatch,
                                   expectedIntent token: ScenePropertyMutationToken) async -> PreparedScenePropertyPatch?
    func stageScenePropertyPosterCommit(overrides: [String: WallpaperEngineProjectPropertyValue]) -> ScenePropertyPosterCommit
    func stagedScenePropertyPosterCommit(matching revision: ScenePropertyOverridesRevision) -> ScenePropertyPosterCommit?
    func waitForScenePropertyPosterCommit(_ expected: ScenePropertyPosterCommit) async -> Bool
    func commitScenePropertyPatch(_ prepared: PreparedScenePropertyPatch, posterCommit: ScenePropertyPosterCommit,
                                  updatedDescriptor: SceneDescriptor) async -> Bool
}

extension SceneWallpaperSession: SceneWallpaperRuntime {}
#endif
