import SwiftUI

/// A cap expressed as a divisor of the display's refresh rate, not as an absolute
/// frame rate.
///
/// The scene renderer paces frames with `CADisplayLink`, which only wakes on a
/// divisor of the current refresh rate and snaps anything else — measured on a
/// 60 Hz panel: a request of 40 lands on 60, 36 and 24 both land on 30, 20/15/12/10
/// land on themselves. So the old absolute cases could not all be honoured: `24 FPS`
/// ran at 30 and saved nothing, while a 144 Hz panel had no option between 60 and
/// uncapped. A divisor is the one form every display can actually deliver.
public enum FrameRateLimit: Int, CaseIterable, Identifiable, Codable, Sendable {
    // Declared low-to-high: the per-display control is a slider that indexes
    // `allCases`, so the order is the order the user drags through.
    case quarter = 4
    case third = 3
    case half = 2
    /// Every vsync — what "Unlimited" always resolved to in practice.
    case full = 1

    public var id: Int { rawValue }

    /// Label for a control that knows which display it is for. Absolute, because
    /// "30 FPS" is what the user is choosing; the divisor is the mechanism.
    public func title(forRefreshRate refreshRate: Double) -> String {
        Self.fpsTitle(frameRate(forRefreshRate: refreshRate))
    }

    /// Same label for the video path, which divides the source when the source is
    /// slower than the panel.
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

    /// Absolute caps written by builds before the divisor form. They cannot collide
    /// with the divisors (1…4), so one decoder reads both.
    /// 0 was "unlimited", which the link ran at the refresh rate anyway; 60 was the
    /// only panel this shipped against; 24 measurably snapped to 30 on that panel.
    private static let legacyAbsoluteRates: [Int: FrameRateLimit] = [
        0: .full,
        60: .full,
        30: .half,
        24: .half,
        15: .quarter,
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)
        if let divisor = FrameRateLimit(rawValue: rawValue) {
            self = divisor
        } else {
            self = FrameRateLimit.legacyAbsoluteRates[rawValue] ?? .full
        }
    }

    /// The rate this cap produces on a display, rounded to whole frames because
    /// that is what the UI shows and what `CADisplayLink` is asked for. Scene and
    /// web wallpapers divide the panel: their ceiling *is* vsync.
    public func frameRate(forRefreshRate refreshRate: Double) -> Int {
        max(1, Int((panelRate(refreshRate) / Double(rawValue)).rounded()))
    }

    /// Video divides whichever is lower, the panel or the file. A 30 fps file on a
    /// 144 Hz screen has nothing above 30 to divide, so dividing the panel produced
    /// 144/72/48/36 — four steps that all sit above the source and therefore all
    /// collapse to "no cap", leaving the slider inert.
    public func videoFrameRate(forRefreshRate refreshRate: Double, sourceFrameRate: Double) -> Int {
        let panel = panelRate(refreshRate)
        let base = sourceFrameRate > 0 ? min(panel, sourceFrameRate) : panel
        return max(1, Int((base / Double(rawValue)).rounded()))
    }

    /// No display reported a rate (headless, or between reconfigurations).
    private func panelRate(_ refreshRate: Double) -> Double {
        refreshRate > 0 ? refreshRate : 60
    }

    /// Plain video only: anything below the refresh rate pays for an
    /// `AVVideoComposition` pass; `full` stays on the native path. Effects already
    /// require composition regardless.
    public var enforcesCompositionCap: Bool {
        self != .full
    }

    public func getEffectiveLimit(videoFrameRate: Double, screenRefreshRate: Double) -> Float {
        if self == .full {
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
    /// New-config seed: scene half (WPE Balanced / avoid doubled `g_Time`);
    /// video/html full (native path).
    public static func naturalDefault(for wallpaperType: WallpaperType) -> FrameRateLimit {
        switch wallpaperType {
        case .scene: .half
        case .video, .html: .full
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
