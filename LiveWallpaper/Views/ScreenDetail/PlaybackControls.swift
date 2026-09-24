import SwiftUI
import AppKit
import LiveWallpaperCore

#Preview("Custom frame rate") {
    @Previewable @State var rate = FrameRateLimit.fps24
    FrameRateControl(value: $rate, displayFramesPerSecond: 60)
        .frame(width: 320)
        .padding(16)
}

struct PlaybackControls: View {
    var screen: Screen
    var wallpaperType: WallpaperType

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var muted: Bool
    @Binding var videoVolume: Double
    @Binding var frameRateLimit: FrameRateLimit
    @Binding var syncToLockScreen: Bool
    @Binding var sceneMouseInteractionEnabled: Bool
    /// Real pointer input; steals desktop clicks while on.
    @Binding var sceneClickCaptureEnabled: Bool

    @AppStorage("Scene.ClickCapture.Acknowledged") private var clickCaptureAcknowledged = false
    @AppStorage("Web.Interaction.Acknowledged") private var webInteractionAcknowledged = false
    /// The wallpaper type whose Interaction switch waits on first-use confirmation; nil when none does.
    @State private var pendingInteraction: WallpaperType?
    /// HTML-only: mute path for WKWebView media (`AVPlayer.muted` is a no-op here).
    var htmlConfig: Binding<HTMLConfig>?
    var playbackSpeed: Binding<Double>?
    /// `.forceSDR` owns `videoComposition`, so the frame-rate cap is dimmed/ignored.
    var videoColorSpace: VideoColorSpace = .auto
    var showsResetPlayback: Bool = false
    var onResetPlayback: () -> Void = {}

    @State private var showingVolume = false
    @State private var showingSpeed = false
    @State private var showingFrameRate = false
    @State private var trustStore = TrustedHostStore.shared
    @State private var originLimitShown: OriginLimitAnchor?
    @State private var pendingTrustOrigin: TrustedHTMLOrigin?

    private enum OriginLimitAnchor {
        case audio, javaScript
    }

    private var frameRateSymbol: String {
        if frameRateLimit == .matchDisplay {
            return "gauge.with.dots.needle.100percent"
        }
        switch frameRateLimit.rawValue {
        case ...24: return "gauge.with.dots.needle.0percent"
        case ...45: return "gauge.with.dots.needle.33percent"
        default: return "gauge.with.dots.needle.67percent"
        }
    }

    private func frameRateTitle(_ limit: FrameRateLimit) -> String {
        limit.title(forRefreshRate: Double(screenManager.getScreenRefreshRate(for: screen.id)))
    }

