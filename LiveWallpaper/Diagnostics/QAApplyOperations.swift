#if DEBUG
import CoreGraphics
import Foundation

/// Bounded operation history. Completion means a product apply was confirmed, not visual correctness.
@MainActor
final class QAApplyOperations {
    final class Operation {
        let id = UUID().uuidString
        let screenID: CGDirectDisplayID
        let requestID: String?
        let target: String
        let revision: String
        let createdAt = Date()
        var status = "pending"
        var result: [String: Any] = [:]
        var task: Task<Void, Never>?

        init(screenID: CGDirectDisplayID, requestID: String?, target: String, revision: String) {
            self.screenID = screenID
            self.requestID = requestID
            self.target = target
            self.revision = revision
        }

        var terminal: Bool {
            !["pending", "running"].contains(status)
        }

        var json: [String: Any] {
            ["operationID": id, "screenID": screenID, "itemID": target, "itemRevision": revision,
             "status": status, "completionLevel": "committed",
             "createdAt": createdAt.ISO8601Format(), "result": result]
        }
    }

    private var history: [Operation] = []
    let capacity: Int

    init(capacity: Int = 128) {
        self.capacity = capacity
    }

    func previous(requestID: String?, screenID: CGDirectDisplayID, target: String, revision: String?) throws -> Operation? {
        guard let requestID, let existing = history.first(where: { $0.requestID == requestID }) else { return nil }
        guard existing.screenID == screenID, existing.target == target,
              revision == nil || revision == existing.revision else {
            throw QAControlPlane.QAError.message("requestID already belongs to a different apply")
        }
        return existing
    }

    func start(screenID: CGDirectDisplayID, requestID: String?, target: String, revision: String,
               apply: @escaping @MainActor () async -> [String: Any]) throws -> Operation {
        while history.count >= capacity, let index = history.firstIndex(where: \.terminal) {
            history.remove(at: index)
        }
        guard history.count < capacity else { throw QAControlPlane.QAError.message("Too many active operations") }
        guard !history.contains(where: { $0.screenID == screenID && !$0.terminal }) else {
            throw QAControlPlane.QAError.message("An apply is still running on this screen; wait for its operation first")
        }
        let operation = Operation(screenID: screenID, requestID: requestID, target: target, revision: revision)
        history.append(operation)
        operation.task = Task { @MainActor [weak operation] in
            guard let operation else { return }
            operation.status = "running"
            let result = await apply()
            guard !Task.isCancelled else { return }
            operation.result = result
            operation.status = result["confirmed"] as? Bool == true ? "completed" : "failed"
            operation.task = nil
        }
        return operation
    }

    func get(_ arguments: [String: Any]) throws -> Operation {
        guard let id = try QALibraryCatalog.optionalString(arguments["operationID"], key: "operationID"),
              let operation = history.first(where: { $0.id == id }) else {
            throw QAControlPlane.QAError.message("Unknown or expired operationID")
        }
        return operation
    }

    func wait(_ arguments: [String: Any]) async throws -> [String: Any] {
        try QALibraryCatalog.validateKeys(arguments, allowed: ["operationID", "timeoutMs"])
        let operation = try get(arguments)
        let timeout = try QALibraryCatalog.integer(arguments["timeoutMs"] ?? 1000, key: "timeoutMs", range: 0 ... 10000)
        let clock = ContinuousClock()
        let deadline = clock.now + .milliseconds(timeout)
        while !operation.terminal, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        var result = operation.json
        result["waitTimedOut"] = !operation.terminal
        return result
    }

    func shutdown() {
        for operation in history where !operation.terminal {
            operation.task?.cancel()
            operation.task = nil
            operation.status = "cancelled"
            operation.result = ["confirmed": false, "code": "app.shuttingDown"]
        }
    }
}
#endif
