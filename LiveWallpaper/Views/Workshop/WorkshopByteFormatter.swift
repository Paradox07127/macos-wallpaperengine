import Foundation

/// `.file` style everywhere; the unit floor differs per surface, so each keeps its own
/// cached formatter — the cache list refreshes often and rebuilding per row was ruled out.
@MainActor
enum WorkshopByteFormatter {
    static func string(_ bytes: UInt64) -> String {
        allUnits.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
    }

    static let allUnits = make([.useAll])
    static let kilobytesAndUp = make([.useKB, .useMB, .useGB])
    static let megabytesAndUp = make([.useMB, .useGB])
    /// `[]` is `NSByteCountFormatterUseDefault` — the same as `ByteCountFormatter.string(fromByteCount:countStyle:)`.
    static let platformDefault = make([])

    private static func make(_ units: ByteCountFormatter.Units) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = units
        formatter.countStyle = .file
        return formatter
    }
}
