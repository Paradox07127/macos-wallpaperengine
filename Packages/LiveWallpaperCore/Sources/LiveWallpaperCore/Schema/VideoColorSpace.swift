import Foundation

/// Per-screen `AVPlayerLayer` color management. `.auto` leaves the layer alone
/// (system path + EDR); other cases pin `CALayer.colorspace` (HDR keeps EDR).
public enum VideoColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case sRGB
    case displayP3
    case rec2020HDR
    /// Rec.709 composition SDR escape hatch; mutually exclusive with frame-rate cap
    /// (either composition replaces the other).
    case forceSDR

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .auto:        return "Auto"
        case .sRGB:        return "sRGB"
        case .displayP3:   return "Display P3"
        case .rec2020HDR:  return "Rec.2020 HDR"
        case .forceSDR:    return "Force SDR"
        }
    }

    public var descriptionKey: String {
        switch self {
        case .auto:
            return "Use the display's native profile."
        case .sRGB:
            return "Force sRGB output — most accurate for SDR content."
        case .displayP3:
            return "Wide-gamut output for P3-capable displays."
        case .rec2020HDR:
            return "HDR-aware output. Requires an HDR-capable display."
        case .forceSDR:
            return "Render HDR content as SDR via Rec.709. Disables frame-rate limit."
        }
    }
}
