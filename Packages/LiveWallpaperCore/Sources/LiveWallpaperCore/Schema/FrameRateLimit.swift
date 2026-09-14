import SwiftUI

/// A cap expressed as a target frame rate, plus one case that declines to cap and follows
/// the panel. Scene and web pace with `CADisplayLink`, which only wakes on a divisor of the
/// refresh rate, so a target resolves to the fastest divisor not exceeding it.
public enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    // Declared low-to-high: the per-display slider indexes these cases in order, so the
    // order is the order the user drags through.
    case fps15 = 15
    case fps30 = 30
    case fps60 = 60
    /// Every vsync the panel offers. The only case that can exceed 60.
    case matchDisplay = 0

    public var id: Int { rawValue }

    /// `nil` for `matchDisplay`, which has no target to resolve against.
    private var targetFrameRate: Double? {
        rawValue > 0 ? Double(rawValue) : nil
    }

    /// Always the rate the display will actually run at, never the target — the two differ
    /// whenever the refresh rate is not a multiple of the target.
    public func title(forRefreshRate refreshRate: Double) -> String {
        Self.fpsTitle(frameRate(forRefreshRate: refreshRate))
    }

    /// Same label for the video path, which is bounded by the source file as well.
    public func videoTitle(forRefreshRate refreshRate: Double, sourceFrameRate: Double) -> String {
        Self.fpsTitle(videoFrameRate(forRefreshRate: refreshRate, sourceFrameRate: sourceFrameRate))
    }

    private static func fpsTitle(_ framesPerSecond: Int) -> String {
        String(
            localized: "\(framesPerSecond) FPS",
            bundle: .appLanguage,
            comment: "Frame-rate cap label. The placeholder is the resulting frames per second on that display."
        )
    }

    /// Raw values written by earlier builds. The absolute era (0/60/30/24/15) maps onto the
    /// same numbers; only 24 needs a rule. The divisor era (1…4) is read against a 60 Hz panel,
    /// and `full` becomes `matchDisplay` so a 120/240 Hz display keeps running as it did.
    private static let legacyRates: [Int: FrameRateLimit] = [
        24: .fps30,
        1: .matchDisplay,
        2: .fps30,
        3: .fps15,
        4: .fps15,
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        if let known = FrameRateLimit(rawValue: rawValue) {
            self = known
        } else {
            self = FrameRateLimit.legacyRates[rawValue] ?? .matchDisplay
        }
    }

    /// The rate this cap produces on a display: scene and web divide the panel, so the target
    /// is rounded down onto a divisor rather than requested as-is.
    public func frameRate(forRefreshRate refreshRate: Double) -> Int {
        let panel = panelRate(refreshRate)
        guard let target = targetFrameRate else { return max(1, Int(panel.rounded())) }
        let divisor = max(1, (panel / target).rounded(.up))
        return max(1, Int((panel / divisor).rounded()))
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
        refreshRate > 0 ? refreshRate : 60
    }

    /// The cases worth offering on a display, low to high. `matchDisplay` drops out at 60 Hz
    /// and below, where it resolves to the same rate as `fps60`.
    public static func availableCases(forRefreshRate refreshRate: Double) -> [FrameRateLimit] {
        var seen: Set<Int> = []
        return allCases.filter { seen.insert($0.frameRate(forRefreshRate: refreshRate)).inserted }
    }

    /// True when both produce the same on-screen rate — e.g. `.matchDisplay` and `.fps60` at 60 Hz.
    public func resolvesToSameRate(as other: FrameRateLimit, forRefreshRate refreshRate: Double) -> Bool {
        frameRate(forRefreshRate: refreshRate) == other.frameRate(forRefreshRate: refreshRate)
    }

    /// Plain video only: anything below the source pays for an `AVVideoComposition` pass;
    /// `matchDisplay` stays on the native path.
    public var enforcesCompositionCap: Bool {
        self != .matchDisplay
    }

    public func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
        if self == .matchDisplay {
            // Uncapped still cannot outrun the panel; a faster source is pulled down to it.
            if screenRefreshRate > 0 && videoFrameRate > screenRefreshRate {
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

extension FrameRateLimit {
    /// New-config seed: scene 30 (WPE Balanced / avoid doubled `g_Time`, and the
    /// rate a scene costs the least at); video/html uncapped (native path).
    public static func naturalDefault(for wallpaperType: WallpaperType) -> FrameRateLimit {
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
