import SwiftUI

/// The one way to make a circular icon action button (w5-p2-spec §R1a):
/// `Button` + `adaptiveGlassButton(shape: .circle)`, so hover/press/disabled and
/// the macOS 26 glass / 14 bordered split all stay system-driven. The glyph size
/// follows `controlSize` — never override the icon font. `help` /
/// `accessibilityLabel` are attached by the caller (only the call site knows the
/// icon's meaning). `Menu` cannot wrap in a `Button`: give it
/// `.menuStyle(.button)` + `.adaptiveGlassButton(_, shape: .circle, size:)`
/// directly instead (see the Workshop account control in PaneView).
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
