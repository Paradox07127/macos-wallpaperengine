import SwiftUI

/// Spreads the useful low-rate presets out while leaving every integer selectable.
public struct FrameRateSliderScale {
    public let anchors: [Int]
    public let upperBound: Int
    public var presets: [FrameRateLimit] {
        FrameRateLimit.availableCases(forRefreshRate: Double(upperBound))
    }

    public var maximumPosition: Double {
        Double(anchors.count)
    }

    public init(displayFramesPerSecond: Int) {
        let upper = max(1, displayFramesPerSecond)
        upperBound = upper
        anchors = Array(Set([1, 15, 24, 30, 45, 60, 120, upper].filter { $0 <= upper })).sorted()
    }

    public func position(for value: FrameRateLimit) -> Double {
        guard value != .matchDisplay else { return maximumPosition }
        for index in 1 ..< anchors.count where value.rawValue <= anchors[index] {
            return Double(index - 1) + Double(value.rawValue - anchors[index - 1])
                / Double(anchors[index] - anchors[index - 1])
        }
        return Double(anchors.count - 1)
    }

    public func value(at position: Double, snapping: Bool = true) -> FrameRateLimit {
        guard position.isFinite else { return .matchDisplay }
        let position = min(max(0, position), maximumPosition)
        if position >= maximumPosition - 0.5 {
            return .matchDisplay
        }
        if snapping {
            for preset in presets where preset != .matchDisplay {
                if abs(position - self.position(for: preset)) <= 0.12 {
                    return preset
                }
            }
        }
        guard anchors.count > 1 else { return FrameRateLimit(rawValue: upperBound) ?? .matchDisplay }
        let index = min(Int(position), anchors.count - 2)
        let fraction = min(1, position - Double(index))
        let fps = Double(anchors[index]) + fraction * Double(anchors[index + 1] - anchors[index])
        return FrameRateLimit(rawValue: Int(fps.rounded())) ?? .matchDisplay
    }
}

/// The text field's decisions, kept pure so the view stays a thin shell.
enum FrameRateTextEntry {
    enum BlurOutcome: Equatable {
        case unchanged
        case invalid
        case commit(FrameRateLimit)
    }

    /// What the field shows for `value` on this display: the saved target clamped to the panel.
    static func text(for value: FrameRateLimit, upperBound: Int) -> String {
        value == .matchDisplay ? value.title : String(min(value.rawValue, upperBound))
    }

    static func parse(_ text: String, upperBound: Int) -> FrameRateLimit? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare("max") == .orderedSame
            || text.caseInsensitiveCompare(FrameRateLimit.matchDisplay.title) == .orderedSame {
            return .matchDisplay
        }
        guard let fps = Int(text), (1 ... upperBound).contains(fps) else { return nil }
        return FrameRateLimit(rawValue: fps)
    }

    /// Losing focus commits only an edit: the field shows a saved 120 as "60" on a 60 Hz
    /// display, and writing that back would clamp the target for every other display too.
    static func blurCommit(text: String, value: FrameRateLimit, upperBound: Int) -> BlurOutcome {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines)
            != self.text(for: value, upperBound: upperBound) else { return .unchanged }
        return parse(text, upperBound: upperBound).map { .commit($0) } ?? .invalid
    }
}

/// Shared by per-display playback and display defaults. A drag edits local state;
/// release, a preset click, or a submitted text value commits through the binding.
public struct FrameRateControl: View {
    @Binding private var value: FrameRateLimit
    private let displayFramesPerSecond: Int
    private let accessibilityLabel: Text
    @State private var draggingPosition: Double?
    @State private var isDragging = false
    /// Samples that arrive outside an editing bracket (scroll wheel, a track click) commit once they settle, like `CoalescedSlider`.
    @State private var pendingCommit: Task<Void, Never>?
    @State private var input = ""
    @State private var invalidInput = false
    @FocusState private var inputFocused: Bool

    public init(
        value: Binding<FrameRateLimit>,
        displayFramesPerSecond: Int,
        accessibilityLabel: Text = Text("Frame rate limit")
    ) {
        _value = value
        self.displayFramesPerSecond = displayFramesPerSecond
        self.accessibilityLabel = accessibilityLabel
    }

    private var scale: FrameRateSliderScale {
        FrameRateSliderScale(displayFramesPerSecond: displayFramesPerSecond)
    }

    private var displayedValue: FrameRateLimit {
        draggingPosition.map { scale.value(at: $0) } ?? boundedValue
    }

