#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import LiveWallpaperProWPE
import Metal

@MainActor
final class SceneSpanWallpaperGroup {
    private final class Member {
        weak var session: SceneSpanWallpaperSession?
        init(_ session: SceneSpanWallpaperSession) {
            self.session = session
        }
    }

    let id: UUID
    var descriptor: SceneDescriptor
    let owner: SceneWallpaperSession
    let frames: WPESceneSpanFrames
    let density: CGFloat
    private var members: [CGDirectDisplayID: Member] = [:]
    private var displayFrames: [CGDirectDisplayID: CGRect]
    var onEmpty: (() -> Void)?

    init(id: UUID, descriptor: SceneDescriptor, owner: SceneWallpaperSession,
         frames: WPESceneSpanFrames, density: CGFloat, displayFrames: [CGDirectDisplayID: CGRect]) {
        self.id = id
        self.descriptor = descriptor
        self.owner = owner
        self.frames = frames
        self.density = density
        self.displayFrames = displayFrames
        owner.onRuntimeErrorChange = { [weak self] in
            self?.sessions.forEach { $0.onRuntimeErrorChange?() }
        }
        owner.onRuntimeActivityChange = { [weak self] in
            self?.sessions.forEach { $0.onRuntimeActivityChange?() }
        }
    }

    private var sessions: [SceneSpanWallpaperSession] {
        members.values.compactMap(\.session)
    }

    var canvasFrame: CGRect {
        displayFrames.values.reduce(CGRect.null) { $0.union($1) }
    }

    func makeMember(for screen: Screen, configuration: ScreenConfiguration) throws -> SceneSpanWallpaperSession {
        displayFrames[screen.id] = screen.frame
        let session = try SceneSpanWallpaperSession(group: self, screen: screen, configuration: configuration)
        members[screen.id] = Member(session)
        reconcile()
        return session
    }

    func discardUnattachedMember(for id: CGDirectDisplayID) {
        guard members[id]?.session == nil else { return }
        displayFrames[id] = nil
        if sessions.isEmpty {
            discardIfUnused()
        } else {
            updateLayout()
        }
    }

    func discardIfUnused() {
        guard sessions.isEmpty else { return }
        owner.cleanup()
        frames.reset(generation: -1)
        onEmpty?()
    }

    func remove(_ session: SceneSpanWallpaperSession) {
        guard members[session.screenID]?.session === session else { return }
        members[session.screenID] = nil
        displayFrames[session.screenID] = nil
        if sessions.isEmpty {
            discardIfUnused()
        } else {
            updateLayout()
            reconcile()
        }
    }

    func updateFrame(_ frame: CGRect, for id: CGDirectDisplayID) {
        guard displayFrames[id] != frame else { return }
        displayFrames[id] = frame
        updateLayout()
    }

    private func updateLayout() {
        for session in sessions {
            session.updatePresentation(.init(canvasFrame: canvasFrame, screenFrame: displayFrames[session.screenID] ?? .zero))
        }
        reconcile()
    }

    func reconcile() {
        let active = sessions.filter(\.isPlaying).sorted { $0.screenID < $1.screenID }
        if sessions.contains(where: \.userIntendsToPlay) {
            owner.play()
        } else {
            owner.pause()
        }
        owner.applyPerformanceProfile(active.isEmpty ? .suspended : .quality)
        owner.frameRateController?.setFrameRateCeiling(min(60, active.map(\.frameRateCeiling).max() ?? 30))
        owner.frameRateController?.setAdaptiveFrameRateThrottle(!active.isEmpty && active.allSatisfy(\.adaptiveThrottle))
        let audioLeader = active.first(where: { !$0.muted })
        owner.audioController?.setAudioMuted(audioLeader == nil)
        owner.audioController?.setAudioVolume(audioLeader?.volume ?? 0)
        owner.setMouseInteractionEnabled(active.contains(where: \.mouseEnabled))
        owner.setClickCaptureEnabled(active.contains(where: \.clickEnabled))
        owner.setHibernationEligible(!sessions.isEmpty && sessions.allSatisfy(\.hibernationEligible))
        owner.setCriticalMemoryPressureActive(sessions.contains(where: \.criticalPressure))
        owner.updateSpanViewport(canvasFrame, density: density,
                                 interactiveFrames: active.filter { $0.mouseEnabled || $0.clickEnabled }.map(\.displayFrame))
        owner.spanSurface.setSpanClockScreen(active.first?.wallpaperWindow?.screen)
    }

