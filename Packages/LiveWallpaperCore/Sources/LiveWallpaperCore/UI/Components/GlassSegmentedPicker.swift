import SwiftUI

/// `.flat` for in-content hosts on an opaque background; `.glass` only for a
/// picker that genuinely floats over a preview.
public enum GlassSegmentedShell: Sendable, Equatable {
    case glass
    case flat
    /// Edit Desk nav pill / library segment control (SCREENS S1): native glass shell,
    /// selected fill `.16`, item height 26 with horizontal padding 14, outer padding 3, gap 2.
    case editDesk
    /// Icon-only display detail tabs, aligned with the 36pt toolbar groups.
    case detail
}

/// The app's toolbar tabs stay stock `.segmented` on purpose.
public struct GlassSegmentedPicker<Value: Hashable, SegmentLabel: View>: View {
    @Binding private var selection: Value
    private let values: [Value]
    private let shell: GlassSegmentedShell
    private let label: (Value, _ isSelected: Bool) -> SegmentLabel
    /// Each segment's VoiceOver name; nil leaves it to whatever the label view reads as.
    private let segmentName: ((Value) -> Text)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.segmentedSelectionNamespace) private var sharedSelectionNamespace
    @Namespace private var selectionNamespace

    public init(
        selection: Binding<Value>,
        values: [Value],
        shell: GlassSegmentedShell = .flat,
        segmentName: ((Value) -> Text)? = nil,
        @ViewBuilder label: @escaping (Value, _ isSelected: Bool) -> SegmentLabel
    ) {
        self._selection = selection
        self.values = values
        self.shell = shell
        self.segmentName = segmentName
        self.label = label
    }

    public var body: some View {
        let row = HStack(spacing: shell == .detail ? DesignTokens.Spacing.xxs : (shell == .editDesk ? 2 : 0)) {
            ForEach(values, id: \.self) { value in
                segment(value)
            }
        }
        .padding(shell == .detail ? DesignTokens.Spacing.xxs : (shell == .editDesk ? 3 : 2))

        switch shell {
        case .glass:
            row.adaptiveGlassSurface(.capsule, interactive: true)
        case .flat:
            row.background(Capsule().fill(Color.gray.opacity(0.18)))
        case .editDesk, .detail:
            row.adaptiveGlassSurface(.capsule, interactive: true)
        }
    }

    private func segment(_ value: Value) -> some View {
        let isSelected = selection == value
        return Button {
            withAnimation(DesignTokens.motion(reduceMotion, DesignTokens.Motion.selection)) {
                selection = value
            }
        } label: {
            label(value, isSelected)
                .frame(maxWidth: shell == .editDesk || shell == .detail ? nil : .infinity)
                .frame(width: shell == .detail ? 40 : nil, height: shell == .detail ? 28 : (shell == .editDesk ? 26 : nil))
                .padding(.horizontal, shell == .editDesk ? 14 : 0)
                .padding(.vertical, shell == .editDesk || shell == .detail ? 0 : 3)
                .background(selectionBacking(isSelected: isSelected))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(SegmentName(name: segmentName?(value)))
    }

    /// Edit Desk hands one capsule across the segments so the indicator slides rather than
    /// cross-fading, which also keeps a single layer of glass over the stage behind it.
    @ViewBuilder
    private func selectionBacking(isSelected: Bool) -> some View {
        if shell == .editDesk || shell == .detail {
            if isSelected {
                Capsule()
                    .fill(segmentFill(isSelected: true))
                    .matchedGeometryEffect(id: "selectedSegment", in: backingNamespace)
            }
        } else {
            Capsule().fill(segmentFill(isSelected: isSelected))
        }
    }

    /// Only `.editDesk` joins a shared namespace: other shells can share a screen, and a shared id would collide.
    private var backingNamespace: Namespace.ID {
        shell == .editDesk ? sharedSelectionNamespace ?? selectionNamespace : selectionNamespace
    }

    private func segmentFill(isSelected: Bool) -> Color {
        guard isSelected else { return .clear }
        switch shell {
        case .editDesk: return DesignTokens.EditDesk.Colors.fillSelectedNavItem
        case .detail: return DesignTokens.EditDesk.Colors.fillSelectedChip
        case .flat, .glass: return Color.accentColor.opacity(0.35)
        }
    }
}

private struct SegmentName: ViewModifier {
    let name: Text?

    func body(content: Content) -> some View {
        if let name {
            content.accessibilityLabel(name)
        } else {
            content
        }
    }
}

public extension EnvironmentValues {
    /// nil = each picker uses its own namespace.
    @Entry var segmentedSelectionNamespace: Namespace.ID?
}

public extension GlassSegmentedPicker where SegmentLabel == Text {
    init(
        selection: Binding<Value>,
        values: [Value],
        shell: GlassSegmentedShell = .flat,
        title: @escaping (Value) -> LocalizedStringKey
    ) {
        self.init(selection: selection, values: values, shell: shell, segmentName: { Text(title($0)) }, label: { value, isSelected in
            Text(title(value))
                .font(isSelected ? DesignTokens.Typography.bodyEmphasized : DesignTokens.Typography.body)
        })
    }
}
