import SwiftUI

public struct GlassIconButton: View {
    private let systemImage: String
    private let prominence: AdaptiveGlassProminence
    private let size: ControlSize
    private let tint: Color?
    private let role: ButtonRole?
    private let action: () -> Void

    public init(
        _ systemImage: String,
        prominence: AdaptiveGlassProminence = .regular,
        size: ControlSize = .large,
        tint: Color? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.prominence = prominence
        self.size = size
        self.tint = tint
        self.role = role
        self.action = action
    }

    @ViewBuilder
    public var body: some View {
        let diameter = DesignTokens.iconButtonDiameter(size)
        let button = Button(role: role, action: action) {
            // As the label, the symbol's own bounds would size the circle; the overlay keeps them out of layout.
            Color.clear.overlay { Image(systemName: systemImage) }
        }
        .adaptiveGlassButton(prominence, shape: .circle, size: size)
        .frame(width: diameter, height: diameter)
        if let tint {
            button.tint(tint)
        } else {
            button
        }
    }
}
