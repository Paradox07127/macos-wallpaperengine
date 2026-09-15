import Foundation

/// Propagates cancellation to detached CPU work and drains it before its captured resources are released.
enum CancellableBackgroundWork {
    static func run<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            return try autoreleasepool {
                let value = try operation()
                try Task.checkCancellation()
                return value
            }
        }
        return try await withTaskCancellationHandler {
            let value = try await worker.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            worker.cancel()
        }
    }
}
