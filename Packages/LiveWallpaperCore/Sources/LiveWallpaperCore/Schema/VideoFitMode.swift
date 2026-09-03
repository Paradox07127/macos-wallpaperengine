import AVFoundation
import SwiftUI

public enum VideoFitMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case aspectFill = "Fill"
    case aspectFit = "Fit"
    case stretch = "Stretch"
    case center = "Center"

    public static let videoModes: [VideoFitMode] = [.aspectFill, .aspectFit, .stretch]
    public static let sceneModes: [VideoFitMode] = [.aspectFill, .aspectFit, .stretch, .center]

    public var id: String { rawValue }

    /// Tolerant decoder: an unknown fit mode (future build's addition, rolled back)
    /// decodes to `.aspectFill` instead of failing the whole `ScreenConfiguration` parse.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if let mode = VideoFitMode(rawValue: rawValue) {
            self = mode
        } else {
            Logger.warning("VideoFitMode: unknown rawValue \"\(rawValue)\", defaulting to aspectFill", category: .settings)
            self = .aspectFill
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .aspectFill: return "Fill"
        case .aspectFit: return "Fit"
        case .stretch: return "Stretch"
        case .center: return "Center"
        }
    }

    public var tooltipKey: LocalizedStringKey {
        switch self {
        case .aspectFill: return "Fill: crop to fill screen"
        case .aspectFit: return "Fit: show entire video"
        case .stretch: return "Stretch: distort to fill"
        case .center: return "Center: original size"
        }
    }

    public var iconName: String {
        switch self {
        case .aspectFill: return "rectangle.fill"
        case .aspectFit: return "rectangle"
        case .stretch: return "arrow.up.left.and.arrow.down.right"
        case .center: return "viewfinder"
        }
    }

    public var avLayerVideoGravity: AVLayerVideoGravity {
        switch self {
        case .aspectFill: return .resizeAspectFill
        case .aspectFit: return .resizeAspect
        case .stretch: return .resize
        case .center: return .resizeAspect
        }
    }
}
