import AppKit
import LiveWallpaperCore
import SwiftUI

/// Direct manipulation of a web wallpaper's layout transform, on the preview
/// itself: drag to move, pinch to scale, twist to rotate.
///
/// Three facts shaped this, all checked rather than assumed:
///
/// * The preview is a static `NSImage` snapshot, so a gesture layer over it
///   cannot fight the page's own interactivity — and a snapshot costs a full
///   offscreen web render, so it must never be taken mid-gesture. The live
///   feedback is this view transforming the image it already has.
/// * There are TWO snapshot paths and they differ. The offscreen one
///   (`PendingHTMLSnapshot`) never injects the transform script, so its image is
///   the untransformed page. But while the wallpaper is *playing*,
///   `HTMLPreviewSection` prefers a capture of the running WebView, which the
///   runtime has already transformed. Drawing the committed transform on that
///   image squares it — a 2× wallpaper previewed at 4×. So this view draws the
///   full transform only over an untransformed base, and over a live capture it
///   draws the in-flight gesture delta alone.
/// * The wallpaper's own transform is a CSS string —
///   `translate(TXpx,TYpx) rotate(Rdeg) scale(S)` with `transform-origin:50% 50%`
///   (`HTMLWallpaperRuntimeScript`). CSS composes right-to-left, so scale happens
///   first. SwiftUI modifiers wrap outward, so `.scaleEffect` → `.rotationEffect`
///   → `.offset` is the same composition. Reordering these makes the preview lie.
///
/// Writes land once, on release. The sliders in the transform popover stay: they
/// are the keyboard and VoiceOver path, and the place to type an exact number.
struct WebTransformCanvas<Content: View>: View {
    let screen: Screen
    @Binding var config: HTMLConfig
    /// Gestures are attached only while this is on. The preview occupies most of
    /// the page, so an always-live drag layer means the first stray swipe throws
    /// the wallpaper off-centre; arming it is a deliberate act, from the transform
    /// popover.
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
    /// Which recognisers are mid-flight. Committing on the first `onEnded` while
    /// a second is still running clears the accumulators under it, and its next
    /// update — which reports a total, not a delta — then compounds onto the
    /// value just written. A set, not a count: `onChanged` fires per sample.
    private enum GestureKind: Hashable { case drag, magnify, rotate }
    @State private var activeGestures: Set<GestureKind> = []

    /// One preview point is this many CSS pixels on the display.
    ///
    /// `min`, not the width ratio: the preview fills a 16:9 box with
    /// `scaledToFill`, so on a display of any other aspect the picture is cropped
    /// on one axis and the *other* axis sets the scale. Taking width alone made a
    /// 21:9 display's drags travel about a third further than the preview showed.
    ///
    /// `NSScreen.frame` is in points, which is what CSS pixels are, so there is no
    /// backing-scale term.
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
            .onTapGesture(count: 2) {
                if isArmed {
                    resetTransform()
                }
            }
            .overlay {
                if isArmed {
                    // Says the canvas is live without adding a control to it.
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

    /// `HTMLConfig` normalises rotation into (-360, 360), so 270° is a legal
    /// persisted value. Clamping to ±180 here showed it as 180 and then wrote
    /// that back permanently on the next gesture.
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
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                beginGesture(.drag)
                // Option turns the drag into a scale and Command into a rotation,
                // because a mouse has neither pinch nor twist.
                let flags = NSEvent.modifierFlags
                if flags.contains(.option) {
                    magnification = max(0.05, 1 - value.translation.height / 200)
                } else if flags.contains(.command) {
                    rotationDelta = .degrees(Double(value.translation.width) / 2)
                } else if flags.contains(.shift) {
                    // Axis lock: whichever axis has travelled further wins.
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
                beginGesture(.magnify)
                magnification = value.magnification
            }
            .onEnded { _ in endGesture(.magnify) }
    }

    private var rotate: some Gesture {
        RotateGesture()
            .onChanged { value in
                beginGesture(.rotate)
                rotationDelta = value.rotation
            }
            .onEnded { _ in endGesture(.rotate) }
    }

    // MARK: - Commit

    /// Each recogniser reports a total measured from its own start, so the shared
    /// accumulators may only be cleared once every one of them has finished.
    private func beginGesture(_ kind: GestureKind) {
        isManipulating = true
        activeGestures.insert(kind)
    }

    private func endGesture(_ kind: GestureKind) {
        activeGestures.remove(kind)
        guard activeGestures.isEmpty else { return }
        commit()
    }

    /// The one write. Everything above this line is local state driving a
    /// `scaleEffect`/`offset`, which is why a drag does not reach the running
    /// wallpaper on every sample.
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

    /// Command suppresses every snap, for the case where the value the user wants
    /// is just off one of them.
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

    /// Only while a gesture is running: 100% and 103% look the same, and a
    /// permanent readout would be one more thing floating over the wallpaper.
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
