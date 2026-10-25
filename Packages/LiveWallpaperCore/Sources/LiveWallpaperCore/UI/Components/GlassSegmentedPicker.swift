import SwiftUI

/// `.flat` for in-content hosts on an opaque background; `.glass` only for a
/// picker that genuinely floats over a preview.
public enum GlassSegmentedShell: Sendable, Equatable {
    case glass
    case flat
    /// Edit Desk nav pill / library segment control (SCREENS S1): native glass shell,
    /// selected fill `.16`, item height 26 with horizontal padding 14, outer padding 3, gap 2.
    case editDesk
    /// Icon-only display detail tabs, as tall as the `GlassToolbarMetrics.height` groups beside them.
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
    @Environment(\.appearsActive) private var appearsActive
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
        .padding(shell == .detail ? Self.detailInset : (shell == .editDesk ? 3 : 2))
        .atlasRole("GlassSegmentedPicker")

        switch shell {
        case .glass:
            row.adaptiveGlassSurface(.capsule, interactive: true)
        case .flat:
            row.background(Capsule().fill(Color.gray.opacity(0.18)))
        case .editDesk, .detail:
            // One container so the selected glass samples the shell's glass instead of rendering over it blind.
            AdaptiveGlassContainer {
                row.adaptiveGlassSurface(.capsule, interactive: true)
            }
        }
    }

    private static var detailInset: CGFloat {
        DesignTokens.Spacing.xxs
    }

    private static var detailSegmentHeight: CGFloat {
        GlassToolbarMetrics.height - 2 * detailInset
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
                .frame(width: shell == .detail ? 40 : nil, height: shell == .detail ? Self.detailSegmentHeight : (shell == .editDesk ? 26 : nil))
                .padding(.horizontal, shell == .editDesk ? 14 : 0)
                .padding(.vertical, shell == .editDesk || shell == .detail ? 0 : 3)
                .background(selectionBacking(isSelected: isSelected))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .modifier(SegmentName(name: segmentName?(value)))
    }

    /// One capsule handed across the segments slides rather than cross-fading. Position stays with
    /// `matchedGeometryEffect`: each page builds its own nav pill, and `glassEffectID` cannot morph across containers.
    @ViewBuilder
    private func selectionBacking(isSelected: Bool) -> some View {
        if shell == .editDesk || shell == .detail {
            if isSelected {
                AdaptiveGlassSelectionCapsule(fill: segmentFill(isSelected: true))
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
        // `accentColor` stays blue in an inactive window; a native segmented control greys its selection there.
        case .flat, .glass: return appearsActive ? Color.accentColor.opacity(0.35) : Color.gray.opacity(0.35)
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
