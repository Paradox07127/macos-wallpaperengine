import SwiftUI
import AppKit
import LiveWallpaperCore

/// Playback controls kept positionally stable across wallpaper types.
struct PlaybackInspector: View {
    var screen: Screen
    var wallpaperType: WallpaperType

    @Environment(ScreenManager.self) private var screenManager
    @Environment(\.featureCatalog) private var featureCatalog
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var muted: Bool
    @Binding var videoVolume: Double
    @Binding var videoDisplayMode: VideoDisplayMode
    @Binding var frameRateLimit: FrameRateLimit
    @Binding var syncToLockScreen: Bool
    @Binding var sceneMouseInteractionEnabled: Bool
    /// Real pointer input; steals desktop clicks while on.
    @Binding var sceneClickCaptureEnabled: Bool
    /// Draft `fitMode`; applies via `ScreenManager.updateSceneFitMode`.
    @Binding var sceneFitMode: VideoFitMode

    /// First enable confirms; later toggles are silent.
    @AppStorage("Scene.ClickCapture.Acknowledged") private var clickCaptureAcknowledged = false
    @State private var showClickCaptureConfirm = false
    /// HTML-only: mute path for WKWebView media (`AVPlayer.muted` is a no-op here).
    var htmlConfig: Binding<HTMLConfig>?
    /// `.forceSDR` owns `videoComposition`, so the frame-rate cap is dimmed/ignored.
    var videoColorSpace: VideoColorSpace = .auto
    var showsResetPlayback: Bool = false
    var onResetPlayback: () -> Void = {}

    @AppStorage("Inspector.PlaybackExpanded") private var isPlaybackExpanded = true
    @State private var lockScreenExtracted = false
    /// Drop stale "clear ✓" Tasks when a newer toggle wins (same pattern as schedule conflict flash).
    @State private var lockScreenFeedbackGeneration = 0

