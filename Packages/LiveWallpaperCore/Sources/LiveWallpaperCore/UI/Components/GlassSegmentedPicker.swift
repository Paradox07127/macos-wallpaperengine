import SwiftUI

/// Shell behind the segments. `.flat` is the default because every current host
/// is in-content — an inspector card or a settings panel on an opaque background,
/// where glass has nothing to refract and only adds an edge. `.glass` is for a
/// picker that genuinely floats over a preview.
public enum GlassSegmentedShell: Sendable {
    case glass
    case flat
}

/// Shared in-content segmented control (the app's toolbar tabs stay stock
/// `.segmented` on purpose). Segments are always equal-width.
public struct GlassSegmentedPicker<Value: Hashable, SegmentLabel: View>: View {
    @Binding private var selection: Value
    private let values: [Value]
    private let shell: GlassSegmentedShell
    private let label: (Value, _ isSelected: Bool) -> SegmentLabel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        selection: Binding<Value>,
        values: [Value],
        shell: GlassSegmentedShell = .flat,
        @ViewBuilder label: @escaping (Value, _ isSelected: Bool) -> SegmentLabel
    ) {
        self._selection = selection
        self.values = values
        self.shell = shell
        self.label = label
    }

    public var body: some View {
        let row = HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                segment(value)
            }
        }
        .padding(2)

        switch shell {
        case .glass:
            row.adaptiveGlassSurface(.capsule, interactive: true)
        case .flat:
            row.background(Capsule().fill(Color.gray.opacity(0.18)))
        }
    }

    private func segment(_ value: Value) -> some View {
        let isSelected = selection == value
        return Button {
            withAnimation(DesignTokens.motion(reduceMotion, .snappy(duration: 0.18))) {
                selection = value
            }
        } label: {
            label(value, isSelected)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

public extension GlassSegmentedPicker where SegmentLabel == Text {
    /// Text segments in the canonical body/bodyEmphasized weights.
    init(
        selection: Binding<Value>,
        values: [Value],
        shell: GlassSegmentedShell = .flat,
        title: @escaping (Value) -> LocalizedStringKey
    ) {
        self.init(selection: selection, values: values, shell: shell) { value, isSelected in
            Text(title(value))
                .font(isSelected ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
        }
    }
}
