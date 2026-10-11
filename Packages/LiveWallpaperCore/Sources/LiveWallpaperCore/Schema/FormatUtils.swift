import Foundation

public enum FormatUtils {
    public static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    public static func formatPercent(_ percent: Double) -> String {
        formatFractionAsPercent(percent / 100)
    }

    public static func formatFractionAsPercent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        return clamped.formatted(.percent.precision(.fractionLength(0)))
    }
}