    var body: some View {
        GroupBox {
            CollapsibleSection(
                title: "Playback",
                systemImage: "play.circle",
                isExpanded: $isPlaybackExpanded,
                trailingAccessory: { resetPlaybackAccessory }
            ) {
                VStack(spacing: 8) {
                    audioRow
                    if showsFrameRateRow {
                        Divider()
                        frameRateRow
                    }
                    if showsVideoDisplayModeRow {
                        Divider()
                        videoDisplayModeRow
                    }
                    if showsFitModeRow {
                        Divider()
                        fitModeRow
                    }
                    if showsMouseInteractionRow {
                        Divider()
                        mouseInteractionRow
                        Divider()
                        clickInteractionRow
                    }
                    if showsSyncToLockScreenRow {
                        Divider()
                        syncToLockScreenRow
                    }
                }
            }
        }
        .groupBoxStyle(ContainerGroupBoxStyle())
        .alert("Enable Wallpaper Interaction?", isPresented: $showClickCaptureConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Enable") {
                clickCaptureAcknowledged = true
                setClickCapture(true)
            }
        } message: {
            Text("This lets you click elements inside the scene, but while it's on you can't click desktop icons or right-click the desktop on this display. Turn it off here to restore desktop clicks.")
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

    // MARK: - Row availability

    private var showsFrameRateRow: Bool {
        switch wallpaperType {
        case .video, .scene: return true
        case .html: return false
        }
    }

    /// Always shown for video so a persisted `.spanAllDisplays` isn't hidden when a second display unplugs (row disables instead).
    private var showsVideoDisplayModeRow: Bool {
        wallpaperType == .video
    }

    private var hasMultipleDisplays: Bool {
        screenManager.screens.count > 1
    }

    private var showsMouseInteractionRow: Bool {
        wallpaperType == .scene
    }

    private var showsFitModeRow: Bool {
        wallpaperType == .scene
    }

    private var showsSyncToLockScreenRow: Bool {
        wallpaperType == .video && featureCatalog.isEnabled(.lockScreenSnapshots)
    }

    // MARK: - Rows

    /// Mute dead zone on the volume slider (avoids leaking 1–2% from a stray drag).
    private static let audioDeadZone: Double = 0.04

    private var audioRow: some View {
        // The readout follows the drag; this icon follows the committed value, so
        // mid-drag it can lag the word next to it by up to one quiet window.
        // Deliberate: the icon is a parameter of `SettingRow`, so making it live
        // means re-rendering this row on every gesture sample — which is the
        // cost the coalescing exists to remove, spent to fix a transient
        // cosmetic mismatch.
        let isMuted = audioMutedBinding.wrappedValue
        return SettingRow(
            icon: isMuted ? "speaker.slash" : "speaker.wave.2",
            iconColor: isMuted ? .secondary : .blue,
            title: "Audio"
        ) {
            // Coalesced: the binding writes the draft and, for HTML wallpapers,
            // reaches the live session on every sample.
            CoalescedSlider(
                value: unifiedAudioBinding.wrappedValue,
                in: 0...1,
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
        }
    }

    @ViewBuilder
    private func audioLevelLabel(isMuted: Bool, percent: Int) -> some View {
        if isMuted {
            Text("Muted", comment: "Audio level display when the wallpaper is muted")
        } else {
            Text(verbatim: "\(percent)%")
        }
    }

    private func audioAccessibilityValue(isMuted: Bool, percent: Int) -> Text {
        if isMuted {
            return Text("Muted", comment: "Audio level display when the wallpaper is muted")
        }
        return Text("\(percent) percent", comment: "Audio level accessibility value, e.g. \"35 percent\".")
    }

    private var frameRateRow: some View {
        let forceSDRActive = videoColorSpace == .forceSDR
        return SettingRow(
            icon: "gauge.with.dots.needle.bottom.50percent",
            iconColor: forceSDRActive ? .secondary : .blue,
            title: "Frame Rate",
            subtitle: forceSDRActive ? "Disabled while Force SDR is active" : nil,
            info: "Caps below 30 FPS force a compositing pass — useful when effects are active or to extend battery on long sessions. 60 FPS and Unlimited use the native playback path."
        ) {
            Picker("", selection: frameRateBinding) {
                ForEach(FrameRateLimit.allCases) { limit in
                    Text(limit.titleKey).tag(limit)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(forceSDRActive)
            .accessibilityLabel(Text("Frame rate limit"))
            .accessibilityValue(forceSDRActive
                ? Text("Disabled — Force SDR is active", comment: "Accessibility value when the frame-rate picker is dimmed because Force SDR owns the video composition slot.")
                : Text(frameRateLimit.titleKey))
        }
    }

    private var fitModeRow: some View {
        SettingRow(
            icon: "aspectratio",
            iconColor: .blue,
            title: "Scaling",
            info: "How the scene maps onto the display. Fill crops to cover, Fit adds letterbox bars, Center keeps the render at original size, Stretch distorts to fill."
        ) {
            Picker("", selection: fitModeBinding) {
                ForEach(VideoFitMode.sceneModes) { mode in
                    Text(mode.titleKey).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Text("Scaling"))
            .accessibilityValue(Text(sceneFitMode.titleKey))
        }
    }

    private var fitModeBinding: Binding<VideoFitMode> {
        Binding(
            get: { sceneFitMode },
            set: { newValue in
                guard sceneFitMode != newValue else { return }
                sceneFitMode = newValue
                screenManager.updateSceneFitMode(newValue, for: screen)
            }
        )
    }

    private var videoDisplayModeRow: some View {
        SettingRow(
            icon: "rectangle.split.2x1",
            iconColor: videoDisplayMode == .spanAllDisplays ? .blue : .secondary,
            title: "Span Displays",
            subtitle: hasMultipleDisplays ? nil : "Connect another display to enable",
            info: "When on, all connected displays render one stretched video. When off, each display plays its own copy independently — multi-display sync is not possible."
        ) {
            Toggle("", isOn: spanDisplaysBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!hasMultipleDisplays)
                .accessibilityLabel(Text("Span across displays"))
                .accessibilityHint(hasMultipleDisplays
                    ? Text("")
                    : Text("Disabled — connect another display to enable"))
        }
    }

    private var spanDisplaysBinding: Binding<Bool> {
        Binding(
            get: { videoDisplayMode == .spanAllDisplays },
            set: { newValue in
                let target: VideoDisplayMode = newValue ? .spanAllDisplays : .perDisplay
                guard videoDisplayMode != target else { return }
                videoDisplayMode = target
                screenManager.updateVideoDisplayMode(target, for: screen)
            }
        )
    }

    private var mouseInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.rays",
            iconColor: sceneMouseInteractionEnabled ? .blue : .secondary,
            title: "Follow Cursor",
            info: "Camera parallax and pointer-driven effects follow your cursor. Passive — safe for desktop icon clicks. Turn off to keep the scene perfectly still regardless of where the cursor is."
        ) {
            Toggle("", isOn: mouseInteractionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Follow cursor"))
                .accessibilityHint(Text("When off, the scene stops following the cursor"))
        }
    }

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

    private var clickInteractionRow: some View {
        SettingRow(
            icon: "cursorarrow.click",
            iconColor: sceneClickCaptureEnabled ? .blue : .secondary,
            title: "Interaction",
            info: "Lets the scene receive real clicks and drags (for interactive scenes). While on, clicks go to the wallpaper instead of the desktop on this display — you won't be able to click desktop icons until you turn it back off."
        ) {
            Toggle("", isOn: clickInteractionBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(Text("Interaction"))
                .accessibilityHint(Text("When on, the scene captures mouse clicks and the desktop can't be clicked on this display"))
        }
    }

    private var clickInteractionBinding: Binding<Bool> {
        Binding(
            get: { sceneClickCaptureEnabled },
            set: { newValue in
                guard sceneClickCaptureEnabled != newValue else { return }
                if newValue, !clickCaptureAcknowledged {
                    showClickCaptureConfirm = true
                    return
                }
                setClickCapture(newValue)
            }
        )
    }

    private func setClickCapture(_ enabled: Bool) {
        guard sceneClickCaptureEnabled != enabled else { return }
        sceneClickCaptureEnabled = enabled
        screenManager.updateSceneClickCapture(enabled, for: screen)
    }

    private var syncToLockScreenRow: some View {
        SettingRow(
            icon: "photo.on.rectangle",
            iconColor: .blue,
            title: "Capture on Lock",
            info: "When the global lock-capture setting is on, captures this video's current frame at lock and sets it as the macOS desktop picture. It does not restore a wallpaper after unlock, and the desktop picture remains changed."
        ) {
            HStack(spacing: 6) {
                if lockScreenExtracted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DesignTokens.Colors.Status.active)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
                Toggle("", isOn: syncToLockScreenBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Capture this video's frame when locking"))
            }
        }
    }

    // MARK: - Bindings

    /// Video → `AVPlayer.muted`; HTML → `HTMLConfig.muteAudio`.
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

    /// The track is not a plain 0…1 volume: the bottom `audioDeadZone` of it is
    /// the mute region, and the rest is remapped onto the volume. The readout
    /// follows the drag from the slider's own state, so it has to undo the same
    /// mapping `unifiedAudioBinding.set` applies — reading it as a raw
    /// percentage showed the wrong number and muted at the wrong point.
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

    private var videoVolumePercent: Int {
        Int((Self.clampedVolume(currentVolume) * 100).rounded())
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
                guard screenManager.extractLockScreenFrame(for: screen) else { return }
                lockScreenFeedbackGeneration += 1
                let generation = lockScreenFeedbackGeneration
                withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                    lockScreenExtracted = true
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard generation == lockScreenFeedbackGeneration else { return }
                    withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.25))) {
                        lockScreenExtracted = false
                    }
                }
            }
        )
    }

    /// Parent binding + `ScreenManager.updateHTMLConfig` in one place.
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

        measurementText = geometry.usesLiveView ? "Live view" : "Screen frame"
        pointSizeText = Self.pointSizeText(geometry.pointSize)
        backingPixelSizeText = Self.pixelSizeText(geometry.backingPixelSize)
        scaleText = Self.scalePairText(x: scaleX, y: scaleY, suffix: true)
        viewportText = Self.cssViewportText(viewportSize)
        devicePixelRatioText = "\(Self.scalePairText(x: scaleX, y: scaleY, suffix: false)) (native)"
        modeText = if usesPhysicalPixels {
            config.physicalPixelLayout ? "Physical pixels" : "Physical pixels (auto)"
        } else {
            "CSS points"
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
