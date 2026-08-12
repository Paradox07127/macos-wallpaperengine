import AppKit

/// Pure ownership state for deduplicated HTML snapshot producers.
///
/// Each caller owns one lease. Cancelling a lease only cancels the producer
/// after the last waiter leaves; producer completion is identity-checked so a
/// late completion from cancelled work cannot retire a replacement for the
/// same cache key.
struct HTMLSnapshotLeaseState {
    struct ProducerID: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    struct LeaseID: Hashable, Sendable {
        fileprivate let rawValue: UInt64
    }

    struct Lease: Equatable, Sendable {
        let cacheKey: String
        let producerID: ProducerID
        let leaseID: LeaseID
    }

    enum Acquisition: Equatable {
        case start(Lease)
        case join(Lease)

        var lease: Lease {
            switch self {
            case .start(let lease), .join(let lease):
                return lease
            }
        }
    }

    enum ReleaseAction: Equatable {
        case none
        case cancelProducer(ProducerID)
    }

    private struct Entry {
        let producerID: ProducerID
        var leaseIDs: Set<LeaseID>
    }

    private var nextProducerRawValue: UInt64 = 0
    private var nextLeaseRawValue: UInt64 = 0
    private var entriesByCacheKey: [String: Entry] = [:]

    mutating func acquire(cacheKey: String) -> Acquisition {
        nextLeaseRawValue &+= 1
        let leaseID = LeaseID(rawValue: nextLeaseRawValue)

        if var existing = entriesByCacheKey[cacheKey] {
            existing.leaseIDs.insert(leaseID)
            entriesByCacheKey[cacheKey] = existing
            return .join(
                Lease(
                    cacheKey: cacheKey,
                    producerID: existing.producerID,
                    leaseID: leaseID
                )
            )
        }

        nextProducerRawValue &+= 1
        let producerID = ProducerID(rawValue: nextProducerRawValue)
        entriesByCacheKey[cacheKey] = Entry(
            producerID: producerID,
            leaseIDs: [leaseID]
        )
        return .start(
            Lease(
                cacheKey: cacheKey,
                producerID: producerID,
                leaseID: leaseID
            )
        )
    }

    mutating func release(_ lease: Lease) -> ReleaseAction {
        guard var entry = entriesByCacheKey[lease.cacheKey],
              entry.producerID == lease.producerID,
              entry.leaseIDs.remove(lease.leaseID) != nil else {
            return .none
        }
        guard entry.leaseIDs.isEmpty else {
            entriesByCacheKey[lease.cacheKey] = entry
            return .none
        }
        entriesByCacheKey[lease.cacheKey] = nil
        return .cancelProducer(lease.producerID)
    }

    /// Returns the leases owned by this exact producer. A stale completion
    /// returns an empty set and leaves the current cache-key owner untouched.
    mutating func complete(
        cacheKey: String,
        producerID: ProducerID
    ) -> Set<LeaseID> {
        guard let entry = entriesByCacheKey[cacheKey],
              entry.producerID == producerID else {
            return []
        }
        entriesByCacheKey[cacheKey] = nil
        return entry.leaseIDs
    }

    func producerID(for cacheKey: String) -> ProducerID? {
        entriesByCacheKey[cacheKey]?.producerID
    }

    #if DEBUG
    // Test-only introspection; no production reader.
    func waiterCount(for cacheKey: String) -> Int {
        entriesByCacheKey[cacheKey]?.leaseIDs.count ?? 0
    }
    #endif
}

@MainActor
final class HTMLSnapshotWaiter {
    private enum State {
        case pending
        case resolved(NSImage?)
    }

    private var state: State = .pending
    private var continuation: CheckedContinuation<NSImage?, Never>?

    func wait() async -> NSImage? {
        switch state {
        case .pending:
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        case .resolved(let image):
            return image
        }
    }

    func resolve(_ image: NSImage?) {
        guard case .pending = state else { return }
        state = .resolved(image)
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: image)
    }
}