    func publishClick(_ frame: WPEPointerFrame, from session: SceneSpanWallpaperSession) {
        guard session.isPlaying, session.clickEnabled else { return }
        let canvas = canvasFrame
        let display = session.displayFrame
        func global(_ local: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2((Double(display.minX - canvas.minX) + local.x * Double(display.width)) / Double(canvas.width),
                  (Double(canvas.maxY - display.maxY) + local.y * Double(display.height)) / Double(canvas.height))
        }
        owner.spanSurface.mailbox.publishPointerFrame(.init(position: global(frame.position), clickPosition: global(frame.clickPosition),
                                                            isDown: frame.isDown, isRightDown: frame.isRightDown))
        Task { await owner.spanRenderActor.renderFrame() }
    }
}

@MainActor
final class SceneSpanWallpaperSession: SceneWallpaperRuntime, WallpaperFrameRateConfigurable, WallpaperAudioConfigurable {
    let wallpaperType: WallpaperType = .scene
    let group: SceneSpanWallpaperGroup
    let screenID: CGDirectDisplayID
    private var window: VideoWallpaperWindow?
    private let surface: WPERenderSurface
    private let actor: WPEDisplayRenderActor
    private let presented = WPESceneSpanPresentationState()
    private var startup: Task<Void, Never>?
    private var stopped = false
    private var profile: WallpaperPerformanceProfile = .quality
    private var preview: WallpaperPerformanceProfile?
    var playbackMachine = WallpaperPlaybackStateMachine()
    private(set) var displayFrame: CGRect
    private(set) var frameRateCeiling: Int
    private(set) var adaptiveThrottle = false
    private(set) var muted = true
    private(set) var volume: Double
    private(set) var mouseEnabled: Bool
    private(set) var clickEnabled = false
    private(set) var hibernationEligible = false
    private(set) var criticalPressure = false
    var onRuntimeErrorChange: (@MainActor () -> Void)?
    var onRuntimeActivityChange: (@MainActor () -> Void)?

    init(group: SceneSpanWallpaperGroup, screen: Screen, configuration: ScreenConfiguration) throws {
        self.group = group
        screenID = screen.id
        displayFrame = screen.frame
        frameRateCeiling = configuration.frameRateLimit.frameRate(forRefreshRate: Double(screen.nsScreen.configuredFramesPerSecond))
        volume = configuration.videoVolume
        mouseEnabled = configuration.sceneMouseInteractionEnabled
        guard let device = MTLCreateSystemDefaultDevice() else { throw WPEMetalRenderExecutorError.commandQueueUnavailable }
        let window = VideoWallpaperWindow(frame: screen.frame)
        self.window = window
        surface = WPERenderSurface(frame: CGRect(origin: .zero, size: screen.frame.size), device: device, targetScreen: screen.nsScreen, allowsHDR: false)
        window.contentView = surface.mtkView
        actor = WPEDisplayRenderActor(label: "com.loomscreen.scene-span.present.\(screen.id)")
        let presenter = try WPESceneSpanPresenter(device: device, layer: WPEPresentLayer(layer: surface.metalLayer),
                                                  frames: group.frames, state: presented, producer: group.owner.spanRenderActor,
                                                  configuration: .init(canvasFrame: group.canvasFrame, screenFrame: screen.frame), density: group.density)
        surface.attach(client: WPERenderSurfaceClientShim(renderActor: actor, backing: .renderThread), monitorsPointer: false)
        surface.mtkView.onPointerFrameChange = { [weak self] frame in
            guard let self else { return }
            self.group.publishClick(frame, from: self)
        }
        startup = Task { [actor, surface] in
            await actor.adoptSpanPresenter(.init(presenter: presenter))
            await actor.setLinkPreferredFPS(min(60, frameRateCeiling))
            await actor.setLinkPaused(false)
            guard !Task.isCancelled else { return }
            surface.startDisplayLinkDriver(renderActor: actor)
        }
        window.orderBack(nil)
    }