    @State private var lockScreenExtracted = false
    /// Drop stale "clear ✓" Tasks when a newer toggle wins (same pattern as schedule conflict flash).
    @State private var lockScreenFeedbackGeneration = 0

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if let origin = webEffective?.limitedBy {
                originLimitedControl(origin, symbol: "speaker.slash", title: "Audio", anchor: .audio)
            } else {
                audioControl
            }
            ForEach(visibleRows, id: \.self) { kind in
                control(kind)
            }
            if showsResetPlayback {
                resetPlaybackAccessory
            }
        }
        .buttonStyle(.borderless)
        .htmlOriginTrustDialog(
            pending: $pendingTrustOrigin, screen: screen, source: webSource, config: htmlConfig?.wrappedValue ?? .default
        )
        .alert(
            "Enable Wallpaper Interaction?",
            isPresented: Binding(
                get: { pendingInteraction != nil },
                set: { presented in
                    if !presented {
                        pendingInteraction = nil
                    }
                }
            ),
            presenting: pendingInteraction
        ) { kind in
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                if kind == .scene {
                    clickCaptureAcknowledged = true
                    setClickCapture(true)
                } else if let htmlConfig {
                    webInteractionAcknowledged = true
                    htmlConfigBinding(htmlConfig, keyPath: \.allowMouseInteraction).wrappedValue = true
                }
            }
        } message: { kind in
            if kind == .scene {
                Text("Clicks go to the scene instead of desktop icons and the desktop context menu on this display. Turn off Interaction to restore desktop clicks.")
            } else {
                Text("Clicks and scrolls go to the web page instead of desktop icons and the desktop context menu on this display. Turn off Interaction to restore desktop clicks.")
            }
        }
    }

    @ViewBuilder
    private var resetPlaybackAccessory: some View {
        if showsResetPlayback {
            Button(action: onResetPlayback) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(Text("Reset playback to display defaults"))
            .accessibilityLabel(Text("Reset playback"))
        }
    }

    // MARK: - Row layout

    private enum PlaybackRow: Hashable {
        case speed, frameRate, mouseInteraction, clickInteraction, syncToLockScreen
        case webJavaScript, webInteraction
    }

    private var visibleRows: [PlaybackRow] {
        var rows: [PlaybackRow] = []
        if playbackSpeed != nil {
            rows.append(.speed)
        }
        rows.append(.frameRate)
        if showsMouseInteractionRow {
            rows.append(contentsOf: [.mouseInteraction, .clickInteraction])
        }
        if showsSyncToLockScreenRow {
            rows.append(.syncToLockScreen)
        }
        if htmlConfig != nil {
            rows.append(contentsOf: [.webJavaScript, .webInteraction])
        }
        return rows
    }

    private var audioControl: some View {
        let isMuted = webEffective?.muted ?? audioMutedBinding.wrappedValue
        return Button {
            showingVolume = true
        } label: {
            PreviewControlLabel(
                systemImage: isMuted ? "speaker.slash" : "speaker.wave.2",
                title: "Audio",
                isActive: !isMuted
            )
        }
        .help(Text("Audio"))
        .accessibilityLabel(Text("Audio"))
        .accessibilityValue(audioAccessibilityValue(
            isMuted: isMuted,
            percent: Self.audioPercent(atSliderValue: unifiedAudioBinding.wrappedValue)
        ))
        .appLanguagePopover(isPresented: $showingVolume, arrowEdge: .bottom) {
            volumePopover
        }
    }

    private var volumePopover: some View {
        CoalescedSlider(
            value: unifiedAudioBinding.wrappedValue,
            in: 0 ... 1,
            owner: screen.id,
            accessibilityLabel: Text("Audio"),
            accessibilityValue: { live in
                audioAccessibilityValue(
                    isMuted: Self.audioIsMuted(atSliderValue: live),
                    percent: Self.audioPercent(atSliderValue: live)
                )
            },
            write: { unifiedAudioBinding.wrappedValue = $0 },
            readout: { live in
                audioLevelLabel(
                    isMuted: Self.audioIsMuted(atSliderValue: live),
                    percent: Self.audioPercent(atSliderValue: live)
                )
                .font(DesignTokens.Typography.metric)
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Inspector.sliderValueWidth, alignment: .trailing)
            }
        )
        .frame(width: 200)
        .padding(DesignTokens.Spacing.md)
    }

    @ViewBuilder
    private func control(_ kind: PlaybackRow) -> some View {
        switch kind {
        case .speed:
            if let playbackSpeed {
                speedControl(playbackSpeed)
            }
        case .frameRate:
            frameRateControl
        case .mouseInteraction:
            glyphToggle(
                on: "cursorarrow.rays",
                title: "Cursor",
                isOn: sceneMouseInteractionEnabled,
                binding: mouseInteractionBinding,
                label: Text("Follow cursor"),
                help: Text("Effects follow the cursor without capturing desktop clicks.")
            )
        case .clickInteraction:
            glyphToggle(
                on: "cursorarrow.click",
                title: "Interaction",
                isOn: sceneClickCaptureEnabled,
                binding: clickInteractionBinding,
                label: Text("Interaction"),
                help: Text("Sends clicks to the scene instead of this display’s desktop.")
            )
        case .syncToLockScreen:
            lockScreenControl
        case .webJavaScript:
            if let origin = webEffective?.limitedBy {
                originLimitedControl(origin, symbol: "curlybraces", title: "JavaScript", anchor: .javaScript)
            } else if let htmlConfig, let web = webEffective {
                glyphToggle(
                    on: "curlybraces",
                    title: "JavaScript",
                    isOn: web.allowsJavaScript,
                    binding: htmlConfigBinding(htmlConfig, keyPath: \.allowJavaScript),
                    label: Text("JavaScript"),
                    help: Text("Scripted content may not display when disabled.")
                )
            }
        case .webInteraction:
            if let htmlConfig {
                glyphToggle(
                    on: "cursorarrow.click",
                    title: "Interaction",
                    isOn: htmlConfig.wrappedValue.allowMouseInteraction,
                    binding: webInteractionBinding(htmlConfig),
                    label: Text("Interaction"),
                    help: Text("Sends clicks and scrolls to the wallpaper; desktop icons and the Dock cannot receive clicks.")
                )
            }
        }
    }

    private func speedControl(_ speed: Binding<Double>) -> some View {
        Button {
            showingSpeed = true
        } label: {
            PreviewControlLabel(systemImage: "gauge.with.needle", title: "Speed")
        }
        .help(Text("Playback speed"))
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(verbatim: Self.speedLabel(speed.wrappedValue)))
        .appLanguagePopover(isPresented: $showingSpeed, arrowEdge: .bottom) {
            VStack(spacing: DesignTokens.Spacing.sm) {
                Slider(value: speed, in: 0.5 ... 2.0, step: 0.25)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Playback speed"))
                Text(verbatim: Self.speedLabel(speed.wrappedValue))
                    .font(DesignTokens.Typography.metric)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180)
            .padding(DesignTokens.Spacing.md)
        }
    }

    /// Gated on `.video`: a scene's frame-rate control must stay usable when a
    /// previous video wallpaper left Force SDR set on this screen.
    static func frameRateDisabled(wallpaperType: WallpaperType, videoColorSpace: VideoColorSpace) -> Bool {
        wallpaperType == .video && videoColorSpace == .forceSDR
    }

    static func speedLabel(_ speed: Double) -> String {
        abs(speed - speed.rounded()) < 0.001 ? "\(Int(speed))×" : String(format: "%.2g×", speed)
    }

    /// What a web page runs with, which is what its controls show. `limitedBy` is the untrusted origin
    /// overriding the config; nil when the config's own values apply.
    static func webEffective(
        _ config: HTMLConfig, source: HTMLSource?, trustedOrigins: Set<TrustedHTMLOrigin>
    ) -> (limitedBy: TrustedHTMLOrigin?, allowsJavaScript: Bool, muted: Bool) {
        let trust = source.map { HTMLTrust.evaluate(source: $0, trustedOrigins: trustedOrigins) } ?? .localContent
        let limitedBy: TrustedHTMLOrigin? = if case let .untrustedRemote(origin) = trust {
            origin
        } else {
            nil
        }
        return (
            limitedBy,
            trust.effectiveAllowJavaScript(requested: config.allowJavaScript),
            trust.effectiveMuteAudio(requested: config.muteAudio)
        )
    }

    /// The saved target stays distinct from Max on every display.
    private var frameRateControl: some View {
        let forceSDRActive = Self.frameRateDisabled(wallpaperType: wallpaperType, videoColorSpace: videoColorSpace)
        return Button {
            showingFrameRate = true
        } label: {
            PreviewControlLabel(systemImage: frameRateSymbol, title: "Frame Rate")
        }
        .disabled(forceSDRActive)
        .help(forceSDRActive
            ? Text("Disabled while Force SDR is active")
            : Text(verbatim: frameRateTitle(frameRateLimit)))
        .accessibilityLabel(Text("Frame rate limit"))
        .accessibilityValue(forceSDRActive
            ? Text("Disabled — Force SDR is active", comment: "Accessibility value when the frame-rate picker is dimmed because Force SDR owns the video composition slot.")
            : Text(verbatim: frameRateTitle(frameRateLimit)))
        .appLanguagePopover(isPresented: $showingFrameRate, arrowEdge: .bottom) {
            frameRatePopover
        }
    }

    private var frameRatePopover: some View {
        FrameRateControl(
            value: frameRateBinding,
            displayFramesPerSecond: screenManager.getScreenRefreshRate(for: screen.id)
        )
        .id(screen.id)
        .frame(width: 320)
        .padding(DesignTokens.Spacing.md)
    }

    private var lockScreenControl: some View {
        glyphToggle(
            on: "photo.on.rectangle",
            title: "On Lock",
            isOn: syncToLockScreen,
            binding: syncToLockScreenBinding,
            label: Text("Capture this video's frame when locking"),
            help: Text("Captures this video's current frame at lock and sets it as the macOS desktop picture."),
            badge: lockScreenExtracted
        )
    }

    private func glyphToggle(
        on symbol: String,
        title: LocalizedStringKey,
        isOn: Bool,
        binding: Binding<Bool>,
        label: Text,
        help: Text,
        badge: Bool = false
    ) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            PreviewControlLabel(systemImage: symbol, title: title, isActive: isOn)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(DesignTokens.Colors.Status.active)
                            .accessibilityHidden(true)
                    }
                }
        }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }

    // MARK: - Origin limit

    private var webSource: HTMLSource? {
        screenManager.getConfiguration(for: screen)?.htmlSource
    }

    /// nil when this is not a web page.
    private var webEffective: (limitedBy: TrustedHTMLOrigin?, allowsJavaScript: Bool, muted: Bool)? {
        htmlConfig.map { Self.webEffective($0.wrappedValue, source: webSource, trustedOrigins: trustStore.originSet) }
    }

    private func originLimitedControl(
        _ origin: TrustedHTMLOrigin, symbol: String, title: LocalizedStringKey, anchor: OriginLimitAnchor
    ) -> some View {
        Button {
            originLimitShown = anchor
        } label: {
            PreviewControlLabel(systemImage: symbol, title: title, tint: DesignTokens.Colors.Status.warning)
        }
        .help(Text("Limited by origin"))
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text("Limited by origin"))
        .appLanguagePopover(
            isPresented: Binding(
                get: { originLimitShown == anchor },
                set: { presented in
                    if !presented {
                        originLimitShown = nil
                    }
                }
            ),
            arrowEdge: .bottom
        ) {
            originLimitPopover(origin)
        }
    }

    private func originLimitPopover(_ origin: TrustedHTMLOrigin) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Label("Limited by origin", systemImage: "exclamationmark.shield")
                .font(DesignTokens.Typography.bodyEmphasized)
            Group {
                if origin.canBeTrusted {
                    Text("JavaScript stays off and audio stays muted until you trust \(origin.displayName).")
                } else {
                    Text("Scripts disabled. Only HTTPS, loopback, and local-network origins can run JavaScript.")
                }
            }
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if origin.canBeTrusted {
                Button("Trust This Origin") {
                    originLimitShown = nil
                    pendingTrustOrigin = origin
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .frame(width: 240, alignment: .leading)
        .padding(DesignTokens.Spacing.md)
    }

    /// Mute dead zone on the volume slider (avoids leaking 1–2% from a stray drag).
    static let audioDeadZone: Double = 0.04

    private func audioLevelLabel(isMuted: Bool, percent: Int) -> some View {
        if isMuted {
            Text("Muted", comment: "Audio level display when the wallpaper is muted")
        } else {
            Text(verbatim: "\(percent)%")
        }
    }

    private func audioAccessibilityValue(isMuted: Bool, percent: Int) -> Text {
        if isMuted {
            Text("Muted", comment: "Audio level display when the wallpaper is muted")
        } else {
            Text("\(percent) percent", comment: "Audio level accessibility value, e.g. \"35 percent\".")
        }
    }

    // MARK: - Row availability

    private var mouseInteractionBinding: Binding<Bool> {
        Binding(
            get: { sceneMouseInteractionEnabled },
            set: { newValue in
                guard sceneMouseInteractionEnabled != newValue else { return }
                sceneMouseInteractionEnabled = newValue
                screenManager.updateSceneMouseInteraction(newValue, for: screen)
            }
        )
    }

    private func setClickCapture(_ enabled: Bool) {
        guard sceneClickCaptureEnabled != enabled else { return }
        sceneClickCaptureEnabled = enabled
        screenManager.updateSceneClickCapture(enabled, for: screen)
    }

    private var showsMouseInteractionRow: Bool {
        wallpaperType == .scene
    }

    private var showsSyncToLockScreenRow: Bool {
        wallpaperType == .video && featureCatalog.isEnabled(.lockScreenSnapshots)
    }

    // MARK: - Rows

    private var clickInteractionBinding: Binding<Bool> {
        Binding(
            get: { sceneClickCaptureEnabled },
            set: { newValue in
                guard sceneClickCaptureEnabled != newValue else { return }
                if newValue, !clickCaptureAcknowledged {
                    pendingInteraction = .scene
                    return
                }
                setClickCapture(newValue)
            }
        )
    }

    private func webInteractionBinding(_ htmlConfig: Binding<HTMLConfig>) -> Binding<Bool> {
        let allowsInteraction = htmlConfigBinding(htmlConfig, keyPath: \.allowMouseInteraction)
        return Binding(
            get: { allowsInteraction.wrappedValue },
            set: { newValue in
                if newValue, !webInteractionAcknowledged {
                    pendingInteraction = .html
                    return
                }
                allowsInteraction.wrappedValue = newValue
            }
        )
    }

    // MARK: - Bindings

    private var audioMutedBinding: Binding<Bool> {
        if let htmlConfig {
            return htmlConfigBinding(htmlConfig, keyPath: \.muteAudio)
        }
        return Binding(
            get: { muted },
            set: { newValue in
                guard muted != newValue else { return }
                muted = newValue
                screenManager.updateMuted(newValue, for: screen)
            }
        )
    }

    /// Not a plain 0…1 volume: the bottom `audioDeadZone` is the mute region and the
    /// rest is remapped onto volume, so the readout must undo the same mapping.
    static func audioIsMuted(atSliderValue value: Double) -> Bool {
        value <= audioDeadZone
    }

    static func audioPercent(atSliderValue value: Double) -> Int {
        let normalized = (value - audioDeadZone) / (1 - audioDeadZone)
        return Int((clampedVolume(normalized) * 100).rounded())
    }

    private var unifiedAudioBinding: Binding<Double> {
        Binding(
            get: {
                if audioMutedBinding.wrappedValue { return 0 }
                let deadZone = Self.audioDeadZone
                return deadZone + Self.clampedVolume(currentVolume) * (1 - deadZone)
            },
            set: { sliderValue in
                let shouldMute = sliderValue <= Self.audioDeadZone
                let mutedBinding = audioMutedBinding

                if shouldMute {
                    if !mutedBinding.wrappedValue {
                        mutedBinding.wrappedValue = true
                    }
                    return
                }

                if mutedBinding.wrappedValue {
                    mutedBinding.wrappedValue = false
                }

                let normalized = (sliderValue - Self.audioDeadZone) / (1 - Self.audioDeadZone)
                let clampedValue = Self.clampedVolume(normalized)
                applyVolume(clampedValue)
            }
        )
    }

    private var currentVolume: Double {
        if let htmlConfig {
            return htmlConfig.wrappedValue.audioVolume
        }
        return videoVolume
    }

    private func applyVolume(_ value: Double) {
        if let htmlConfig {
            guard abs(htmlConfig.wrappedValue.audioVolume - value) > 0.001 else { return }
            var next = htmlConfig.wrappedValue
            next.audioVolume = HTMLConfig.clampedAudioVolume(value)
            htmlConfig.wrappedValue = next
            screenManager.updateHTMLConfig(next, for: screen)
            return
        }
        guard abs(videoVolume - value) > 0.001 else { return }
        videoVolume = value
        screenManager.updateVideoVolume(value, for: screen)
    }

    private static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, 0), 1)
    }

    private var frameRateBinding: Binding<FrameRateLimit> {
        Binding(
            get: { frameRateLimit },
            set: { newValue in
                guard frameRateLimit != newValue else { return }
                frameRateLimit = newValue
                screenManager.updateFrameRateLimit(newValue, for: screen)
            }
        )
    }

    private var syncToLockScreenBinding: Binding<Bool> {
        Binding(
            get: { syncToLockScreen },
            set: { newValue in
                guard syncToLockScreen != newValue else { return }
                syncToLockScreen = newValue
                screenManager.updateSetAsDesktopPicture(newValue, for: screen)
                guard newValue else {
                    lockScreenFeedbackGeneration += 1
                    lockScreenExtracted = false
                    return
                }
                lockScreenFeedbackGeneration += 1
                let generation = lockScreenFeedbackGeneration
                Task { @MainActor in
                    // Awaited: otherwise the confirmation appears before the frame is decoded,
                    // written or installed, and a failure never takes it back.
                    let captured = await screenManager.extractLockScreenFrame(for: screen) == .captured
                    guard generation == lockScreenFeedbackGeneration else { return }
                    guard captured else {
                        // Bumping the generation already invalidated the previous run's clear-timer,
                        // so this attempt has to put the tick away itself.
                        withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                            lockScreenExtracted = false
                        }
                        return
                    }
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                        lockScreenExtracted = true
                    }
                    try? await Task.sleep(for: .seconds(2))
                    guard generation == lockScreenFeedbackGeneration else { return }
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                        lockScreenExtracted = false
                    }
                }
            }
        )
    }

    private func htmlConfigBinding<Value: Equatable>(
        _ htmlConfig: Binding<HTMLConfig>,
        keyPath: WritableKeyPath<HTMLConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { htmlConfig.wrappedValue[keyPath: keyPath] },
            set: { newValue in
                guard htmlConfig.wrappedValue[keyPath: keyPath] != newValue else { return }
                var next = htmlConfig.wrappedValue
                next[keyPath: keyPath] = newValue
                htmlConfig.wrappedValue = next
                screenManager.updateHTMLConfig(next, for: screen)
            }
        )
    }
}

