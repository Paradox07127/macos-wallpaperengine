#if !LITE_BUILD
import Foundation

/// Thread-safe sink for GPU command-buffer errors: they surface in the completed handler on a
/// GPU thread AFTER the frame call returned, so they can't throw. Bounded to count + last
/// message so a persistently-failing GPU never grows memory.
final class WPEGPUErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var errorCount = 0
    private var lastMessage: String?

    /// First five, then every 300th — same cadence as present drawable-miss logs.
    static func shouldLogOccurrence(_ count: Int) -> Bool {
        count <= 5 || count % 300 == 0
    }

    @discardableResult
    func record(_ message: String) -> Int {
        lock.lock()
        errorCount += 1
        lastMessage = message
        let n = errorCount
        lock.unlock()
        return n
    }

    var summary: (count: Int, last: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (errorCount, lastMessage)
    }
}
#endif