    var userIntendsToPlay: Bool {
        playbackMachine.userIntendsToPlay
    }

    var isPlaying: Bool {
        !stopped && userIntendsToPlay && profile == .quality && preview != .suspended
    }

    var isHibernated: Bool {
        group.owner.isHibernated
    }

    var runtimeError: WallpaperRuntimeError? {
        group.owner.runtimeError
    }

    var loadFailureCause: WallpaperFailureCause? {
        group.owner.loadFailureCause
    }

    var loadError: SceneRenderingError? {
        group.owner.loadError
    }

    var loadProgress: String? {
        group.owner.loadProgress
    }

    var rendererDiagnostics: SceneRendererDiagnostics? {
        group.owner.rendererDiagnostics
    }

    var rendererRuntimeActivity: WPESceneRuntimeActivity? {
        group.owner.rendererRuntimeActivity
    }

    var mayPerformRuntimeWork: Bool {
        isPlaying && group.owner.mayPerformRuntimeWork
    }

    var hasPresentedFrame: Bool? {
        guard !stopped else { return nil }
        guard let frame = group.frames.latest() else { return false }
        return presented.hasPresented(generation: frame.generation)
    }

    var summary: WallpaperSessionSummary {
        .init(wallpaperType: .scene, activity: loadError != nil ? .error : (isPlaying ? .active : (userIntendsToPlay ? .policySuspended : .paused)),
              supportsPlaybackControl: true, subtitle: loadError?.errorDescription.map(LogPrivacyRedactor.scrub))
    }

    var videoPlayer: WallpaperVideoPlayer? {
        nil
    }

    var wallpaperWindow: NSWindow? {
        window
    }

    var frameRateController: (any WallpaperFrameRateConfigurable)? {
        stopped ? nil : self
    }

    var audioController: (any WallpaperAudioConfigurable)? {
        stopped ? nil : self
    }

    func play() {
        playbackMachine.userPlay(); reconcile()
    }

    func pause() {
        playbackMachine.userPause(); reconcile()
    }

    func show() {
        window?.orderBack(nil); reconcile()
    }

