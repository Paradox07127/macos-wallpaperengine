import SwiftUI

/// `.flat` for in-content hosts on an opaque background; `.glass` only for a
/// picker that genuinely floats over a preview.
public enum GlassSegmentedShell: Sendable, Equatable {
    case glass
    case flat
    /// Edit Desk nav pill / library segment control (SCREENS S1): native glass shell,
    /// selected fill `.16`, item height 26 with horizontal padding 14, outer padding 3, gap 2.
    case editDesk
}

/// The app's toolbar tabs stay stock `.segmented` on purpose.
public struct GlassSegmentedPicker<Value: Hashable, SegmentLabel: View>: View {
    @Binding private var selection: Value
    private let values: [Value]
    private let shell: GlassSegmentedShell
    private let label: (Value, _ isSelected: Bool) -> SegmentLabel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

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
        let row = HStack(spacing: shell == .editDesk ? 2 : 0) {
            ForEach(values, id: \.self) { value in
                segment(value)
            }
        }
        .padding(shell == .editDesk ? 3 : 2)

        switch shell {
        case .glass:
            row.adaptiveGlassSurface(.capsule, interactive: true)
        case .flat:
            row.background(Capsule().fill(Color.gray.opacity(0.18)))
        case .editDesk:
            row.adaptiveGlassSurface(.capsule, interactive: true)
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
                .frame(maxWidth: shell == .editDesk ? nil : .infinity)
                .frame(height: shell == .editDesk ? 26 : nil)
                .padding(.horizontal, shell == .editDesk ? 14 : 0)
                .padding(.vertical, shell == .editDesk ? 0 : 3)
                .background(selectionBacking(isSelected: isSelected))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Edit Desk hands one capsule across the segments so the indicator slides rather than
    /// cross-fading, which also keeps a single layer of glass over the stage behind it.
    @ViewBuilder
    private func selectionBacking(isSelected: Bool) -> some View {
        if shell == .editDesk {
            if isSelected {
                Capsule()
                    .fill(segmentFill(isSelected: true))
                    .matchedGeometryEffect(id: "selectedSegment", in: selectionNamespace)
            }
        } else {
            Capsule().fill(segmentFill(isSelected: isSelected))
        }
    }

    private func segmentFill(isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        return shell == .editDesk ? DesignTokens.EditDesk.Colors.fillSelectedNavItem : Color.accentColor.opacity(0.35)
    }
}

public extension GlassSegmentedPicker where SegmentLabel == Text {
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
