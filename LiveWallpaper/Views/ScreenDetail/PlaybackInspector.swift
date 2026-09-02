import SwiftUI
import AppKit
import LiveWallpaperCore

/// Playback controls as a row of glyphs on the preview's own overlay.
///
/// These were a form of labelled rows, first in the inspector column and then in
/// a shelf under the preview. Both readings were wrong about what they are: every
/// one of them acts on the wallpaper *this display is playing right now*, which is
/// the thing the preview shows — so they belong on the preview, the way a media
/// player puts its transport under the picture.
///
/// Two of them do not follow that rule and left:
/// * span-all-displays moved to the inspector's Display group — its effect is on a
///   different screen, so the preview can never show it;
/// * scale moved to each type's own overlay bar earlier, next to the title.
///
/// The bindings below are unchanged from the form version, deliberately: the audio
/// dead zone, the coalesced volume write, and the click-capture confirmation are
/// the parts with teeth, and re-typing them for a new layout is how they get lost.
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

    /// First enable confirms; later toggles are silent.
    @AppStorage("Scene.ClickCapture.Acknowledged") private var clickCaptureAcknowledged = false
    @State private var showClickCaptureConfirm = false
    /// HTML-only: mute path for WKWebView media (`AVPlayer.muted` is a no-op here).
    var htmlConfig: Binding<HTMLConfig>?
    /// `.forceSDR` owns `videoComposition`, so the frame-rate cap is dimmed/ignored.
    var videoColorSpace: VideoColorSpace = .auto
    var showsResetPlayback: Bool = false
    var onResetPlayback: () -> Void = {}

    @State private var showingVolume = false
    @State private var lockScreenExtracted = false
    /// Drop stale "clear ✓" Tasks when a newer toggle wins (same pattern as schedule conflict flash).
    @State private var lockScreenFeedbackGeneration = 0

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            audioControl
            ForEach(visibleRows, id: \.self) { kind in
                control(kind)
            }
            if showsResetPlayback {
                resetPlaybackAccessory
            }
        }
        .buttonStyle(.borderless)
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

    // MARK: - Row layout

    /// Which rows this wallpaper type shows, in order. Held as data rather than
    /// a chain of `if`s inside the stack so the shelf can balance them across
    /// columns — 1 row for web up to 5 for scene, and stacking all five in the
    /// wide shelf forced it to scroll.
    private enum PlaybackRow: Hashable {
        case frameRate, mouseInteraction, clickInteraction, syncToLockScreen
    }

    /// Audio is rendered ahead of this list because every type has it.
    private var visibleRows: [PlaybackRow] {
        var rows: [PlaybackRow] = []
        if showsFrameRateRow {
            rows.append(.frameRate)
        }
        if showsMouseInteractionRow {
            rows.append(contentsOf: [.mouseInteraction, .clickInteraction])
        }
        if showsSyncToLockScreenRow {
            rows.append(.syncToLockScreen)
        }
        return rows
    }

    /// Audio is always first and always present: every wallpaper type can make
    /// sound, and the speaker is the one glyph in this row nobody has to learn.
    private var audioControl: some View {
        let isMuted = audioMutedBinding.wrappedValue
        return Button {
            showingVolume = true
        } label: {
            Image(systemName: isMuted ? "speaker.slash" : "speaker.wave.2")
                .foregroundStyle(isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.primary))
        }
        .help(Text("Audio"))
        .accessibilityLabel(Text("Audio"))
        .accessibilityValue(audioAccessibilityValue(
            isMuted: isMuted,
            percent: Self.audioPercent(atSliderValue: unifiedAudioBinding.wrappedValue)
        ))
        .popover(isPresented: $showingVolume, arrowEdge: .bottom) {
            volumePopover
        }
    }

    /// The slider lives behind the speaker rather than beside it: a continuous
    /// control in a glyph row is the one thing that cannot shrink to an icon, and
    /// stretched across the overlay it would crowd out everything else.
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
        case .frameRate:
            frameRateControl
        case .mouseInteraction:
            glyphToggle(
                on: "cursorarrow.rays",
                isOn: sceneMouseInteractionEnabled,
                binding: mouseInteractionBinding,
                label: Text("Follow cursor"),
                help: Text("Camera parallax and pointer-driven effects follow your cursor. Passive — safe for desktop icon clicks.")
            )
        case .clickInteraction:
            glyphToggle(
                on: "cursorarrow.click",
                isOn: sceneClickCaptureEnabled,
                binding: clickInteractionBinding,
                label: Text("Interaction"),
                help: Text("Lets the scene receive real clicks. While on, clicks go to the wallpaper instead of the desktop on this display.")
            )
        case .syncToLockScreen:
            lockScreenControl
        }
    }

    /// Carries its value in the label — a frame-rate cap is a number, and an icon
    /// alone cannot say which one is in force.
    private var frameRateControl: some View {
        let forceSDRActive = videoColorSpace == .forceSDR
        return Menu {
            Picker("", selection: frameRateBinding) {
                ForEach(FrameRateLimit.allCases) { limit in
                    Text(limit.titleKey).tag(limit)
                }
            }
            .labelsHidden()
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                Text(frameRateLimit.titleKey)
                    .font(DesignTokens.Typography.caption)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(forceSDRActive)
        .help(forceSDRActive
            ? Text("Disabled while Force SDR is active")
            : Text("Caps below 30 FPS force a compositing pass — useful when effects are active or to extend battery."))
        .accessibilityLabel(Text("Frame rate limit"))
        .accessibilityValue(forceSDRActive
            ? Text("Disabled — Force SDR is active", comment: "Accessibility value when the frame-rate picker is dimmed because Force SDR owns the video composition slot.")
            : Text(frameRateLimit.titleKey))
    }

    private var lockScreenControl: some View {
        glyphToggle(
            on: "photo.on.rectangle",
            isOn: syncToLockScreen,
            binding: syncToLockScreenBinding,
            label: Text("Capture this video's frame when locking"),
            help: Text("Captures this video's current frame at lock and sets it as the macOS desktop picture."),
            badge: lockScreenExtracted
        )
    }

    /// One shape for every on/off control here: tinted when on, secondary when
    /// off, with the sentence that used to be the row's `info` as its tooltip.
    private func glyphToggle(
        on symbol: String,
        isOn: Bool,
        binding: Binding<Bool>,
        label: Text,
        help: Text,
        badge: Bool = false
    ) -> some View {
        Button {
            binding.wrappedValue.toggle()
        } label: {
            Image(systemName: symbol)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(DesignTokens.Colors.Status.active)
                            .offset(x: 4, y: -4)
                            .accessibilityHidden(true)
                    }
                }
        }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }

    /// Mute dead zone on the volume slider (avoids leaking 1–2% from a stray drag).
    private static let audioDeadZone: Double = 0.04

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

    private var showsFrameRateRow: Bool {
        switch wallpaperType {
        case .video, .scene: true
        case .html: false
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
                    showClickCaptureConfirm = true
                    return
                }
                setClickCapture(newValue)
            }
        )
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

    /// The track is not a plain 0…1 volume: the bottom `audioDeadZone` is the mute region, the
    /// rest remapped onto volume. The readout follows the drag from the slider's own state, so
    /// it must undo the same mapping `unifiedAudioBinding.set` applies — reading it as a raw percentage showed the wrong number and muted at the wrong point.
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
