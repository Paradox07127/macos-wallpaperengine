#if !LITE_BUILD
import Foundation

/// Manual defaults always win (WPEMetalTextureCacheBudgetMiB; explicit 0 ⇒ unbounded).
enum WPEMemoryTier: CaseIterable, Equatable, Sendable {
    case constrained
    case standard
    case expansive

    static let current = tier(forPhysicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)

    /// Boundaries sit between shipping Apple-silicon RAM points (8/16/18/24/32…):
    /// <12 GiB captures the 8 GB baseline, <24 GiB captures 16/18 GB.
    static func tier(forPhysicalMemoryBytes bytes: UInt64) -> WPEMemoryTier {
        let gib = Double(bytes) / 1_073_741_824
        if gib < 12 { return .constrained }
        if gib < 24 { return .standard }
        return .expansive
    }

    /// Every tier is bounded: nil here would skip LRU eviction entirely. Unbounded remains available only via the manual defaults override (explicit ≤0).
    var defaultTextureCacheBudgetBytes: Int? {
        switch self {
        case .constrained: return 256 * 1_048_576
        case .standard: return 512 * 1_048_576
        case .expansive: return 768 * 1_048_576
        }
    }

    /// Caps native-resolution perspective rendering to bound FBO memory growth.
    /// HDR halves the pixel budget because `rgba16Float` doubles bytes per pixel.
    func perspectiveRenderPixelBudget(hdr: Bool) -> Double {
        let base = 1920.0 * 1080.0
        let multiplier: Double
        switch self {
        case .constrained: multiplier = 1.0   // 8 GB: no native-res bump
        case .standard: multiplier = 2.25      // 16/18 GB: up to ~1620p
        case .expansive: multiplier = 4.0      // ≥24 GB: up to 4K
        }
        return base * (hdr ? multiplier * 0.5 : multiplier)
    }

    var lazyAnimationRawByteThreshold: Int {
        switch self {
        case .constrained: return 100_000_000
        case .standard, .expansive: return 200_000_000
        }
    }

    /// Process-wide budget for decoded animation frame bytes shared by every lazy .tex source across all scenes/displays.
    var animatedFrameCacheBudgetBytes: Int {
        switch self {
        case .constrained: return 96 * 1_048_576
        case .standard: return 128 * 1_048_576
        case .expansive: return 192 * 1_048_576
        }
    }

    /// Single decoded frame admission cap: frames above this decode, upload,
    /// and release without entering the process cache (and never prefetch).
    var animatedFrameAdmissionByteCap: Int {
        switch self {
        case .constrained: return 32 * 1_048_576
        case .standard: return 48 * 1_048_576
        case .expansive: return 64 * 1_048_576
        }
    }

    /// Process-wide live `AVQueuePlayer` decoders for MP4-in-`.tex` sources.
    /// Overflow sources keep a still frame instead of refusing the layer.
    var videoDecoderLimit: Int {
        switch self {
        case .constrained: return 2
        case .standard: return 4
        case .expansive: return 6
        }
    }
}
#endif
