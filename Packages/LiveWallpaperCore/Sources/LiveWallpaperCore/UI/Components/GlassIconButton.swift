import SwiftUI

public struct GlassIconButton: View {
    /// Replaces the glass tiers with a flat token circle, for call sites whose design fixes the
    /// fill and the glyph instead of letting the tier pick them (SCREENS.md S6).
    public struct FlatFill {
        public let fill: Color
        public let foreground: Color
        public let diameter: CGFloat

        public init(fill: Color, foreground: Color, diameter: CGFloat) {
            self.fill = fill
            self.foreground = foreground
            self.diameter = diameter
        }
    }

    private let systemImage: String
    private let prominence: AdaptiveGlassProminence
    private let size: ControlSize
    private let tint: Color?
    private let role: ButtonRole?
    private let flatFill: FlatFill?
    private let action: () -> Void

    public init(
        _ systemImage: String,
        prominence: AdaptiveGlassProminence = .regular,
        size: ControlSize = .large,
        tint: Color? = nil,
        role: ButtonRole? = nil,
        flatFill: FlatFill? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.prominence = prominence
        self.size = size
        self.tint = tint
        self.role = role
        self.flatFill = flatFill
        self.action = action
    }

    public var body: some View {
        if let flatFill {
            flat(flatFill)
        } else {
            glass
        }
    }

    private func flat(_ appearance: FlatFill) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .foregroundStyle(appearance.foreground)
                .frame(width: appearance.diameter, height: appearance.diameter)
                .background(Circle().fill(appearance.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var glass: some View {
        let button = Button(role: role, action: action) {
            Image(systemName: systemImage)
        }
        .adaptiveGlassButton(prominence, shape: .circle, size: size)
        if let tint {
            button.tint(tint)
        } else {
            button
        }
    }
}