@MainActor
struct HTMLRenderingDiagnostics {
    let measurementText: String
    let pointSizeText: String
    let backingPixelSizeText: String
    let scaleText: String
    let viewportText: String
    let devicePixelRatioText: String
    let modeText: String

    init(screen: Screen, source: HTMLSource?, config: HTMLConfig) {
        let geometry = Self.currentGeometry(for: screen)
        let scaleX = geometry.pointSize.width > 0
            ? geometry.backingPixelSize.width / geometry.pointSize.width
            : screen.nsScreen.backingScaleFactor
        let scaleY = geometry.pointSize.height > 0
            ? geometry.backingPixelSize.height / geometry.pointSize.height
            : screen.nsScreen.backingScaleFactor
        let usesPhysicalPixels = Self.effectivePhysicalPixelLayout(source: source, config: config)
        let viewportSize = usesPhysicalPixels ? geometry.backingPixelSize : geometry.pointSize

        // Localized here rather than at the label: the overlay renders these
        // verbatim because its other cells are raw measurements.
        measurementText = geometry.usesLiveView
            ? String(localized: "Live view", bundle: .appLanguage, comment: "Web rendering diagnostics: what was measured.")
            : String(localized: "Screen frame", bundle: .appLanguage, comment: "Web rendering diagnostics: what was measured.")
        pointSizeText = Self.pointSizeText(geometry.pointSize)
        backingPixelSizeText = Self.pixelSizeText(geometry.backingPixelSize)
        scaleText = Self.scalePairText(x: scaleX, y: scaleY, suffix: true)
        viewportText = Self.cssViewportText(viewportSize)
        devicePixelRatioText = String(
            format: String(localized: "%@ (native)", bundle: .appLanguage, comment: "Web rendering diagnostics: a device pixel ratio that matches the display's own."),
            Self.scalePairText(x: scaleX, y: scaleY, suffix: false)
        )
        modeText = if usesPhysicalPixels {
            if config.physicalPixelLayout {
                String(localized: "Physical pixels", bundle: .appLanguage, comment: "Web rendering diagnostics: canvas sizing mode.")
            } else {
                String(localized: "Physical pixels (auto)", bundle: .appLanguage, comment: "Web rendering diagnostics: canvas sizing mode chosen automatically.")
            }
        } else {
            String(localized: "CSS points", bundle: .appLanguage, comment: "Web rendering diagnostics: canvas sizing mode.")
        }
    }

