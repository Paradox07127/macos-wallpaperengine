import AppKit
import LiveWallpaperCore
import SwiftUI

/// Drag to move, pinch to scale, twist to rotate; writes land once, on release.
/// Draws the full transform only over an untransformed base — over a live capture,
/// already transformed by the runtime, it draws the gesture delta alone.
/// `.scaleEffect` → `.rotationEffect` → `.offset` mirrors the CSS string's right-to-left
/// composition; reordering makes the preview lie.
struct WebTransformCanvas<Content: View>: View {
    let screen: Screen
    @Binding var config: HTMLConfig
    /// Gestures are attached only while this is on; arming happens in the transform popover.
    let isArmed: Bool
    /// The base image already has the committed transform baked in (a capture of
    /// the running wallpaper), so only the gesture's own delta may be drawn.
    let baseIncludesTransform: Bool
    @ViewBuilder let content: () -> Content

    @Environment(ScreenManager.self) private var screenManager

    @State private var dragTranslation: CGSize = .zero
    @State private var magnification: CGFloat = 1
    @State private var rotationDelta: Angle = .zero
    @State private var isManipulating = false
    @State private var previewSize = CGSize(width: 1, height: 1)
    /// Which recognisers are mid-flight. A set, not a count: `onChanged` fires per sample,
    /// and committing while one still runs compounds its next total onto the value just written.
    private enum GestureKind: Hashable { case drag, magnify, rotate }
    @State private var activeGestures: Set<GestureKind> = []
    @GestureState private var isRecognizing = false
    @State private var gestureInterrupted = false

    /// One preview point is this many CSS pixels on the display.
    /// `min`, not the width ratio: `scaledToFill` crops one axis, so the *other* sets the scale.
    /// `NSScreen.frame` is in points, which is what CSS pixels are — no backing-scale term.
    private var pointsToCSS: Double {
        guard previewSize.width > 1, previewSize.height > 1 else { return 1 }
        return min(
            screen.frame.width / previewSize.width,
            screen.frame.height / previewSize.height
        )
    }

