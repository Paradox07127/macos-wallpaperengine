import SwiftUI

/// Fixed size presets so capsule buttons stay uniform across pages — callers
/// previously passed ad-hoc font/padding combos and no two pages matched.
public enum GlassCapsuleButtonPreset: Sendable {
    case small
    case regular
    case large

    var fontSize: CGFloat {
        switch self {
        case .small: return 11
        case .regular: return 12
        case .large: return 13
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: return 8
        case .regular: return 12
        case .large: return 16
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .small: return 4
        case .regular: return 6
        case .large: return 8
        }
    }
}

public struct GlassCapsuleButtonStyle: ButtonStyle {
    public var tint: Color
    public var preset: GlassCapsuleButtonPreset

    public init(tint: Color = .accentColor, preset: GlassCapsuleButtonPreset = .regular) {
        self.tint = tint
        self.preset = preset
    }

    public func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, preset: preset)
    }

    /// Inner view so we can read `\.isEnabled` (ButtonStyle.Configuration doesn't expose it).
    private struct StyledLabel: View {
        let configuration: Configuration
        let tint: Color
        let preset: GlassCapsuleButtonPreset
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let effectiveTint = isEnabled ? tint : Color.secondary
            configuration.label
                .font(.system(size: preset.fontSize))
                .foregroundStyle(effectiveTint)
                .padding(.horizontal, preset.horizontalPadding)
                .padding(.vertical, preset.verticalPadding)
                .adaptiveGlassSurface(.capsule, tint: effectiveTint, interactive: true)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.45)
        }
    }
}