    private static func currentGeometry(for screen: Screen) -> (
        pointSize: CGSize,
        backingPixelSize: CGSize,
        usesLiveView: Bool
    ) {
        if let contentView = screen.activeWallpaperWindow?.contentView {
            let bounds = contentView.bounds
            if bounds.width > 0, bounds.height > 0 {
                return (bounds.size, contentView.convertToBacking(bounds).size, true)
            }
        }

        let pointSize = screen.frame.size
        let scale = screen.nsScreen.backingScaleFactor
        return (
            pointSize,
            CGSize(width: pointSize.width * scale, height: pointSize.height * scale),
            false
        )
    }

    private static func effectivePhysicalPixelLayout(source: HTMLSource?, config: HTMLConfig) -> Bool {
        guard !config.physicalPixelLayout, let source else {
            return config.physicalPixelLayout
        }
        return HTMLWallpaperCompatibilityPolicy.shouldAutoEnablePhysicalPixelLayout(source)
    }

    private static func pointSizeText(_ size: CGSize) -> String {
        "\(pointLengthText(size.width))×\(pointLengthText(size.height)) pt"
    }

    private static func pixelSizeText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) px"
    }

    private static func cssViewportText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded())) CSS px"
    }

    private static func scalePairText(x: CGFloat, y: CGFloat, suffix: Bool) -> String {
        let xText = scaleValueText(x)
        let text: String
        if abs(x - y) < 0.005 {
            text = xText
        } else {
            text = "\(xText) / \(scaleValueText(y))"
        }
        return suffix ? "\(text)×" : text
    }

    private static func pointLengthText(_ value: CGFloat) -> String {
        if abs(value.rounded() - value) < 0.05 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    private static func scaleValueText(_ value: CGFloat) -> String {
        if abs(value.rounded() - value) < 0.005 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}