    private var boundedValue: FrameRateLimit {
        value == .matchDisplay ? value : (FrameRateLimit(rawValue: min(value.rawValue, scale.upperBound)) ?? .matchDisplay)
    }

    private var inputHelp: Text {
        Text("Enter 1–\(scale.upperBound) FPS or Max")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: displayedValue.title)
                    .monospacedDigit()
                Spacer(minLength: 12)
                TextField("FPS", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .focused($inputFocused)
                    .onSubmit(commitInput)
                    .accessibilityLabel(Text("Custom frame rate"))
                    .help(inputHelp)
            }
            .font(.caption)

            Slider(value: sliderBinding, in: 0 ... scale.maximumPosition, onEditingChanged: editingChanged)
                .controlSize(.small)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(Text(verbatim: displayedValue.title))
                .accessibilityIdentifier("frameRate.slider")
                .accessibilityAdjustableAction { direction in
                    adjustFrameRate(increasing: direction == .increment)
                }
                .onMoveCommand { direction in
                    switch direction {
                    case .right, .up: adjustFrameRate(increasing: true)
                    case .left, .down: adjustFrameRate(increasing: false)
                    @unknown default: break
                    }
                }

            presetMarkers
            if invalidInput {
                inputHelp
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onAppear { resetInput() }
        .onChange(of: value) { _, _ in
            draggingPosition = nil
            resetInput()
        }
        .onChange(of: displayFramesPerSecond) { _, _ in
            draggingPosition = nil
            resetInput()
        }
        .onChange(of: inputFocused) { wasFocused, focused in
            if wasFocused, !focused {
                switch FrameRateTextEntry.blurCommit(text: input, value: value, upperBound: scale.upperBound) {
                case .unchanged: break
                case .invalid: invalidInput = true
                case let .commit(chosen): commit(chosen)
                }
            }
        }
        .onDisappear {
            pendingCommit?.cancel()
            pendingCommit = nil
            isDragging = false
            draggingPosition = nil
        }
    }

    private var presetMarkers: some View {
        GeometryReader { geometry in
            ForEach(scale.presets) { preset in
                Button { commit(preset) } label: {
                    VStack(spacing: 3) {
                        Circle().fill(.secondary).frame(width: 3, height: 3)
                        Text(verbatim: preset == .matchDisplay ? preset.title : String(preset.rawValue))
                            .font(.system(size: 10).monospacedDigit())
                    }
                    .frame(width: 32, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: preset.title))
                .position(x: 8 + (geometry.size.width - 16) * scale.position(for: preset)
                    / scale.maximumPosition, y: 12)
            }
        }
        .frame(height: 24)
    }

    private var sliderBinding: Binding<Double> {
        Binding(get: { draggingPosition ?? scale.position(for: value) }, set: { position in
            let chosen = scale.value(at: position)
            draggingPosition = scale.position(for: chosen)
            guard !isDragging else { return }
            pendingCommit?.cancel()
            pendingCommit = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                pendingCommit = nil
                commit(chosen)
            }
        })
    }

    private func editingChanged(_ editing: Bool) {
        isDragging = editing
        pendingCommit?.cancel()
        pendingCommit = nil
        if editing {
            inputFocused = false
        } else if let position = draggingPosition {
            commit(scale.value(at: position))
        }
    }

    private func commit(_ chosen: FrameRateLimit) {
        let chosen = chosen == .matchDisplay ? chosen : (FrameRateLimit(rawValue: min(chosen.rawValue, scale.upperBound)) ?? .matchDisplay)
        draggingPosition = nil
        if value != chosen {
            value = chosen
        }
        input = chosen == .matchDisplay ? chosen.title : String(chosen.rawValue)
        invalidInput = false
    }

    private func commitInput() {
        if let chosen = FrameRateTextEntry.parse(input, upperBound: scale.upperBound) {
            commit(chosen)
        } else {
            invalidInput = true
        }
    }

    private func adjustFrameRate(increasing: Bool) {
        if value == .matchDisplay {
            if !increasing {
                commit(FrameRateLimit(rawValue: scale.anchors.last ?? 120) ?? .fps120)
            }
            return
        }
        let next = boundedValue.rawValue + (increasing ? 1 : -1)
        if next > scale.upperBound {
            commit(.matchDisplay)
        } else {
            commit(FrameRateLimit(rawValue: max(1, next)) ?? value)
        }
    }

    private func resetInput() {
        input = FrameRateTextEntry.text(for: value, upperBound: scale.upperBound)
        invalidInput = false
    }
}
