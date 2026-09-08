import SwiftUI

/// Circular icon action using shared glass and control-size metrics.
/// Callers supply help and an accessible name; use a button with a popover over artwork.
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

    public var body: some View {
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
