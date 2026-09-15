import SwiftUI

/// Values snap to this grid without creating a view for each possible stop.
public struct SliderValueGrid {
    public let range: ClosedRange<Double>
    public let step: Double

    public init(in range: ClosedRange<Double>, step: Double) {
        self.range = range
        self.step = step
    }

    public func normalized(_ value: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step.isFinite, step > 0 else { return clamped }
        let snapped = ((clamped - range.lowerBound) / step).rounded() * step + range.lowerBound
        return min(max(snapped, range.lowerBound), range.upperBound)
    }
}

/// A continuous track whose writes snap to the authored value grid.
public struct QuantizedSlider: View {
    @Binding private var value: Double
    private let grid: SliderValueGrid
    private let onEditingChanged: (Bool) -> Void

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _value = value
        grid = SliderValueGrid(in: range, step: step)
        self.onEditingChanged = onEditingChanged
    }

    public var body: some View {
        Slider(value: normalizedBinding, in: grid.range, onEditingChanged: onEditingChanged)
    }

    private var normalizedBinding: Binding<Double> {
        Binding(get: { value }, set: { next in
            let normalized = grid.normalized(next)
            if value != normalized {
                value = normalized
            }
        })
    }
}

public enum CoalescedSliderSizing {
    case fixed(CGFloat)
    case flexible(minimum: CGFloat, maximum: CGFloat)
}

public struct CoalescedSlider<Readout: View>: View {
    private let committedValue: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let quantizationStep: Double?
    private let owner: AnyHashable
    private let quietWindow: Duration
    private let controlSize: ControlSize
    private let sizing: CoalescedSliderSizing
    private let accessibilityLabel: Text
    private let accessibilityValue: (Double) -> Text
    private let write: (Double) -> Void
    private let readout: (Double) -> Readout

    /// - Parameters:
    ///   - quantizationStep: snaps writes on a continuous track; takes precedence over display `step`.
    ///   - owner: what the value belongs to (display, plus the wallpaper). A reused row
    ///     keeps its `@State`, so without this a drag can commit onto another subject.
    public init(
        value: Double,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        quantizationStep: Double? = nil,
        owner: AnyHashable,
        quietWindow: Duration = .milliseconds(180),
        controlSize: ControlSize = .small,
        sizing: CoalescedSliderSizing = .fixed(DesignTokens.Inspector.sliderWidth),
        accessibilityLabel: Text,
        accessibilityValue: @escaping (Double) -> Text,
        write: @escaping (Double) -> Void,
        @ViewBuilder readout: @escaping (Double) -> Readout
    ) {
        self.committedValue = value
        self.range = range
        self.step = step
        self.quantizationStep = quantizationStep
        self.owner = owner
        self.quietWindow = quietWindow
        self.controlSize = controlSize
        self.sizing = sizing
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
        self.write = write
        self.readout = readout
    }

    @State private var draggingValue: Double?
    @State private var commitTask: Task<Void, Never>?
    /// What the quiet window last sent: releasing after it has fired would write the
    /// same value twice, and not every destination filters equal writes.
    @State private var lastWrittenValue: Double?

    private var value: Double { draggingValue ?? committedValue }

    public var body: some View {
        HStack(spacing: DesignTokens.Inspector.sliderValueSpacing) {
            slider
                .controlSize(controlSize)
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
        if let quantizationStep {
            QuantizedSlider(value: binding, in: range, step: quantizationStep, onEditingChanged: editingChanged)
        } else if let step {
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
