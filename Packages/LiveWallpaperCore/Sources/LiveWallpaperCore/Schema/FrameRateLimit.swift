import SwiftUI

/// A user-selected content frame rate. Zero follows the display; positive values
/// remain absolute targets across displays and are paced by the runtime.
public struct FrameRateLimit: RawRepresentable, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    /// Serialization safety; editing and runtime limits come from the selected display mode.
    public static let supportedFrameRates = 1 ... Int(Int32.max)
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard rawValue == 0 || Self.supportedFrameRates.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    private init(preset: Int) {
        rawValue = preset
    }

    public static let fps15 = Self(preset: 15)
    public static let fps24 = Self(preset: 24)
    public static let fps30 = Self(preset: 30)
    public static let fps45 = Self(preset: 45)
    public static let fps60 = Self(preset: 60)
    public static let fps120 = Self(preset: 120)
    public static let matchDisplay = Self(preset: 0)
    public static let allCases: [Self] = [.fps15, .fps24, .fps30, .fps45, .fps60, .fps120, .matchDisplay]

    public var id: Int {
        rawValue
    }

    private var targetFrameRate: Double? {
        rawValue > 0 ? Double(rawValue) : nil
    }

    /// Show the saved intent, even when the current display or video is slower.
    public var title: String {
        self == .matchDisplay
            ? String(localized: "Max", bundle: .appLanguage, comment: "Frame rate follows the display without a user cap.")
            : Self.fpsTitle(rawValue)
    }

    public func title(forRefreshRate refreshRate: Double) -> String {
        self == .matchDisplay ? title : Self.fpsTitle(frameRate(forRefreshRate: refreshRate))
    }

    private static func fpsTitle(_ framesPerSecond: Int) -> String {
        String(localized: "\(framesPerSecond) FPS", bundle: .appLanguage,
               comment: "The selected target frame rate.")
    }

    /// Scalars only: a keyed object makes the 0.6.7 decoder throw away the whole configuration
    /// array, whereas any scalar it does not know reads as Max there.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(Int.self)
        switch raw {
        // Old scalar 1...4 meant full/half/third/quarter, never 1...4 FPS.
        case 1: self = .matchDisplay
        case 2: self = .fps30
        case 3, 4: self = .fps15
        case -4 ... -1: self = Self(rawValue: -raw) ?? .matchDisplay
        default: self = Self(rawValue: raw) ?? .matchDisplay
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        // 1...4 FPS are stored negated so they cannot be read as the divisor-era scalars.
        try container.encode((1 ... 4).contains(rawValue) ? -rawValue : rawValue)
    }

    /// Bound the requested content rate by the panel, without divisor rounding.
    public func frameRate(forRefreshRate refreshRate: Double) -> Int {
        let panel = panelRate(refreshRate)
        return max(1, Int(min(panel, targetFrameRate ?? panel).rounded()))
    }

    /// Video re-times through `AVVideoComposition`, which honours any whole rate, so the
    /// target applies directly — still bounded by the source file.
    public func videoFrameRate(forRefreshRate refreshRate: Double, sourceFrameRate: Double) -> Int {
        let panel = panelRate(refreshRate)
        let base = sourceFrameRate > 0 ? min(panel, sourceFrameRate) : panel
        guard let target = targetFrameRate else { return max(1, Int(base.rounded())) }
        return max(1, Int(min(base, target).rounded()))
    }

    /// No display reported a rate (headless, or between reconfigurations).
    private func panelRate(_ refreshRate: Double) -> Double {
        refreshRate.isFinite && refreshRate > 0 ? min(refreshRate, Double(Int32.max)) : 60
    }

    /// Keep Max distinct from an explicit cap, including on slower displays.
    public static func availableCases(forRefreshRate refreshRate: Double) -> [FrameRateLimit] {
        allCases.filter { $0 == .matchDisplay || Double($0.rawValue) <= refreshRate }
    }

    /// Plain video only: anything below the source pays for an `AVVideoComposition` pass;
    /// `matchDisplay` stays on the native path.
    public var enforcesCompositionCap: Bool {
        self != .matchDisplay
    }

    public func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
        if self == .matchDisplay {
            // Uncapped still cannot outrun the panel; a faster source is pulled down to it.
            if screenRefreshRate > 0, videoFrameRate > screenRefreshRate {
                return Float(screenRefreshRate)
            }
            return 0
        }
        let rawLimit = Float(
            self.videoFrameRate(forRefreshRate: screenRefreshRate, sourceFrameRate: videoFrameRate)
        )
        // A source already at or below the cap has nothing to composite away.
        if videoFrameRate > 0, videoFrameRate <= Double(rawLimit) {
            return 0
        }
        return rawLimit
    }

    public static func resolveCompositionFPS(
        limit: FrameRateLimit,
        videoFrameRate: Double,
        screenRefreshRate: Double
    ) -> Double {
        let effectiveLimit = limit.getEffectiveLimit(
            videoFrameRate: videoFrameRate,
            screenRefreshRate: screenRefreshRate
        )
        if effectiveLimit > 0 {
            return Double(effectiveLimit)
        }
        if videoFrameRate > 0 {
            return videoFrameRate
        }
        if screenRefreshRate > 0 {
            return screenRefreshRate
        }
        return Double(limit.frameRate(forRefreshRate: 60))
    }
}

public extension FrameRateLimit {
    /// New-config seed: scene 30 (WPE Balanced / avoid doubled `g_Time`, and the
    /// rate a scene costs the least at); video/html uncapped (native path).
    static func naturalDefault(for wallpaperType: WallpaperType) -> FrameRateLimit {
        switch wallpaperType {
        case .scene: .fps30
        case .video, .html: .matchDisplay
        }
    }
}

public enum PlainVideoFrameRateCompositionPolicy {
    public static func compositionLimit(
        frameRateLimit: FrameRateLimit,
        videoFrameRate: Double,
        screenRefreshRate: Double
    ) -> Float? {
        guard frameRateLimit.enforcesCompositionCap else { return nil }

        let limit = frameRateLimit.getEffectiveLimit(
            videoFrameRate: videoFrameRate,
            screenRefreshRate: screenRefreshRate
        )
        guard limit > 0, videoFrameRate > Double(limit) else { return nil }
        return limit
    }
}
