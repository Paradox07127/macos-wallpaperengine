import CoreGraphics
import Foundation

/// Populated by `PlayableVideoLoader.detectFormat(at:)`. Drives UI badges
/// (ProRes / HDR / 4K) and unlocks the EDR rendering path for HDR sources.
public struct VideoFormatInfo: Equatable, Hashable, Sendable {
    public let codecFourCC: String?
    public let isHDR: Bool
    public let resolution: CGSize?
    public let frameRate: Double?

    public init(
        codecFourCC: String? = nil,
        isHDR: Bool = false,
        resolution: CGSize? = nil,
        frameRate: Double? = nil
    ) {
        self.codecFourCC = codecFourCC
        self.isHDR = isHDR
        self.resolution = resolution
        self.frameRate = frameRate
    }
}

extension VideoFormatInfo {
    public var isProRes: Bool {
        guard let codec = codecFourCC?.lowercased() else { return false }
        return ["apch", "apcn", "apcs", "apco", "ap4h", "ap4x"].contains(codec)
    }

    public var is4K: Bool {
        guard let size = resolution else { return false }
        return max(size.width, size.height) >= 3840
    }

    public var is8K: Bool {
        guard let size = resolution else { return false }
        return max(size.width, size.height) >= 7680
    }

    /// Resolution first so "4K HDR ProRes" reads naturally.
    public var badges: [VideoFormatBadge] {
        var result: [VideoFormatBadge] = []
        if is8K {
            result.append(.resolution8K)
        } else if is4K {
            result.append(.resolution4K)
        }
        if isHDR { result.append(.hdr) }
        if isProRes { result.append(.proRes) }
        return result
    }
}

extension VideoFormatInfo {
    /// Shared vocabulary for the resolution capsule so the same wallpaper reads
    /// the same on the Workshop's online and installed grids — online derives it
    /// from a Steam tag, installed from the probed file.
    public var resolutionShortLabel: String? {
        guard let size = resolution else { return nil }
        return Self.resolutionShortLabel(width: Int(size.width), height: Int(size.height))
    }

    /// Verbatim glyphs ("4K", "1080p", "UW"), not translated — same rule as
    /// `VideoFormatBadge.displayLabel`.
    public static func resolutionShortLabel(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        if height > width { return "Portrait" }
        let ratio = Double(width) / Double(height)
        if ratio >= 3.0 { return "Dual" }
        if ratio >= 2.0 { return "UW" }
        switch height {
        case 2160...: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        default: return "SD"
        }
    }
}

/// Badge labels ("4K", "HDR", "ProRes") are verbatim glyphs, not translated
/// (per Apple HIG).
public enum VideoFormatBadge: Equatable, Hashable, Sendable {
    case resolution4K
    case resolution8K
    case hdr
    case proRes

    public var displayLabel: String {
        switch self {
        case .resolution4K: return "4K"
        case .resolution8K: return "8K"
        case .hdr:          return "HDR"
        case .proRes:       return "ProRes"
        }
    }
}