    var body: some View {
        content()
            .scaleEffect(drawnScale, anchor: .center)
            .rotationEffect(.degrees(drawnRotation), anchor: .center)
            .offset(
                x: drawnTranslateX / pointsToCSS,
                y: drawnTranslateY / pointsToCSS
            )
            .clipped()
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { previewSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in previewSize = size }
                }
            }
            .contentShape(Rectangle())
            .gesture(manipulation, isEnabled: isArmed)
            .onChange(of: isArmed) { _, armed in
                if !armed {
                    interruptGesture()
                }
            }
            .onChange(of: screen.id) { _, _ in interruptGesture() }
            .onChange(of: isRecognizing) { _, recognizing in
                if !recognizing {
                    resetGestureState()
                    gestureInterrupted = false
                }
            }
            .onDisappear { interruptGesture() }
            .onTapGesture(count: 2) {
                if isArmed {
                    resetTransform()
                }
            }
            .overlay {
                if isArmed {
                    RoundedRectangle(cornerRadius: DesignTokens.Corner.preview, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isArmed, isManipulating {
                    readout
                }
            }
            .help(isArmed
                ? Text("Drag to move · pinch to scale · twist to rotate · double-click to reset")
                : Text(verbatim: ""))
    }

    // MARK: - Drawn values

    /// What to draw on top of the base image: the whole transform when the base
    /// is untransformed, and only the gesture's own delta when it is not.
    private var drawnScale: Double {
        baseIncludesTransform ? magnification : liveScale
    }

    private var drawnRotation: Double {
        baseIncludesTransform ? rotationDelta.degrees : liveRotation
    }

    private var drawnTranslateX: Double {
        baseIncludesTransform ? dragTranslation.width * pointsToCSS : liveTranslateX
    }

    private var drawnTranslateY: Double {
        baseIncludesTransform ? dragTranslation.height * pointsToCSS : liveTranslateY
    }

    // MARK: - Committed values

    private var liveScale: Double {
        snappedScale(HTMLConfig.clampedTransformScale(config.transformScale * magnification))
    }

    /// `HTMLConfig` normalises rotation into (-360, 360), so 270° is legal; clamping to ±180
    /// here would write that clamp back on the next gesture.
    private var liveRotation: Double {
        snappedRotation(
            HTMLConfig.clampedTransformRotation(config.transformRotationDegrees + rotationDelta.degrees)
        )
    }

    private var liveTranslateX: Double {
        snappedTranslate(HTMLConfig.clampedTransformTranslate(
            config.transformTranslateX + dragTranslation.width * pointsToCSS
        ))
    }

    private var liveTranslateY: Double {
        snappedTranslate(HTMLConfig.clampedTransformTranslate(
            config.transformTranslateY + dragTranslation.height * pointsToCSS
        ))
    }

    // MARK: - Gestures

    /// Composed simultaneously so a trackpad's pinch and twist arrive together;
    /// each keeps its own accumulator, or the second finger landing would jump
    /// the value the first one was carrying.
    private var manipulation: some Gesture {
        drag
            .simultaneously(with: magnify)
            .simultaneously(with: rotate)
            .updating($isRecognizing) { _, recognizing, _ in recognizing = true }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !gestureInterrupted, isArmed else { return }
                beginGesture(.drag)
                // A mouse has neither pinch nor twist.
                let flags = NSEvent.modifierFlags
                if flags.contains(.option) {
                    magnification = max(0.05, 1 - value.translation.height / 200)
                } else if flags.contains(.command) {
                    rotationDelta = .degrees(Double(value.translation.width) / 2)
                } else if flags.contains(.shift) {
                    dragTranslation = abs(value.translation.width) >= abs(value.translation.height)
                        ? CGSize(width: value.translation.width, height: 0)
                        : CGSize(width: 0, height: value.translation.height)
                } else {
                    dragTranslation = value.translation
                }
            }
            .onEnded { _ in endGesture(.drag) }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !gestureInterrupted, isArmed else { return }
                beginGesture(.magnify)
                magnification = value.magnification
            }
            .onEnded { _ in endGesture(.magnify) }
    }

    private var rotate: some Gesture {
        RotateGesture()
            .onChanged { value in
                guard !gestureInterrupted, isArmed else { return }
                beginGesture(.rotate)
                rotationDelta = value.rotation
            }
            .onEnded { _ in endGesture(.rotate) }
    }

    // MARK: - Commit

    private func beginGesture(_ kind: GestureKind) {
        isManipulating = true
        activeGestures.insert(kind)
    }

    private func endGesture(_ kind: GestureKind) {
        guard !gestureInterrupted, isArmed,
              activeGestures.remove(kind) != nil else { return }
        guard activeGestures.isEmpty else { return }
        commit()
    }

    private func interruptGesture() {
        // A display switch can leave the recognizer tracking the same fingers.
        // Discard its remaining samples until it ends or is cancelled.
        gestureInterrupted = isRecognizing
        resetGestureState()
    }

    private func commit() {
        var next = config
        next.transformScale = liveScale
        next.transformRotationDegrees = liveRotation
        next.transformTranslateX = liveTranslateX
        next.transformTranslateY = liveTranslateY
        resetGestureState()
        guard next != config else { return }
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }

    private func resetTransform() {
        resetGestureState()
        var next = config
        next.transformScale = 1
        next.transformRotationDegrees = 0
        next.transformTranslateX = 0
        next.transformTranslateY = 0
        guard next != config else { return }
        config = next
        screenManager.updateHTMLConfig(next, for: screen)
    }

    private func resetGestureState() {
        dragTranslation = .zero
        magnification = 1
        rotationDelta = .zero
        isManipulating = false
        activeGestures = []
    }

    // MARK: - Snapping

    private var snapsEnabled: Bool {
        !NSEvent.modifierFlags.contains(.command)
    }

    private func snappedScale(_ value: Double) -> Double {
        guard snapsEnabled, abs(value - 1) < 0.03 else { return value }
        return 1
    }

    /// Quarter turns in both directions, since the persisted range is (-360, 360).
    private func snappedRotation(_ value: Double) -> Double {
        guard snapsEnabled else { return value }
        for target in stride(from: -270.0, through: 270.0, by: 90) where abs(value - target) < 2.5 {
            return target
        }
        return value
    }

    /// In CSS pixels, so the deadband scales with the display rather than being a
    /// fixed number of preview points on every screen.
    private func snappedTranslate(_ value: Double) -> Double {
        guard snapsEnabled, abs(value) < 6 * pointsToCSS else { return value }
        return 0
    }

    // MARK: - Readout

    private var readout: some View {
        Text(verbatim: String(
            format: "%.0f%%  %.0f°  %.0f, %.0f",
            liveScale * 100,
            liveRotation,
            liveTranslateX,
            liveTranslateY
        ))
        .font(DesignTokens.Typography.metric)
        .foregroundStyle(DesignTokens.Colors.overlayForeground)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, 4)
        .adaptiveGlassOverMedia(.capsule)
        .padding(DesignTokens.Spacing.md)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
