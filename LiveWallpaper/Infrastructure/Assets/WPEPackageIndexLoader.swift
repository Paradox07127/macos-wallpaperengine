import Foundation

/// FileHandle is blocking I/O and must not occupy the cooperative executor; parse on this utility queue, not a detached Swift task.
enum WPEPackageIndexLoader {
    struct PreparedPackage: @unchecked Sendable {
        let package: WallpaperEnginePackage
        let handle: FileHandle
    }

    /// Caps concurrent parses at 2 so two displays/imports progress without multiplying the bounded-index budget under hostile simultaneous inputs.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.livewallpaper.wpe-package-index"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    static func load(
        from packageURL: URL,
        limits: WallpaperEnginePackage.IndexLimits = .production
    ) async throws -> PreparedPackage {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        let handle = try FileHandle(forReadingFrom: packageURL)
                        do {
                            let package = try WallpaperEnginePackage.parseIndex(
                                streamingFrom: handle,
                                limits: limits,
                                shouldCancel: { cancellation.isCancelled }
                            )
                            guard !cancellation.isCancelled else {
                                try? handle.close()
                                throw CancellationError()
                            }
                            continuation.resume(returning: PreparedPackage(package: package, handle: handle))
                        } catch {
                            try? handle.close()
                            throw error
                        }
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
