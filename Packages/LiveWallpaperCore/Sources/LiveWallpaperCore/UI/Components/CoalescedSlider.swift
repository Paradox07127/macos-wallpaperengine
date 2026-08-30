import SwiftUI

/// How wide the track is. Two shapes cover every inspector row today.
public enum CoalescedSliderSizing {
    case fixed(CGFloat)
    case flexible(minimum: CGFloat, maximum: CGFloat)
}

/// A slider whose gesture samples stay inside the row. Every inspector slider used to write straight
/// through on each sample, and on the other side of those bindings sit things that are not free once
/// per frame: persisting settings to disk, rebuilding a `CIFilter` chain, rebuilding an overlay, or
/// reaching the render session. The knob now tracks the pointer from row-local state, and the value
/// leaves the row on a quiet window and again when the gesture ends. The WPE scene custom-settings
/// card keeps its own plain `Slider` instead of this one: it stages into an editor that merges a
/// preset layer underneath the user's increment — a different commit protocol, not a different slider.
public struct CoalescedSlider<Readout: View>: View {
    private let committedValue: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let owner: AnyHashable
    private let quietWindow: Duration
    private let sizing: CoalescedSliderSizing
    private let accessibilityLabel: Text
    private let accessibilityValue: (Double) -> Text
    private let write: (Double) -> Void
    private let readout: (Double) -> Readout

    /// - Parameters:
    ///   - owner: what the value belongs to — typically the display, plus the wallpaper. A row keeps
    ///     its `@State` when the surrounding list re-uses it for a different subject, so without
    ///     this a drag started on one display can commit onto another.
    ///   - quietWindow: matches the WPE inspector's 180 ms, the interval already proven to keep a
    ///     live preview tracking a drag.
    public init(
        value: Double,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        owner: AnyHashable,
        quietWindow: Duration = .milliseconds(180),
        sizing: CoalescedSliderSizing = .fixed(DesignTokens.Inspector.sliderWidth),
        accessibilityLabel: Text,
        accessibilityValue: @escaping (Double) -> Text,
        write: @escaping (Double) -> Void,
        @ViewBuilder readout: @escaping (Double) -> Readout
    ) {
        self.committedValue = value
        self.range = range
        self.step = step
        self.owner = owner
        self.quietWindow = quietWindow
        self.sizing = sizing
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.write = write
        self.readout = readout
    }

    @State private var draggingValue: Double?
    @State private var commitTask: Task<Void, Never>?
    /// What the quiet window last sent. Releasing the mouse after the window has
    /// already fired would otherwise write the same value a second time, and not
    /// every destination filters equal writes — the particle overlay rebuilt
    /// itself twice for one gesture.
    @State private var lastWrittenValue: Double?

    private var value: Double { draggingValue ?? committedValue }

    public var body: some View {
        HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
            slider
                .controlSize(.small)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue(value))
                .modifier(SliderSizing(sizing: sizing))

            readout(value)
        }
        .onChange(of: owner) { _, _ in
            // The row now belongs to something else; a pending commit was
            // computed against the subject it no longer points at.
            cancelPendingCommit()
            draggingValue = nil
            lastWrittenValue = nil
        }
        .onDisappear { cancelPendingCommit() }
    }

    @ViewBuilder
    private var slider: some View {
        if let step {
            Slider(value: binding, in: range, step: step, onEditingChanged: editingChanged)
        } else {
            Slider(value: binding, in: range, onEditingChanged: editingChanged)
        }
    }

    private var binding: Binding<Double> {
        Binding(
            get: { value },
            set: { next in
                draggingValue = next
                scheduleCommit(next)
            }
        )
    }

    private func editingChanged(_ editing: Bool) {
        guard !editing else { return }
        let final = draggingValue ?? committedValue
        draggingValue = nil
        cancelPendingCommit()
        guard final != lastWrittenValue else {
            lastWrittenValue = nil
            return
        }
        lastWrittenValue = nil
        write(final)
    }

    private func scheduleCommit(_ next: Double) {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: quietWindow)
            guard !Task.isCancelled else { return }
            commitTask = nil
            lastWrittenValue = next
            write(next)
        }
    }

    private func cancelPendingCommit() {
        commitTask?.cancel()
        commitTask = nil
    }
}

private struct SliderSizing: ViewModifier {
    let sizing: CoalescedSliderSizing

    func body(content: Content) -> some View {
        switch sizing {
        case .fixed(let width):
            content.frame(width: width)
        case .flexible(let minimum, let maximum):
            content.frame(minWidth: minimum, maxWidth: maximum)
        }
    }
}