    func applyPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        self.profile = profile; reconcile()
    }

    func applyPreviewPerformanceProfile(_ profile: WallpaperPerformanceProfile) {
        preview = profile == .quality ? nil : profile; reconcile()
    }

    func clearPreviewPerformanceOverride() {
        preview = nil; reconcile()
    }

    func setFrameRateCeiling(_ framesPerSecond: Int) {
        frameRateCeiling = max(1, framesPerSecond); reconcile()
    }

    func setAdaptiveFrameRateThrottle(_ active: Bool) {
        adaptiveThrottle = active; group.reconcile()
    }

    func setAudioMuted(_ muted: Bool) {
        self.muted = muted; group.reconcile()
    }

    func setAudioVolume(_ volume: Double) {
        self.volume = volume; group.reconcile()
    }

    func setHibernationEligible(_ eligible: Bool) {
        hibernationEligible = eligible; group.reconcile()
    }

    func setCriticalMemoryPressureActive(_ active: Bool) {
        criticalPressure = active; group.reconcile()
    }

    func setMouseInteractionEnabled(_ enabled: Bool) {
        mouseEnabled = enabled; group.reconcile()
    }

    func setClickCaptureEnabled(_ enabled: Bool) {
        clickEnabled = enabled; reconcile()
    }

    func setSceneFitMode(_ mode: VideoFitMode) {
        group.owner.setSceneFitMode(mode)
    }

    private func reconcile() {
        guard !stopped else { return }
        actor.submitConfig(.performanceProfile(isPlaying ? .quality : .suspended))
        actor.submitConfig(.frameRateCeiling(min(60, frameRateCeiling)))
        surface.mtkView.clickCaptureEnabled = clickEnabled && isPlaying
        window?.setWallpaperMouseInteractionEnabled(clickEnabled && isPlaying)
        group.reconcile()
    }

    func updateFrame(to frame: CGRect) {
        displayFrame = frame
        window?.setFrame(frame, display: true)
        window?.contentView?.frame = CGRect(origin: .zero, size: frame.size)
        group.updateFrame(frame, for: screenID)
    }

    func updatePresentation(_ configuration: VideoSpanRenderConfiguration) {
        Task { await actor.updateSpanPresentation(configuration) }
    }

    func cleanup() {
        guard !stopped else { return }
        stopped = true
        startup?.cancel()
        let startup = startup
        let stop = surface.stopDisplayLinkDriver()
        window?.close()
        window = nil
        group.remove(self)
        Task { [actor] in
            await startup?.value
            await stop?.value
            await actor.teardownRenderer()
            await actor.shutdown()
        }
    }

    func prepareForDisplay(timeout: Duration) async -> WallpaperPreparationResult {
        await WallpaperPreparationWaiter.wait(timeout: timeout, pollInterval: .milliseconds(25)) { [weak self] in
            guard let self, !stopped else { return .cancelled }
            await group.owner.pollRendererState()
            if loadError != nil {
                return .failed
            }
            return hasPresentedFrame == true ? .ready : nil
        }
    }

    func retry() async {
        await group.owner.retry()
    }

    func pollRendererState() async {
        await group.owner.pollRendererState()
    }

    func captureLivePosterFromNextFrame() async -> NSImage? {
        await group.owner.captureLivePosterFromNextFrame()
    }

    func scenePropertyBindings() async -> [String: [WPEScenePropertyBinding]] {
        await group.owner.scenePropertyBindings()
    }

    @discardableResult func advanceScenePropertyMutationIntent() -> ScenePropertyMutationToken {
        group.owner.advanceScenePropertyMutationIntent()
    }

    func currentScenePropertyMutationToken() -> ScenePropertyMutationToken {
        group.owner.currentScenePropertyMutationToken()
    }

    func isCurrentScenePropertyMutationIntent(_ token: ScenePropertyMutationToken) -> Bool {
        group.owner.isCurrentScenePropertyMutationIntent(token)
    }

    func prepareScenePropertyPatch(_ patch: WPEScenePropertyPatch, expectedIntent token: ScenePropertyMutationToken) async -> PreparedScenePropertyPatch? {
        await group.owner.prepareScenePropertyPatch(patch, expectedIntent: token)
    }

    func stageScenePropertyPosterCommit(overrides: [String: WallpaperEngineProjectPropertyValue]) -> ScenePropertyPosterCommit {
        group.owner.stageScenePropertyPosterCommit(overrides: overrides)
    }

    func stagedScenePropertyPosterCommit(matching revision: ScenePropertyOverridesRevision) -> ScenePropertyPosterCommit? {
        group.owner.stagedScenePropertyPosterCommit(matching: revision)
    }

    func waitForScenePropertyPosterCommit(_ expected: ScenePropertyPosterCommit) async -> Bool {
        await group.owner.waitForScenePropertyPosterCommit(expected)
    }

    func commitScenePropertyPatch(_ prepared: PreparedScenePropertyPatch, posterCommit: ScenePropertyPosterCommit, updatedDescriptor: SceneDescriptor) async -> Bool {
        let committed = await group.owner.commitScenePropertyPatch(prepared, posterCommit: posterCommit, updatedDescriptor: updatedDescriptor)
        if committed {
            group.descriptor = updatedDescriptor
        }
        return committed
    }
}
#endif
