#if !LITE_BUILD
import Foundation

/// Memory-tier policy for the live video decoder admission limit.
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
