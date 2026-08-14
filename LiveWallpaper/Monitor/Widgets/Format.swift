import Foundation

/// User-facing temperature unit for the monitor widgets' sensor readouts.
enum MonitorTemperature {
    static let fahrenheitDefaultsKey = "MonitorTemperatureFahrenheit"

    static var isFahrenheit: Bool {
        UserDefaults.standard.bool(forKey: fahrenheitDefaultsKey)
    }

    static var symbol: String { isFahrenheit ? "°F" : "°C" }

    static func valueText(_ celsius: Double) -> String {
        let c = celsius.isFinite ? celsius : 0
        let shown = isFahrenheit ? c * 9 / 5 + 32 : c
        return "\(Int(shown.rounded()))"
    }
}

enum Format {
    static func rate(_ bytesPerSec: Double) -> String {
        let bps = bytesPerSec.isFinite ? max(bytesPerSec, 0) : 0
        if bps < 1 { return "0 B/s" }
        if bps < 1024 { return "\(Int(bps.rounded())) B/s" }
        if bps < 1_048_576 {
            return String(format: bps < 10_240 ? "%.1f KB/s" : "%.0f KB/s", bps / 1024)
        }
        if bps < 1_073_741_824 {
            return String(format: bps < 10_485_760 ? "%.1f MB/s" : "%.0f MB/s", bps / 1_048_576)
        }
        return String(format: "%.1f GB/s", bps / 1_073_741_824)
    }

    static func bytes(_ value: Double) -> String {
        let b = value.isFinite ? max(value, 0) : 0
        if b < 1024 { return "\(Int(b)) B" }
        if b < 1_048_576 { return String(format: "%.0f KB", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.0f MB", b / 1_048_576) }
        return String(format: "%.1f GB", b / 1_073_741_824)
    }

    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func gib(_ bytes: Double) -> Double {
        (bytes.isFinite ? bytes : 0) / 1_073_741_824
    }

    /// Durations here are derived from timestamps in files written outside this
    /// app (agent transcripts, the statusline sidecar), so they are untrusted.
    /// `isFinite` is not a sufficient guard: 1e300 is finite and `Int(_:)`
    /// traps on it. The ceiling is ~100 years, far past any real duration.
    private static func boundedSeconds(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(min(seconds, 3.15e9))
    }

    static func mmss(_ seconds: Double) -> String {
        let sec = boundedSeconds(seconds)
        let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func ago(_ seconds: Double) -> String {
        let sec = boundedSeconds(seconds)
        if sec < 60 { return "\(sec)s" }
        if sec < 3600 { return "\(sec / 60)m" }
        if sec < 86400 { return "\(sec / 3600)h" }
        return "\(sec / 86400)d"
    }

    static func countdown(_ seconds: Double) -> String {
        let sec = boundedSeconds(seconds)
        let h = sec / 3600, m = (sec % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(sec)s"
    }

    static func tokens(_ count: Int) -> String {
        let n = max(count, 0)
        if n < 1000 { return String(n) }
        if n < 1_000_000 {
            let k = Double(n) / 1000
            return n < 10_000 ? String(format: "%.1fK", k) : String(format: "%.0fK", k)
        }
        let m = Double(n) / 1_000_000
        return n < 10_000_000 ? String(format: "%.2fM", m) : String(format: "%.1fM", m)
    }

    static func percent(_ fraction: Double) -> String {
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return "\(Int((f * 100).rounded()))%"
    }

    static func interfaceTypeLabel(_ type: String?) -> String {
        switch type {
        case "wifi": return "Wi-Fi"
        case "wiredEthernet", "wired": return "Ethernet"
        case "cellular": return "Cellular"
        case "other": return "Other"
        case let .some(value) where !value.isEmpty:
            return value.prefix(1).uppercased() + value.dropFirst()
        default: return ""
        }
    }
}
