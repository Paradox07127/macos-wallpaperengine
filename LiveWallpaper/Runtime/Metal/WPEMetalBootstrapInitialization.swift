#if !LITE_BUILD
import Foundation
import Metal

/// Completion callbacks publish only to their own token, never into the
/// executor's dictionary: an older failure cannot invalidate a newer entry.
final class WPEMetalBootstrapInitialization: @unchecked Sendable {
    private enum State { case encoded, ready, failed }
    private let lock = NSLock()
    private var state = State.encoded
    private weak var owner: MTLCommandBuffer?

    init(commandBuffer: MTLCommandBuffer) {
        owner = commandBuffer
    }

    func canRead(in commandBuffer: MTLCommandBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .ready: return true
        case .encoded: return owner === commandBuffer
        case .failed: return false
        }
    }

    func belongs(to commandBuffer: MTLCommandBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return owner === commandBuffer
    }

    func complete(succeeded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        state = succeeded ? .ready : .failed
    }
}

struct WPEMetalBootstrapTexture {
    let texture: MTLTexture
    let initialization: WPEMetalBootstrapInitialization
}
#endif
