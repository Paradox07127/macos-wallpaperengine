import Darwin
import Foundation

enum ProcessResourceUsage {
    static func read(pid: Int32) -> rusage_info_v4? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? usage : nil
    }

    /// Footprint matches Apple's charge to a process; RSS is only a fallback.
    static func memory(resident: UInt64, footprint: UInt64?) -> (bytes: UInt64, metric: String) {
        if let footprint {
            return (footprint, "footprint")
        }
        return (resident, "resident")
    }
}
